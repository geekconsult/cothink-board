import Foundation
import CryptoKit
import Security
import BoardCore
import SwiftUI

enum CloudAccountError: LocalizedError {
    case invalidServer, unexpectedReply, keychain(OSStatus), server(String), draft

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address, or an HTTP loopback address for a local server."
        case .unexpectedReply: return "The server returned an unexpected sign-in response."
        case .keychain(let status): return "Keychain could not access the saved session (\(status))."
        case .server(let detail): return detail
        case .draft: return "Finish editing the current board before switching workspaces."
        }
    }
}

struct CloudLogin: Codable, Equatable {
    static let productionServer = "https://cothink.aigeekconsult.com"
    static let retiredServer = "https://cothink.denyume.cloud"
    struct User: Codable, Equatable { let id: String; let email: String; var avatar: String? = nil }
    let user: User
    let server: URL
    let token: String

    static func origin(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw CloudAccountError.invalidServer }
        parts.host = host
        parts.scheme = parts.scheme?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.path = ""
        guard let url = parts.url else { throw CloudAccountError.invalidServer }
        return url
    }
}

private final class NoCloudRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CloudTransport {
    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: NoCloudRedirects(), delegateQueue: nil)
    }()
    let login: CloudLogin

    static func authenticate(server: URL, email: String, password: String) async throws -> CloudLogin {
        struct Reply: Decodable { let user: CloudLogin.User }
        struct Failure: Decodable { let error: String }
        var request = URLRequest(url: server.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "x-cothink-client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudAccountError.unexpectedReply }
        guard response.statusCode == 200 else {
            throw CloudAccountError.server((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Sign-in failed (HTTP \(response.statusCode)).")
        }
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie"),
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: server)
                .first(where: { $0.name == "cothink_session" }),
              cookie.value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
        else { throw CloudAccountError.unexpectedReply }
        return CloudLogin(user: try JSONDecoder().decode(Reply.self, from: data).user, server: server, token: cookie.value)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == login.server.scheme, url.host == login.server.host,
              url.port == login.server.port, url.user == nil, url.password == nil,
              url.path.hasPrefix("/api/") else { throw CloudAccountError.invalidServer }
        var request = request
        request.setValue("cothink_session=\(login.token)", forHTTPHeaderField: "Cookie")
        request.setValue("1", forHTTPHeaderField: "x-cothink-client")
        let (data, response) = try await Self.http.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudAccountError.unexpectedReply }
        return (data, http)
    }

    func logout() async {
        var request = URLRequest(url: login.server.appendingPathComponent("api/auth/logout"))
        request.httpMethod = "POST"
        _ = try? await send(request)
    }
}

private struct CloudKeychain {
    let workspace: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.cothink.board.web-session",
         kSecAttrAccount as String: workspace]
    }
    func read() throws -> CloudLogin? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudAccountError.keychain(status) }
        return try JSONDecoder().decode(CloudLogin.self, from: data)
    }
    func save(_ value: CloudLogin) throws {
        let data = try JSONEncoder().encode(value)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(changes) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudAccountError.keychain(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudAccountError.keychain(status) }
    }
}

@MainActor
final class CloudAccount: ObservableObject {
    @Published private(set) var login: CloudLogin?
    @Published private(set) var busy = false
    @Published private(set) var expired = false
    @Published private(set) var issue: String?
    @Published private(set) var conflict = false
    @Published private(set) var webOnly = false
    @Published private(set) var lastSync: Date?
    @Published var showingPanel = false
    var boardsToConnect: [Board] {
        guard let store = model?.store, (try? CloudWorkspaceSync.isConnected(store: store)) == false else { return [] }
        return model?.boards ?? []
    }
    private var engine: CloudWorkspaceSync?
    private var base: URL?
    private weak var model: BoardViewModel?
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private var keychain: CloudKeychain? { base.map { CloudKeychain(workspace: $0.standardizedFileURL.path) } }

    func start(_ model: BoardViewModel) {
        guard base == nil, let store = model.store else { return }
        base = store.storageDirectory
        self.model = model
        do {
            if let saved = try keychain?.read() {
                if saved.server.absoluteString == CloudLogin.retiredServer {
                    login = saved
                    expired = true
                    issue = "CoThink Web moved. Sign in at the new address to resume syncing."
                } else {
                    try connect(saved)
                }
            }
        } catch { issue = error.localizedDescription }
    }

