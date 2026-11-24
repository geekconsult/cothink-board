import AppKit
import BoardCore
import SwiftUI

struct ProfileReply: Decodable {
    let user: CloudLogin.User
}

struct BoardMember: Identifiable, Decodable {
    let id: String
    let email: String
    let avatar: String
    let role: String
    var roleLabel: String { role == "owner" ? "Owner" : role == "edit" ? "Can edit" : "Can view" }
}

struct BoardPeople: Decodable {
    let revision: Int
    let members: [BoardMember]
}

extension CloudTransport {
    func cloudJSON<T: Decodable>(_ path: [String], method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 30, query: [URLQueryItem] = []) async throws -> T {
        var url = path.reduce(login.server) { $0.appending(component: $1) }
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = try? JSONDecoder().decode([String: String].self, from: data)
            throw CloudAccountError.server(detail?["error"] ?? "Request failed (HTTP \(response.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func people(boardID: String) async throws -> BoardPeople {
        try await cloudJSON(["api", "boards", boardID, "people"])
    }

    func share(boardID: String, email: String, role: String, revision: Int) async throws {
        struct Changed: Decodable { let revision: Int }
        let _: Changed = try await cloudJSON(["api", "boards", boardID, "shares"], method: "POST",
            body: ["email": email, "role": role, "expectedRevision": revision])
    }
}

struct ProfileFace: View {
    static let choices = ["mochi", "peach", "puddle", "honey", "sprout", "pip"]
    private static let images = Dictionary(uniqueKeysWithValues: choices.compactMap { id -> (String, NSImage)? in
        let url = Bundle.main.url(forResource: id, withExtension: "svg", subdirectory: "ProfileAvatars")
            ?? Bundle.module.url(forResource: id, withExtension: "svg", subdirectory: "ProfileAvatars")
        return url.flatMap(NSImage.init(contentsOf:)).map { (id, $0) }
    })
    static func image(_ id: String) -> NSImage? { images[id] }

    let id: String
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        Group {
            if let image = Self.image(id) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "person.crop.circle").resizable().scaledToFit() }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(hovering && !reduceMotion ? -8 : 0))
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.4), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }
}

