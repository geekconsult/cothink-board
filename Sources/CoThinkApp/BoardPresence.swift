import SwiftUI

struct PresentPerson: Decodable, Equatable, Identifiable {
    let id, email, avatar: String
    let objectIDs: [String]
}
struct PresenceReply: Decodable { let people: [PresentPerson] }

struct ViewInvitation: Decodable, Equatable, Identifiable {
    let id, from, email, avatar: String
}

struct ViewInvitations: Decodable, Equatable {
    let eligible, followers, outgoing: [String]
    let incoming: [ViewInvitation]
    static let empty = Self(eligible: [], followers: [], outgoing: [], incoming: [])
}

struct PresenceContext: Equatable {
    let login: CloudLogin?
    let boardID: String?
    var editing: String?
}

@MainActor
final class BoardPresence: ObservableObject {
    @MainActor private final class Visit {
        let id = UUID().uuidString
        let login: CloudLogin
        let boardID: String
        var sequence = 0
        var busy = false
        init(_ login: CloudLogin, _ boardID: String) { self.login = login; self.boardID = boardID }
        func request(editing: String?, cursor: CGPoint? = nil, camera: BoardCamera? = nil, followingID: String? = nil, tour: Int? = nil, leave: Bool = false) async throws -> PresenceReply {
            sequence += 1
            var body: [String: Any] = ["visit": id, "sequence": sequence, "acceptsInvites": true]
            body["tour"] = tour
            body["followingID"] = followingID
            body["camera"] = camera?.payload
            body["objectID"] = editing
            body["cursor"] = cursor.map { ["x": $0.x, "y": $0.y] }
            return try await CloudTransport(login: login).cloudJSON(["api","boards",boardID,"presence"],
                method: leave ? "DELETE" : "PUT", body: body, timeout: 5)
        }
    }