    private func connect(_ identity: CloudLogin, migrate: Bool = false) throws {
        guard let base, let model else { throw CloudAccountError.unexpectedReply }
        var store = try BoardStore(directory: base)
        if migrate {
            try CloudWorkspaceSync.migrateCoThinkProductionOrigin(store: store, server: identity.server, userID: identity.user.id)
        }
        if try !CloudWorkspaceSync.isCompatible(store: store, server: identity.server, userID: identity.user.id) {
            let key = SHA256.hash(data: Data((identity.server.absoluteString + "\n" + identity.user.id).utf8))
                .map { String(format: "%02x", $0) }.joined()
            let accounts = base.appendingPathComponent("Accounts")
            let destination = accounts.appendingPathComponent(key)
            store = try BoardStore(directory: destination)
            if identity.server.absoluteString == CloudLogin.productionServer {
                let oldKey = SHA256.hash(data: Data((CloudLogin.retiredServer + "\n" + identity.user.id).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let oldFolder = accounts.appendingPathComponent(oldKey)
                if FileManager.default.fileExists(atPath: oldFolder.path) {
                    let oldStore = try BoardStore(directory: oldFolder)
                    if migrate {
                        try CloudWorkspaceSync.migrateCoThinkProductionOrigin(store: oldStore, server: identity.server, userID: identity.user.id)
                    }
                    if try CloudWorkspaceSync.isConnected(store: oldStore),
                       try CloudWorkspaceSync.isCompatible(store: oldStore, server: identity.server, userID: identity.user.id),
                       try !CloudWorkspaceSync.isConnected(store: store) {
                        store = oldStore
                    }
                }
            }
        }
        // Each actor owns its own BoardStore cache. The stores coordinate writes using the same on-disk lock.
        let workerStore = try BoardStore(directory: store.storageDirectory)
        if model.store?.storageDirectory != store.storageDirectory { try model.switchWorkspace(to: store) }
        engine = CloudWorkspaceSync(store: workerStore, server: identity.server, userID: identity.user.id, send: CloudTransport(login: identity).send)
        login = identity
        issue = nil; expired = false; conflict = false; webOnly = false; lastSync = nil
        nextAttempt = .distantPast; failures = 0
    }

    func signIn(server: String, email: String, password: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let identity = try await CloudTransport.authenticate(server: CloudLogin.origin(server), email: email, password: password)
            do {
                try connect(identity, migrate: true)
                try keychain?.save(identity)
            } catch {
                engine = nil; login = nil
                await CloudTransport(login: identity).logout()
                throw error
            }
            await performSync()
        } catch { issue = error.localizedDescription }
    }

    func loadAvatar(choice: String? = nil) async throws {
        guard let current = login, !expired else { throw CloudAccountError.unexpectedReply }
        let transport = CloudTransport(login: current)
        let reply: ProfileReply
        if let choice {
            reply = try await transport.cloudJSON(["api", "auth", "avatar"], method: "PUT", body: ["avatar": choice])
        } else {
            reply = try await transport.cloudJSON(["api", "auth", "me"])
        }
        guard login?.token == current.token, reply.user.id == current.user.id else { return }
        let updated = CloudLogin(user: reply.user, server: current.server, token: current.token)
        if current != updated {
            try keychain?.save(updated)
            login = updated
        }
    }

    func signOut() async {
        guard !busy, let identity = login else { return }
        busy = true
        defer { busy = false }
        do {
            try keychain?.remove()
            engine = nil; login = nil; issue = nil; expired = false; conflict = false; webOnly = false; lastSync = nil
            if identity.server.absoluteString != CloudLogin.retiredServer { await CloudTransport(login: identity).logout() }
        } catch { issue = error.localizedDescription }
    }

    func tick() {
        guard engine != nil, !busy, !expired, !conflict, nextAttempt <= Date() else { return }
        Task { await sync() }
    }

    func sync(preference: CloudConflictChoice? = nil) async {
        guard !busy, !expired, engine != nil else { return }
        busy = true
        defer { busy = false }
        await performSync(preference)
    }

    private func performSync(_ preference: CloudConflictChoice? = nil) async {
        guard let engine else { return }
        do {
            guard model?.draftBlocked != true else { throw CloudAccountError.draft }
            try model?.updateCloudReminderSnapshots()
            try await engine.synchronize(preference: preference)
            try model?.refresh()
            if let model, model.board == nil, let first = model.boards.first { model.selectBoard(first.id) }
            lastSync = Date(); issue = nil; conflict = false; webOnly = false
            failures = 0; nextAttempt = Date().addingTimeInterval(6)
        } catch {
            issue = error.localizedDescription
            switch error {
            case CloudSyncError.conflict: conflict = true
            case CloudSyncError.readOnly: conflict = true; webOnly = true
            case CloudSyncError.http(401): expired = true; issue = "Your web session expired. Sign in again to resume syncing."
            default: break
            }
            failures = min(failures + 1, 5)
            nextAttempt = Date().addingTimeInterval(Double(3 * (1 << failures)))
        }
    }
}
