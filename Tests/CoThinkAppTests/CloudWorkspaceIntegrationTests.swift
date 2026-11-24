import Foundation
import XCTest
import SwiftUI
import BoardCore
@testable import CoThinkApp

final class CloudWorkspaceIntegrationTests: XCTestCase {
    // The caller provides a disposable authenticated web instance and a Chrome smoke driver.
    @MainActor
    func testRoundTripThroughAuthenticatedWebApp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["COTHINK_TEST_URL"], let email = env["COTHINK_TEST_EMAIL"],
              let password = env["COTHINK_TEST_PASSWORD"], let script = env["COTHINK_TEST_CHROME"],
              let node = env["COTHINK_TEST_NODE"] else { throw XCTSkip("Start a disposable web server and set COTHINK_TEST_URL, COTHINK_TEST_EMAIL, COTHINK_TEST_PASSWORD, COTHINK_TEST_CHROME, and COTHINK_TEST_NODE.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BoardViewModel(storeDirectory: directory)
        let store = try XCTUnwrap(model.store)
        let boardID = try XCTUnwrap(model.board?.id)
        let note = Note(text: "Created on Mac", x: 90, y: 105)
        var reminders = Note(text: "Reminders", x: 340, y: 105, height: 200)
        reminders.reminderID = "local-native-id"
        reminders.additionalReminders = [ReminderReference(id: "another-local-native-id", title: "Check delivery")]
        reminders.reminderSnapshots = [CloudReminderItem(title: "Call supplier", completed: true, flagged: true),
                                        CloudReminderItem(title: "Check delivery", due: "2026-11-25", priority: 1)]
        let file = ProjectAsset(name: "proof-mac.txt", relativePath: "proof-mac.txt")
        let fileDirectory = store.defaultProjectFilesDirectory(for: boardID)
        try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        try Data("File from Mac".utf8).write(to: fileDirectory.appendingPathComponent(file.relativePath))
        let image = ProjectAsset(name: "from-mac.png", relativePath: "from-mac.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII="))
        try png.write(to: fileDirectory.appendingPathComponent(image.relativePath))
        var imageNote = Note(text: "Image from Mac", x: 680, y: 120, height: 200)
        imageNote.assetIDs = [image.id]
        var fileNote = Note(x: 90, y: 325, width: 220, height: 116)
        fileNote.assetIDs = [file.id]
        XCTAssertTrue(model.mutate {
            $0.title = "Mac–Web integration"
            $0.notes = [note, reminders, fileNote, imageNote]
            $0.assets = [file, image]
        })
        var list = try store.createList(title: "Active work")
        list.boardIDs = [boardID]
        _ = try store.replaceList(list, expectedRevision: list.revision)
        let later = try store.createList(title: "Later")
        var secondList = try store.createList(title: "Planning")
        secondList.boardIDs = [boardID]
        _ = try store.replaceList(secondList, expectedRevision: secondList.revision)
        try store.setOnDesk(boardID, included: true)
        try store.setPinnedList(list.id)
        let server = try CloudLogin.origin(address)
        let account = CloudAccount()
        account.start(model)
        addTeardownBlock { await account.signOut() }
        await account.signIn(server: address, email: email, password: password)
        XCTAssertNil(account.issue)
        _ = try XCTUnwrap(account.lastSync)
        let login = try XCTUnwrap(account.login)
        let transport = CloudTransport(login: login)
        let worker = try BoardStore(directory: directory)
        let remote = try await transport.send(URLRequest(url: server.appendingPathComponent("api/workspace")))
        XCTAssertEqual(remote.1.statusCode, 200)
        let json = String(decoding: remote.0, as: UTF8.self)
        XCTAssertFalse(json.contains("local-native-id"))
        XCTAssertFalse(json.contains(fileDirectory.path))

        let editorEmail = "shared-editor@example.test"
        let _: ProfileReply = try await transport.cloudJSON(["api", "users"], method: "POST",
            body: ["email": editorEmail, "password": password, "role": "member"])
        let roster = try await transport.people(boardID: boardID)
        XCTAssertEqual(roster.members.map(\.role), ["owner"])
        try await transport.share(boardID: boardID, email: editorEmail, role: "edit", revision: roster.revision)
        try await account.loadAvatar(choice: "sprout")
        let editorLogin = try await CloudTransport.authenticate(server: server, email: editorEmail, password: password)
        let editorTransport = CloudTransport(login: editorLogin)
        let sharedPeople = try await editorTransport.people(boardID: boardID)
        XCTAssertEqual(sharedPeople.members.map(\.role), ["owner", "edit"])
        XCTAssertEqual(sharedPeople.members.first?.avatar, "sprout")
        for avatar in ProfileFace.choices { XCTAssertNotNil(ProfileFace.image(avatar)?.tiffRepresentation) }

        let presence = BoardPresence()
        var viewing = PresenceContext(login: login, boardID: boardID, editing: note.id)
        presence.configure(viewing)
        let point = BoardPointerTracking.boardPoint(CGPoint(x: 180, y: 140),
            viewport: CGRect(x: 120, y: 80, width: 600, height: 500), zoom: 2)
        XCTAssertEqual(point, CGPoint(x: 150, y: 110))
        presence.point(at: point)
        var sawWebCursor = false
        var sawCursorExit = false
        defer { presence.close() }
        var sawEditor = false
        let webFile = directory.appendingPathComponent("web-input.txt")
        try Data("File from Chrome".utf8).write(to: webFile)
        let browserReady = directory.appendingPathComponent("browser-ready")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [script, address, boardID, note.id, webFile.path, browserReady.path]
        try task.run()
        defer { if task.isRunning { task.terminate() } }
        try await exerciseFollowing(presence, editorID: editorLogin.user.id, signalPath: browserReady.path)
        let deadline = Date().addingTimeInterval(55)
        while task.isRunning && !FileManager.default.fileExists(atPath: browserReady.path) && Date() < deadline {
            presence.pulse()
            let cursor = presence.cursors.items.first { $0.id == editorLogin.user.id }
            if !sawWebCursor, let cursor, abs(cursor.x - 265) <= 1, abs(cursor.y - 230) <= 1 {
                XCTAssertEqual(cursor.email, editorEmail)
                let renderer = ImageRenderer(content: BoardCursorLayer(feed: presence.cursors, zoom: 1)
                    .frame(width: 500, height: 340))
                let rendered = try XCTUnwrap(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: rendered)
                if let path = env["COTHINK_TEST_SCREENSHOT"] {
                    let screenshot = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("shared-cursor-mac.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: screenshot)
                }
                let tip = bitmap.colorAt(x: Int(cursor.x) + 3, y: Int(cursor.y) + 4)
                XCTAssertGreaterThan(try XCTUnwrap(tip).alphaComponent, 0.7)
                sawWebCursor = true
                presence.point(at: CGPoint(x: 300, y: 255))
            } else if sawWebCursor && !sawCursorExit && cursor == nil {
                sawCursorExit = true
                presence.point(at: nil)
            }
            if !sawEditor, let peer = presence.people.first(where: { $0.id == editorLogin.user.id && $0.objectIDs.contains(note.id) }) {
                XCTAssertEqual(peer.avatar, "honey")
                sawEditor = true
                viewing.editing = nil
                presence.configure(viewing)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard FileManager.default.fileExists(atPath: browserReady.path) else { XCTFail("Browser handshake incomplete. Saw remote cursor: \(sawWebCursor), saw pointer exit: \(sawCursorExit), last pointers: \(presence.cursors.items.map { [$0.x,$0.y] })"); return }
        XCTAssertTrue(sawWebCursor && sawCursorExit)
        XCTAssertTrue(sawEditor)
        await account.sync()
        XCTAssertEqual(model.board?.notes[0].text, "Edit from shared web account")
        let afterPicker = try await transport.people(boardID: boardID)
        XCTAssertEqual(afterPicker.members.first(where: { $0.role == "edit" })?.avatar, "honey")
        XCTAssertTrue(model.mutate { $0.notes[0].text = "Live edit from Mac" })
        await account.sync()
        XCTAssertNil(account.issue)
        while task.isRunning && Date() < deadline {
            presence.pulse()
            try await Task.sleep(for: .milliseconds(200))
        }
        guard !task.isRunning else { XCTFail("Chrome did not finish"); return }
        for _ in 0..<15 where presence.people.contains(where: { $0.id == editorLogin.user.id }) {
            presence.pulse()
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(presence.people.contains(where: { $0.id == editorLogin.user.id }))
        guard task.terminationStatus == 0 else { XCTFail("Chrome round-trip failed"); return }
        await account.sync()
        XCTAssertNil(account.issue)
        try model.refresh()
        XCTAssertEqual(model.pinnedListID, later.id)
        XCTAssertFalse(model.deskIDs.contains(boardID))
        XCTAssertEqual(Set(model.boardLists.filter { $0.boardIDs.contains(boardID) }.map(\.id)), [list.id, secondList.id])
        let updated = try XCTUnwrap(model.board)
        let editTimeFromWeb = try String(contentsOfFile: browserReady.path + ".edited", encoding: .utf8)
        XCTAssertEqual(updated.editedAt, Int64(editTimeFromWeb))
        let webNote = try XCTUnwrap(updated.notes.first { $0.id == note.id })
        XCTAssertEqual(webNote.text, "Changed in Chrome")
        XCTAssertEqual(webNote.x, note.x + 10)
        XCTAssertEqual(updated.notes.first { $0.id == reminders.id }?.reminderID, "local-native-id")
        let downloaded = try XCTUnwrap(updated.projectAssets.first { $0.name == "proof-web.txt" })
        let data = try Data(contentsOf: fileDirectory.appendingPathComponent(downloaded.relativePath))
        XCTAssertEqual(data, Data("File from Chrome".utf8))
        XCTAssertEqual(try store.lists().first?.title, "Work from Chrome")
        XCTAssertFalse(try CloudWorkspaceSync.isCompatible(store: store, server: server, userID: "another-account"))
        let wrongAccount = CloudWorkspaceSync(store: worker, server: server, userID: "another-account") { _ in
            XCTFail("a different account must be rejected before making requests")
            throw URLError(.cancelled)
        }
        do { try await wrongAccount.synchronize(); XCTFail("account isolation failed") }
        catch CloudSyncError.accountChanged {}

        let offline = CloudWorkspaceSync(store: worker, server: server, userID: login.user.id) { _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertTrue(model.mutate { $0.notes[0].text = "Edited offline" })
        do { try await offline.synchronize(); XCTFail("offline request unexpectedly succeeded") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertEqual(try store.get(boardID).notes[0].text, "Edited offline")

        try await editWebBoard(transport, id: boardID) { $0["title"] = "Web renamed while Mac was offline" }
        let reopened = try BoardStore(directory: directory)
        let reconnected = CloudWorkspaceSync(store: reopened, server: server, userID: login.user.id, send: transport.send)
        try await reconnected.synchronize()
        try model.refresh()
        XCTAssertEqual(model.board?.title, "Web renamed while Mac was offline")
        XCTAssertEqual(model.board?.notes[0].text, "Edited offline")
        let merged = try await transport.send(URLRequest(url: server.appendingPathComponent("api/workspace")))
        XCTAssertTrue(String(decoding: merged.0, as: UTF8.self).contains("Edited offline"))

        XCTAssertTrue(model.mutate { $0.title = "Mac conflicting title" })
        try await editWebBoard(transport, id: boardID) { $0["title"] = "Web conflicting title" }
        do { try await reconnected.synchronize(); XCTFail("simultaneous edits to the same title require a choice") }
        catch CloudSyncError.conflict {}
        XCTAssertEqual(try store.get(boardID).title, "Mac conflicting title")
        try await reconnected.synchronize(preference: .web)
        try model.refresh()
        XCTAssertEqual(model.board?.title, "Web conflicting title")
        let editorDirectory = directory.appendingPathComponent("editor-workspace")
        let editorStore = try BoardStore(directory: editorDirectory)
        let editorEngine = CloudWorkspaceSync(store: editorStore, server: server, userID: editorLogin.user.id, send: editorTransport.send)
        try await editorEngine.synchronize()
        var editorBoard = try editorStore.get(boardID)
        XCTAssertEqual(editorBoard.title, "Web conflicting title")
        editorBoard.title = "Shared edit from a second Mac account"
        _ = try editorStore.replace(editorBoard, expectedRevision: editorBoard.revision, actor: "shared-editor")
        try await editorEngine.synchronize()
        let ownerWorkspace = try await transport.send(URLRequest(url: server.appendingPathComponent("api/workspace")))
        XCTAssertTrue(String(decoding: ownerWorkspace.0, as: UTF8.self).contains(editorBoard.title))
        await editorTransport.logout()
        await account.signOut()
        XCTAssertNil(account.issue)
        XCTAssertNil(account.login)
        do { try await reconnected.synchronize(); XCTFail("a signed-out session must be rejected") }
        catch CloudSyncError.http(401) {}
    }

    @MainActor
    private func exerciseFollowing(_ presence: BoardPresence, editorID: String, signalPath: String) async throws {
        func wait(for suffix: String, until condition: () -> Bool = { true }) async throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: signalPath + suffix), condition() { return }
                presence.pulse()
                try await Task.sleep(for: .milliseconds(80))
            }
            XCTFail("Timed out waiting for " + suffix)
            throw NSError(domain: "Follow smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for " + suffix])
        }
        func camera(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> BoardCamera? {
            BoardCamera(viewport: CGRect(x: x*z-200, y: y*z-150, width: 400, height: 300), zoom: z)
        }
        try await wait(for: ".start-follow")
        presence.updateCamera(camera(2650,1820,1.25))
        try await wait(for: ".start-follow") { presence.canInvite(editorID) }
        await presence.invite("*")
        XCTAssertNil(presence.inviteError)
        try await wait(for: ".declined") { presence.invites.outgoing.isEmpty }
        XCTAssertTrue(presence.invites.followers.isEmpty)
        await presence.invite(editorID)
        XCTAssertNil(presence.inviteError)
        try await wait(for: ".pan") { presence.invites.followers.contains(editorID) }
        presence.updateCamera(camera(880,650,1.5))
        presence.point(at: CGPoint(x: 870, y: 645))
        try await wait(for: ".end-native")
        await presence.endTour()
        XCTAssertNil(presence.inviteError)
        try await wait(for: ".stopped") { presence.invites.followers.isEmpty }
        presence.updateCamera(camera(420,330,1))
        presence.point(at: CGPoint(x: 150, y: 110))
        try Data().write(to: URL(fileURLWithPath: signalPath + ".leader-reset"))
        let scroll = NSScrollView(frame: CGRect(x: 0,y: 0,width: 680,height: 480))
        let document = NSView(frame: CGRect(x: 0,y: 0,width: 5000,height: 4000))
        scroll.documentView = document
        let observer = ScrollViewportObserver.ObserverView()
        document.addSubview(observer)
        for step in 1...2 {
            let suffix = ".web-view-" + String(step)
            try await wait(for: suffix) { presence.availableViews.contains(editorID) }
            let expected = try JSONDecoder().decode(BoardCamera.self, from: Data(contentsOf: URL(fileURLWithPath: signalPath + suffix)))
            if step == 1 {
                try await wait(for: suffix) { presence.invites.incoming.first?.from == editorID }
                let invite = try XCTUnwrap(presence.invites.incoming.first)
                XCTAssertNil(presence.following)
                await presence.respond(to: invite, accept: true)
                XCTAssertNil(presence.inviteError)
            }
            try await wait(for: suffix) { presence.followedCamera == expected }
            observer.following = presence.followedCamera
            observer.scale = expected.fittedZoom(in: scroll.contentView.bounds.size)
            observer.scheduleFollow()
            try await wait(for: suffix) {
                let rect = scroll.contentView.bounds
                return abs(rect.midX / observer.scale - expected.x) < 2 && abs(rect.midY / observer.scale - expected.y) < 2
            }
            try Data().write(to: URL(fileURLWithPath: signalPath + ".mac-view-" + String(step)))
        }
        try await wait(for: ".end-web") { presence.following == nil && presence.followedCamera == nil }
        observer.following = nil
        let released = scroll.contentView.bounds
        observer.scheduleFollow()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scroll.contentView.bounds, released)
        let moved = CGPoint(x: released.minX + 40, y: released.minY + 40)
        scroll.contentView.scroll(to: moved)
        XCTAssertEqual(scroll.contentView.bounds.origin, moved)
        try Data().write(to: URL(fileURLWithPath: signalPath + ".independent"))
    }

    private func editWebBoard(_ transport: CloudTransport, id: String, edit: (inout [String: Any]) -> Void) async throws {
        let url = transport.login.server.appendingPathComponent("api/workspace")
        let (data, reply) = try await transport.send(URLRequest(url: url))
        XCTAssertEqual(reply.statusCode, 200)
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(remote["state"] as? [String: Any])
        var boards = try XCTUnwrap(state["boards"] as? [[String: Any]])
        let index = try XCTUnwrap(boards.firstIndex { $0["id"] as? String == id })
        edit(&boards[index])
        state["boards"] = boards
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expectedRevision": try XCTUnwrap(remote["revision"]), "state": state])
        let (_, result) = try await transport.send(request)
        XCTAssertEqual(result.statusCode, 200)
    }
}
