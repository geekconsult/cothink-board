import XCTest
@testable import BoardCore

final class CloudOriginMigrationTests: XCTestCase {
    func testOnlyMatchingProductionAccountKeepsItsSyncCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BoardStore(directory: root)
        let old = CloudAccount(server: "https://cothink.denyume.cloud", userID: "owner")
        let new = try XCTUnwrap(URL(string: "https://cothink.aigeekconsult.com"))
        let local = try store.create(title: "Offline board", actor: "user")
        let (workspace, _) = try store.cloudSnapshot()
        try store.bindCloud(old)
        let baseline = CloudWorkspaceDocument.empty
        try store.applyCloud(workspace, replacing: workspace, checkpoint: CloudCheckpoint(account: old, baseline: baseline))

        try CloudWorkspaceSync.migrateCoThinkProductionOrigin(store: store, server: new, userID: "other")
        XCTAssertFalse(try CloudWorkspaceSync.isCompatible(store: store, server: new, userID: "other"))
        try CloudWorkspaceSync.migrateCoThinkProductionOrigin(store: store, server: new, userID: old.userID)
        XCTAssertTrue(try CloudWorkspaceSync.isCompatible(store: store, server: new, userID: old.userID))
        XCTAssertEqual(try store.cloudSnapshot().1?.baseline, baseline)
        XCTAssertEqual(try store.get(local.id), local)
    }
}