    @Published private(set) var people: [PresentPerson] = []
    @Published private(set) var availableViews = Set<String>()
    @Published private(set) var following: String?
    @Published private(set) var followedCamera: BoardCamera?
    @Published private(set) var invites = ViewInvitations.empty
    @Published private(set) var canPresent = false
    @Published private(set) var inviteBusy = false
    @Published var inviteError: String?
    func canInvite(_ id: String) -> Bool {
        canPresent && following == nil && invites.eligible.contains(id) && !invites.followers.contains(id) && !invites.outgoing.contains(id)
    }
    func endTour() async { await inviteCommand(["action": "end-tour"]) }
    func invite(_ targetID: String) async {
        await inviteCommand(["action": "invite", "targetID": targetID])
    }
    func respond(to invitation: ViewInvitation, accept: Bool) async {
        await inviteCommand(["action": accept ? "accept" : "decline", "inviteID": invitation.id], leader: accept ? invitation.from : nil)
    }
    private func inviteCommand(_ command: [String: String], leader: String? = nil) async {
        struct Reply: Decodable { let camera: BoardCamera?; let tour: Int? }
        guard let current = visit, !inviteBusy else { return }
        inviteBusy = true
        inviteError = nil
        defer { if current === visit { inviteBusy = false } }
        var body = command
        body["visit"] = current.id
        do {
            let reply: Reply = try await CloudTransport(login: current.login).cloudJSON(["api","boards",current.boardID,"presence"],
                method: "POST", body: body, timeout: 6)
            guard current === visit else { return }
            if let leader, let camera = reply.camera {
                guard (tours[leader] ?? 0) <= (reply.tour ?? 0) else { return }
                tours[leader] = reply.tour ?? 0
                views[leader] = camera
                follow(leader)
            }
        } catch {
            if current === visit { inviteError = error.localizedDescription }
        }
    }
    private var tours = [String: Int]()
    private var followedTour: Int?
    private var views = [String: BoardCamera]()
    private var localCamera: BoardCamera?
    private var sharedCamera: BoardCamera? { following == nil ? localCamera : nil }
    let cursors = BoardCursorFeed()
    private var cursor: CGPoint?
    private var cursorUpdate: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var visit: Visit?
    private var editing: String?
    func configure(_ context: PresenceContext) {
        guard let login = context.login, let boardID = context.boardID else { close(); return }
        if visit?.login.token != login.token || visit?.boardID != boardID {
            close()
            let current = Visit(login, boardID)
            visit = current
            listener = Task { await followCursors(current) }
        }
        editing = context.editing
        pulse()
    }
    private func followCursors(_ current: Visit) async {
        let transport = CloudTransport(login: current.login)
        var revision = -1
        while current === visit && !Task.isCancelled {
            do {
                let reply: BoardCursorReply = try await transport.cloudJSON(["api","boards",current.boardID,"presence"],
                    timeout: 8, query: [URLQueryItem(name: "since", value: String(revision))])
                guard current === visit, !Task.isCancelled else { return }
                revision = reply.revision
                let state = reply.invites ?? .empty
                if state != invites { invites = state }
                receiveViews(reply.views ?? [])
                cursors.replace(reply.cursors)
            } catch {
                guard current === visit, !Task.isCancelled else { return }
                if invites != .empty { invites = .empty }
                receiveViews([])
                cursors.replace([])
                revision = -1
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }
    private func receiveViews(_ next: [PersonCamera]) {
        tours = Dictionary(next.map { ($0.id, $0.tour ?? 0) }, uniquingKeysWith: { _, last in last })
        views = Dictionary(next.map { ($0.id, $0.camera) }, uniquingKeysWith: { _, last in last })
        let ids = Set(views.keys)
        if availableViews != ids { availableViews = ids }
        if let following {
            if let view = views[following], tours[following] == followedTour {
                if followedCamera != view { followedCamera = view }
            } else { stopFollowing() }
        }
    }
    func follow(_ id: String) {
        guard let camera = views[id] else { return }
        followedTour = tours[id] ?? 0
        following = id
        followedCamera = camera
        pulse()
    }
    func stopFollowing() {
        guard following != nil else { return }
        followedTour = nil
        following = nil
        followedCamera = nil
        pulse()
    }
    func updateCamera(_ camera: BoardCamera?) {
        guard visit != nil, localCamera != camera else { return }
        localCamera = camera
        if following == nil { scheduleCursor() }
    }
    func point(at point: CGPoint?) {
        guard visit != nil, point != cursor else { return }
        cursor = point
        scheduleCursor()
    }
    private func scheduleCursor() {
        guard cursorUpdate == nil, visit?.busy == false, people.count > 1 else { return }
        cursorUpdate = Task {
            do { try await Task.sleep(for: .milliseconds(65)) } catch { return }
            cursorUpdate = nil
            pulse()
        }
    }
    func pulse() {
        guard let current = visit, !current.busy else { return }
        current.busy = true
        let target = editing
        let sentCursor = cursor
        let sentCamera = sharedCamera
        let sentTour = followedTour
        let sentFollowing = following
        Task {
            guard current === visit else { return }
            let result = try? await current.request(editing: target, cursor: sentCursor, camera: sentCamera, followingID: sentFollowing, tour: sentTour)
            guard current === visit else { return }
            current.busy = false
            let ready = result != nil && sentCamera != nil
            if canPresent != ready { canPresent = ready }
            let next = result?.people ?? []
            if people != next { people = next }
            if editing != target || following != sentFollowing || followedTour != sentTour { pulse() }
            else if cursor != sentCursor || sharedCamera != sentCamera { scheduleCursor() }
        }
    }
    func close() {
        guard let old = visit else { return }
        visit = nil
        listener?.cancel()
        listener = nil
        cursorUpdate?.cancel()
        cursorUpdate = nil
        cursor = nil
        localCamera = nil
        receiveViews([])
        cursors.replace([])
        editing = nil
        invites = .empty
        canPresent = false
        inviteBusy = false
        inviteError = nil
        people = []
        Task { _ = try? await old.request(editing: nil, leave: true) }
    }
}
