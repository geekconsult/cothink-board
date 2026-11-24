import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum CloudWorkspaceFileError: LocalizedError {
    case partial(receipts: Set<String>, message: String)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .partial(_, let message), .file(let message): return message
        }
    }
}

struct CloudWorkspaceFiles {
    let store: BoardStore
    let server: URL
    let send: (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maximumSize = 50 * 1024 * 1024
    private static let pollInterval: TimeInterval = 60

    private struct Stamp: Codable, Equatable {
        let length: Int
        let modified: Date
        let inode: UInt64
    }
    private struct Receipt: Codable {
        let key: String
        let digest: String
        let stamp: Stamp
        let checked: Date

        func serialized() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(self).base64EncodedString()
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func key(boardID: String, assetID: String) -> String {
        digest(Data("\(boardID.utf8.count):\(boardID)\(assetID)".utf8))
    }
    static func relativePath(boardID: String, assetID: String, name: String) -> String {
        // A remote display name never becomes a local path. Keep just its extension for Launch Services.
        let ext = (name as NSString).pathExtension.lowercased()
        let hasExtension = !ext.isEmpty && ext.utf8.count <= 20 && ext.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
        }
        return ".cothink-cloud/" + key(boardID: boardID, assetID: assetID) + (hasExtension ? ".\(ext)" : "")
    }

    func transfer(before: [Board], after: [Board], uploaded: Set<String>, editableBoardIDs: Set<String>) async throws -> Set<String> {
        let originals = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        var previous = [String: Receipt]()
        for value in uploaded {
            if let data = Data(base64Encoded: value), let entry = try? JSONDecoder().decode(Receipt.self, from: data) {
                previous[entry.key] = entry
            }
        }
        var saved = Set<String>()
        var failures = [String]()
        for board in after {
            let original = originals[board.id]
            let localAssets = Dictionary(uniqueKeysWithValues: (original?.assets ?? []).map { ($0.id, $0) })
            for asset in board.assets ?? [] {
                try Task.checkCancellation()
                let key = Self.key(boardID: board.id, assetID: asset.id)
                do {
                    let old = localAssets[asset.id]
                    let file = try location(for: asset, board: board, original: original, old: old)
                    let receipt = try await synchronize(file: file, boardID: board.id, asset: asset, key: key,
                                                        receipt: previous[key], canUpload: old?.relativePath == asset.relativePath && editableBoardIDs.contains(board.id))
                    saved.insert(try receipt.serialized())
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if let prior = previous[key] { saved.insert(try prior.serialized()) }
                    failures.append("\(asset.name): \(error.localizedDescription)")
                }
            }
        }
        if let first = failures.first {
            let remainder = failures.count > 1 ? " (\(failures.count) attachments pending)" : ""
            throw CloudWorkspaceFileError.partial(receipts: saved, message: first + remainder)
        }
        return saved
    }

    private func location(for asset: ProjectAsset, board: Board, original: Board?, old: ProjectAsset?) throws -> URL {
        guard board.id != ".", board.id != "..", !board.id.isEmpty, !board.id.contains("/"), !board.id.contains("\0") else {
            throw CloudWorkspaceFileError.file("Invalid board folder.")
        }
        let root = (original?.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? store.defaultProjectFilesDirectory(for: board.id)).standardizedFileURL.resolvingSymlinksInPath()
        let relative = asset.relativePath
        guard (old?.relativePath == relative || relative == Self.relativePath(boardID: board.id, assetID: asset.id, name: asset.name)),
              !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw CloudWorkspaceFileError.file("Invalid attachment path.")
        }
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"), target.resolvingSymlinksInPath().path == target.path else {
            throw CloudWorkspaceFileError.file("The attachment points outside its project folder.")
        }
        return target
    }

    private func stamp(_ file: URL) throws -> Stamp? {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { throw CloudWorkspaceFileError.file("Expected a regular file.") }
        guard size.intValue <= Self.maximumSize else { throw CloudWorkspaceFileError.file("The attachment exceeds the 50 MB sync limit.") }
        return Stamp(length: size.intValue, modified: date, inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private func synchronize(file: URL, boardID: String, asset: ProjectAsset, key: String, receipt: Receipt?, canUpload: Bool) async throws -> Receipt {
        let initial = try stamp(file)
        if let receipt, receipt.stamp == initial, Date().timeIntervalSince(receipt.checked) < Self.pollInterval { return receipt }

        var endpoint = URLComponents(url: server.appendingPathComponent("api/file"), resolvingAgainstBaseURL: false)!
        endpoint.queryItems = [URLQueryItem(name: "board", value: boardID), URLQueryItem(name: "asset", value: asset.id)]
        guard let url = endpoint.url else { throw CloudWorkspaceFileError.file("Invalid file URL.") }
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "x-cothink-client")
        request.httpMethod = "HEAD"
        let (_, head) = try await send(request)
        guard [200,404].contains(head.statusCode) else { throw httpError(head.statusCode) }
        let rawTag = head.value(forHTTPHeaderField: "ETag")
        let remote = rawTag?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if head.statusCode == 200 && (remote?.utf8.count != 64 || rawTag != "\"" + (remote ?? "") + "\"") {
            throw CloudWorkspaceFileError.file("Update the CoThink web server to sync attachments.")
        }

        var localData: Data?
        var local: String?
        if initial != nil {
            if let receipt, receipt.stamp == initial { local = receipt.digest }
            else { localData = try Data(contentsOf: file); local = Self.digest(localData!) }
        }
        if let local, local == remote, let initial {
            return Receipt(key: key, digest: local, stamp: initial, checked: Date())
        }

        if let remote, local == nil || (receipt != nil && receipt?.digest == local) {
            request.httpMethod = "GET"
            let (bytes, response) = try await send(request)
            guard response.statusCode == 200 else { throw httpError(response.statusCode) }
            guard bytes.count <= Self.maximumSize, Self.digest(bytes) == remote else {
                throw CloudWorkspaceFileError.file("The server file changed during download. Sync again.")
            }
            try Task.checkCancellation()
            guard try stamp(file) == initial else { throw CloudWorkspaceFileError.file("The local file changed during download. Sync again.") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: initial == nil ? [.withoutOverwriting] : [.atomic])
            guard let current = try stamp(file) else { throw CloudWorkspaceFileError.file("Could not save the downloaded attachment.") }
            return Receipt(key: key, digest: remote, stamp: current, checked: Date())
        }

        guard let local, let initial else { throw CloudWorkspaceFileError.file("File contents are unavailable. Check the Mac where the file was attached.") }
        guard canUpload, remote == nil || (receipt != nil && remote == receipt?.digest) else {
            throw CloudWorkspaceFileError.file("The local and web copies differ. Both copies were kept.")
        }
        let bytes = try localData ?? Data(contentsOf: file)
        guard Self.digest(bytes) == local, try stamp(file) == initial else {
            throw CloudWorkspaceFileError.file("The local file changed during upload. Sync again.")
        }
        request.httpMethod = "PUT"
        if let rawTag { request.setValue(rawTag, forHTTPHeaderField: "If-Match") }
        else { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        request.setValue(UTType(filenameExtension: (asset.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        let (_, response) = try await send(request)
        guard response.statusCode == 204 else { throw httpError(response.statusCode) }
        guard response.value(forHTTPHeaderField: "ETag") == "\"\(local)\"" else {
            throw CloudWorkspaceFileError.file("Update the CoThink web server to verify the uploaded attachment.")
        }
        return Receipt(key: key, digest: local, stamp: initial, checked: Date())
    }

    private func httpError(_ status: Int) -> Error {
        switch status {
        case 401: return CloudWorkspaceFileError.file("Sign in again to sync attachments.")
        case 403: return CloudWorkspaceFileError.file("This account cannot modify the attachment.")
        case 405: return CloudWorkspaceFileError.file("Update the CoThink web server to sync attachments.")
        case 412: return CloudWorkspaceFileError.file("The web copy changed. Sync again.")
        default: return CloudWorkspaceFileError.file("The file server returned HTTP \(status).")
        }
    }
}
