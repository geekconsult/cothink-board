import Foundation
import Darwin

public actor CloudWorkspaceSync {
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let store: BoardStore
    private let server: URL
    private let account: CloudAccount
    private let send: Transport
    private var running = false

    public init(store: BoardStore, server: URL, userID: String, send: @escaping Transport) {
        self.store = store
        self.server = server
        self.account = Self.identity(server: server, userID: userID)
        self.send = send
    }

    private static func identity(server: URL, userID: String) -> CloudAccount {
        CloudAccount(server: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), userID: userID)
    }

    public static func isConnected(store: BoardStore) throws -> Bool {
        let (_, marker) = try store.cloudSnapshot()
        return marker != nil
    }

    public static func isCompatible(store: BoardStore, server: URL, userID: String) throws -> Bool {
        let (_, marker) = try store.cloudSnapshot()
        return marker == nil || marker?.account == identity(server: server, userID: userID)
    }

    public static func migrateCoThinkProductionOrigin(store: BoardStore, server: URL, userID: String) throws {
        guard server.absoluteString == "https://cothink.aigeekconsult.com" else { return }
        try store.migrateCloudServer(from: "https://cothink.denyume.cloud", to: server.absoluteString, userID: userID)
    }

    private struct Response: Decodable {
        let revision: Int
        let state: CloudJSON?
        var document: CloudJSON { state ?? CloudWorkspaceDocument.empty }
    }
    private struct Write: Encodable {
        let expectedRevision: Int
        let state: CloudJSON
    }

    private func request(_ update: Write? = nil) async throws -> Response {
        var request = URLRequest(url: server.appendingPathComponent("api/workspace"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "x-cothink-client")
        if let update {
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(update)
        }
        try Task.checkCancellation()
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw CloudSyncError.http(response.statusCode) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    public func synchronize(preference: CloudConflictChoice? = nil) async throws {
        guard !running else { throw CloudSyncError.busy }
        running = true
        defer { running = false }
        // Distinct app processes can use the same local store. A dedicated lock
        // serializes cloud I/O while leaving the normal board transaction lock free.
        let fd = open(store.storageDirectory.appendingPathComponent("cloud-sync.lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CloudSyncError.busy }
        defer { flock(fd, LOCK_UN) }
        for attempt in 0..<3 {
            do {
                try await synchronizeOnce(preference: preference)
                return
            } catch CloudSyncError.http(409) where attempt < 2 {
                // The remote changed after GET. Recalculate against its new contents.
            } catch BoardError.conflict where attempt < 2 {
                // An edit landed in the local store while the HTTP request was in flight.
            }
        }
    }

    private func synchronizeOnce(preference: CloudConflictChoice?) async throws {
        let (local, saved) = try store.cloudSnapshot()
        guard saved == nil || saved?.account == account else { throw CloudSyncError.accountChanged }
        let response = try await request()
        let raw = response.document
        let isolated = CloudLocalWorkspace(boards: [], lists: [])
        let remote = try CloudWorkspaceDocument.localize(raw, preserving: isolated)
        try store.validateCloud(remote)
        let remoteKnown = try CloudWorkspaceDocument.project(remote)
        let current = try CloudWorkspaceDocument.project(local)
        var marker = saved ?? CloudCheckpoint(account: account)
        let baseline = marker.baseline ?? CloudWorkspaceDocument.empty
        let rawBoards = try CloudJSON.index(raw["boards"]?.items ?? [])
        let macBoards = try CloudJSON.index(current["boards"]?.items ?? [])
        let oldBoards = try CloudJSON.index(baseline["boards"]?.items ?? [])
        let webBoards = try CloudJSON.index(remoteKnown["boards"]?.items ?? [])
        var macInput = current
        var filtered = try current["boards"]?.items ?? []
        for key in Set(oldBoards.keys).union(rawBoards.keys) {
            let role = rawBoards[key]?["_access"]?["role"]?.text
            let revoked = rawBoards[key] == nil && marker.sharedBoards.contains(key)
            let viewerEdited = role == "view" && macBoards[key] != oldBoards[key] && macBoards[key] != webBoards[key]
            let removedShared = role == "edit" && macBoards[key] == nil && oldBoards[key] != nil
            guard (revoked && macBoards[key] != oldBoards[key]) || viewerEdited || removedShared else { continue }
            guard preference == .web else {
                throw CloudSyncError.readOnly((rawBoards[key] ?? oldBoards[key])?["title"]?.text ?? key)
            }
            filtered.removeAll { $0["id"]?.text == key }
            if let original = oldBoards[key] { filtered.append(original) }
        }
        if filtered != (try current["boards"]?.items) {
            var dictionary = try current.dictionary
            dictionary["boards"] = .array(filtered)
            macInput = .object(dictionary)
        }
        guard let merged = try CloudWorkspaceMerge.merge(base: baseline, mac: macInput, web: remoteKnown, preference: preference),
              var outgoing = try CloudWorkspaceMerge.applying(from: remoteKnown, to: merged, on: raw) else { throw CloudSyncError.invalidWorkspace }
        let candidate = try CloudWorkspaceDocument.localize(merged, preserving: local)
        try store.validateCloud(candidate)
        // Explicit null clears a pin. Older clients can omit the field on unrelated writes.
        if candidate.pinnedListID == nil, outgoing["pinnedListID"]?.text != nil || remote.pinnedListID != nil {
            var wire = try outgoing.dictionary
            wire["pinnedListID"] = .null
            outgoing = .object(wire)
        }

        try Task.checkCancellation()
        if saved == nil { try store.bindCloud(account) }
        let accepted = outgoing == raw ? response : try await request(Write(expectedRevision: response.revision, state: outgoing))
        try Task.checkCancellation()
        let final = try CloudWorkspaceDocument.localize(accepted.document, preserving: local)
        try store.validateCloud(final)
        let finalBoards = try accepted.document["boards"]?.items ?? []
        let shared = finalBoards.filter { ["edit", "view"].contains($0["_access"]?["role"]?.text ?? "") }
        marker.sharedBoards = Set(shared.compactMap { $0["id"]?.text })
        marker.baseline = try CloudWorkspaceDocument.project(CloudWorkspaceDocument.localize(accepted.document, preserving: isolated))
        if marker != saved || final != local {
            try store.applyCloud(final, replacing: local, checkpoint: marker)
        }
        let editable = Set(finalBoards.filter { $0["_access"]?["role"]?.text != "view" }.compactMap { $0["id"]?.text })
        let files = CloudWorkspaceFiles(store: store, server: server, send: send)
        do {
            let receipts = try await files.transfer(before: local.boards, after: final.boards, uploaded: marker.files, editableBoardIDs: editable)
            if receipts != marker.files { try store.updateCloudFiles(receipts, account: account) }
        } catch let error as CloudWorkspaceFileError {
            if case .partial(let receipts, _) = error, receipts != marker.files {
                try store.updateCloudFiles(receipts, account: account)
            }
            throw error
        }
    }
}
