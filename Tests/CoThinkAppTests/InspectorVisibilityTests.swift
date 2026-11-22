import XCTest
@testable import CoThinkApp

final class InspectorVisibilityTests: XCTestCase {
    func testAutomaticFollowsSelection() {
        XCTAssertFalse(InspectorVisibility.automatic.isVisible(hasSelection: false))
        XCTAssertTrue(InspectorVisibility.automatic.isVisible(hasSelection: true))
    }

    func testExplicitChoicesIgnoreSelection() {
        for selection in [false, true] {
            XCTAssertTrue(InspectorVisibility.shown.isVisible(hasSelection: selection))
            XCTAssertFalse(InspectorVisibility.hidden.isVisible(hasSelection: selection))
        }
    }

    func testToggleCreatesExplicitChoiceFromCurrentVisibility() {
        XCTAssertEqual(InspectorVisibility.automatic.toggled(hasSelection: false), .shown)
        XCTAssertEqual(InspectorVisibility.automatic.toggled(hasSelection: true), .hidden)
        XCTAssertEqual(InspectorVisibility.shown.toggled(hasSelection: false), .hidden)
        XCTAssertEqual(InspectorVisibility.hidden.toggled(hasSelection: true), .shown)
    }
    @MainActor
    func testSelectAllKeepsSelectionWhenDraftCannotBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cothink-inspector-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BoardViewModel(storeDirectory: directory)
        model.addNote(x: 100, y: 100)
        let selected = try XCTUnwrap(model.selectedNoteID)
        model.draftBlocked = true
        model.selectAllNotes()
        XCTAssertEqual(model.selectedNoteID, selected)
        XCTAssertTrue(model.selectedNoteIDs.isEmpty)
    }
}