struct ProfilePicker: View {
    @ObservedObject var account: CloudAccount
    @State private var saving = false
    @State private var error: String?
    private var selected: String? { account.login?.user.avatar }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profile avatar").font(.headline)
                Spacer()
                Button("Surprise me", systemImage: "dice") {
                    if let next = ProfileFace.choices.filter({ $0 != selected }).randomElement() { choose(next) }
                }
            }
            HStack(spacing: 8) {
                ForEach(ProfileFace.choices, id: \.self) { id in
                    Button { choose(id) } label: {
                        ProfileFace(id: id, size: 38).padding(3)
                            .overlay(Circle().strokeBorder(id == selected ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel(id.capitalized).help(id.capitalized)
                        .accessibilityAddTraits(id == selected ? .isSelected : [])
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(saving)
        .task {
            saving = true
            defer { saving = false }
            do { try await account.loadAvatar() } catch { self.error = error.localizedDescription }
        }
    }
    private func choose(_ id: String) {
        saving = true
        Task {
            defer { saving = false }
            do { try await account.loadAvatar(choice: id); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct BoardPeopleButton: View {
    let board: Board
    @ObservedObject var account: CloudAccount
    @ObservedObject var presence: BoardPresence
    @State private var open = false
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -4) {
                ForEach(presence.people.prefix(3)) { person in
                    if presence.availableViews.contains(person.id) {
                        Button { presence.follow(person.id) } label: { ProfileFace(id: person.avatar, size: 23) }
                            .buttonStyle(.plain).help("Follow " + person.email)
                            .accessibilityLabel("Follow " + person.email)
                    } else { ProfileFace(id: person.avatar, size: 23) }
                }
            }
            Button {
                if account.login == nil || account.expired { account.showingPanel = true }
                else { open = true }
            } label: {
                if presence.people.isEmpty {
                    Image(systemName: "person.2").frame(width: 24, height: 26)
                } else {
                    let count = presence.invites.followers.count
                    Text(count == 0 ? "\(presence.people.count) here" : "\(presence.people.count) here · \(count) following you")
                        .font(.caption)
                }
            }.accessibilityLabel("Board people and sharing").help("Board people and sharing")
        }
        .popover(isPresented: $open) {
            if let login = account.login {
                BoardPeoplePanel(board: board, login: login, presence: presence).id(login.user.id)
            }
        }
    }
}

private struct BoardPeoplePanel: View {
    @Environment(\.dismiss) private var dismiss
    let board: Board
    let login: CloudLogin
    @ObservedObject var presence: BoardPresence
    @State private var roster: BoardPeople?
    @State private var email = ""
    @State private var role = "edit"
    @State private var busy = false
    @State private var error: String?
    private var transport: CloudTransport { CloudTransport(login: login) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Board people").font(.headline)
                    Text(board.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh people").disabled(busy)
            }
            if !presence.invites.incoming.isEmpty || presence.inviteError != nil {
                BoardInvitationBanner(presence: presence)
            }
            if let roster {
                if presence.canPresent && presence.following == nil && !presence.invites.eligible.isEmpty {
                    Button("Invite everyone to follow", systemImage: "person.2.wave.2") {
                        Task { await presence.invite("*") }
                    }.disabled(presence.inviteBusy || !presence.invites.eligible.contains(where: presence.canInvite))
                }
                if !presence.invites.followers.isEmpty || !presence.invites.outgoing.isEmpty {
                    Button("End board tour", systemImage: "stop.circle") { Task { await presence.endTour() } }
                        .disabled(presence.inviteBusy)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(roster.members) { person in
                            HStack {
                                if presence.availableViews.contains(person.id) {
                                    Button { presence.follow(person.id); dismiss() } label: {
                                        ProfileFace(id: person.avatar, size: 32)
                                    }.buttonStyle(.plain).help("Follow " + person.email).accessibilityLabel("Follow " + person.email)
                                } else { ProfileFace(id: person.avatar, size: 32) }
                                Text(person.email).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                if presence.people.contains(where: { $0.id == person.id }) {
                                    Text(presence.invites.followers.contains(person.id) ? "Following you" :
                                         presence.invites.outgoing.contains(person.id) ? "Invited" : "Here now")
                                        .font(.caption2).foregroundStyle(.green)
                                }
                                if presence.canInvite(person.id) {
                                    Button("Invite") { Task { await presence.invite(person.id) } }
                                        .controlSize(.small).disabled(presence.inviteBusy)
                                        .accessibilityLabel("Invite " + person.email + " to follow")
                                }
                                Text(person.roleLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(height: min(220, CGFloat(roster.members.count) * 40))
                if roster.members.contains(where: { $0.id == login.user.id && $0.role == "owner" }) {
                    Divider()
                    TextField("User email", text: $email).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Access", selection: $role) {
                            Text("Can edit").tag("edit")
                            Text("Can view").tag("view")
                        }
                        Spacer()
                        Button("Share") { Task { await share(roster.revision) } }
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.disabled(busy)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(18).frame(width: 430).task { await load() }
            .onChange(of: presence.following) { _, next in if next != nil { dismiss() } }
    }
    private func load() async {
        busy = true
        defer { busy = false }
        do { roster = try await transport.people(boardID: board.id); error = nil }
        catch { roster = nil; self.error = error.localizedDescription }
    }
    private func share(_ revision: Int) async {
        busy = true
        defer { busy = false }
        do {
            try await transport.share(boardID: board.id, email: email.trimmingCharacters(in: .whitespacesAndNewlines), role: role, revision: revision)
            email = ""
            await load()
        } catch {
            let detail = error.localizedDescription
            await load()
            self.error = detail
        }
    }
}

struct BoardInvitationBanner: View {
    @ObservedObject var presence: BoardPresence
    var body: some View {
        VStack(spacing: 4) {
            if let invitation = presence.invites.incoming.first {
                HStack {
                    ProfileFace(id: invitation.avatar, size: 23)
                    Text(invitation.email + " invites you to follow their view").lineLimit(2)
                    Button("Accept") { Task { await presence.respond(to: invitation, accept: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { Task { await presence.respond(to: invitation, accept: false) } }
                }.disabled(presence.inviteBusy)
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = presence.inviteError {
                HStack {
                    Text(error)
                    Button("Dismiss") { presence.inviteError = nil }
                }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }.font(.callout).padding(8)
    }
}
