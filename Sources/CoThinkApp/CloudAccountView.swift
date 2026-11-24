import SwiftUI
import BoardCore

struct CloudAccountButton: View {
    @EnvironmentObject private var account: CloudAccount

    var body: some View {
        Button {
            account.showingPanel = true
        } label: {
            if let avatar = account.login?.user.avatar, account.issue == nil {
                ProfileFace(id: avatar, size: 24)
            } else {
                Image(systemName: account.issue != nil ? "exclamationmark.icloud" : account.login == nil ? "person.crop.circle" : "checkmark.icloud")
                .frame(width: 20, height: 20)
            }
        }
        .buttonStyle(.plain).modifier(GlassControl())
        .help(account.issue ?? account.login?.user.email ?? "Sign in to sync with CoThink Web")
        .accessibilityLabel(account.issue == nil ? "Account and sync" : "Account and sync needs attention")
    }
}

struct CloudAccountView: View {
    @ObservedObject var account: CloudAccount
    @Environment(\.dismiss) private var dismiss
    @State private var server = CloudLogin.productionServer
    @State private var email = ""
    @State private var password = ""
    @State private var editServer = false
    @State private var previewBoards = false
    @State private var chooseSide = false
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPanelHeader(title: "Account & Sync", subtitle: account.login?.user.email ?? "CoThink Web", icon: "arrow.triangle.2.circlepath.icloud",
                           close: { dismiss() })
            Divider()
            if account.login == nil || account.expired { signInForm } else { syncDetails }
            if let issue = account.issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.callout)
                    .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if account.busy { ProgressView().controlSize(.small).accessibilityLabel("Connecting to the workspace") }
        }
        .padding(24).frame(width: 460).modifier(AppPanelBackground())
        .onAppear {
            if let login = account.login { server = login.server.absoluteString == CloudLogin.retiredServer ? CloudLogin.productionServer : login.server.absoluteString; email = login.user.email }
            focus = email.isEmpty ? .email : .password
        }
        .confirmationDialog("Resolve conflicting changes?", isPresented: $chooseSide, titleVisibility: .visible) {
            if !account.webOnly {
                Button("Keep Mac changes") { Task { await account.sync(preference: .mac) } }
            }
            Button("Use web changes") { Task { await account.sync(preference: .web) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your choice applies to conflicting edits in this sync. Independent changes are combined.")
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.expired
                 ? "Reconnect to resume syncing this workspace."
                 : "Sign in to sync boards, lists, and attached files.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let localBoards = account.boardsToConnect
            if !account.expired && !localBoards.isEmpty {
                DisclosureGroup("Local boards to sync (\(localBoards.count))", isExpanded: $previewBoards) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(localBoards) { board in
                                Label(board.displayTitle, systemImage: "square.grid.2x2")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }.frame(maxHeight: 110)
                }.font(.callout)
            }
            LabeledContent("Email") {
                TextField("you@example.com", text: $email).textContentType(.username)
                    .accessibilityLabel("Email").focused($focus, equals: .email).onSubmit { focus = .password }
            }
            LabeledContent("Password") {
                SecureField("Web account password", text: $password).textContentType(.password)
                    .accessibilityLabel("Password").focused($focus, equals: .password).onSubmit(signIn)
            }
            DisclosureGroup("Server", isExpanded: $editServer) {
                TextField("Server address", text: $server).accessibilityLabel("Server address")
                    .padding(.top, 4)
            }
            HStack {
                if account.expired { Button("Sign out") { Task { await account.signOut() } } }
                Spacer()
                Button("Sign in & sync", action: signIn).modifier(AppPrimaryAction())
                    .disabled(!canSignIn).keyboardShortcut(.defaultAction)
            }
        }.disabled(account.busy)
    }

    private var canSignIn: Bool {
        !account.busy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func signIn() {
        guard canSignIn else { return }
        let credential = password
        password = ""
        Task { await account.signIn(server: server, email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: credential) }
    }

    private var syncDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProfilePicker(account: account)
            LabeledContent("Server", value: account.login?.server.absoluteString ?? "")
            if let synced = account.lastSync {
                LabeledContent("Last synced", value: synced.formatted(date: .abbreviated, time: .standard))
            }
            Text("Changes sync while CoThink Board is open. You can keep working offline. Signing out pauses sync and keeps downloaded boards on this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sign out") { Task { await account.signOut() } }
                Spacer()
                if account.conflict {
                    Button("Resolve changes…") { chooseSide = true }.modifier(AppPrimaryAction())
                } else {
                    Button("Sync now") { Task { await account.sync() } }.modifier(AppPrimaryAction())
                }
            }.disabled(account.busy)
        }
    }
}
