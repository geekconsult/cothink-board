import XCTest
@testable import CoThinkApp
import BoardCore

final class NoteContentSizingTests: XCTestCase {
    func testFitMeasuresTextAndPreservesAttachmentSpace() {
        let short = Note(text: "Short", width: 300, height: 180)
        let long = Note(text: "A much longer piece of text", width: 300, height: 180)
        let shortSize = NoteContentSizing.fittedSize(for: short)!
        let longSize = NoteContentSizing.fittedSize(for: long)!
        XCTAssertGreaterThan(longSize.width, shortSize.width)
        XCTAssertLessThan(shortSize.height, short.height)
        var withAttachment = short
        withAttachment.assetIDs = ["file"]
        let attachedSize = NoteContentSizing.fittedSize(for: withAttachment)!
        XCTAssertGreaterThanOrEqual(attachedSize.width, withAttachment.width)
        XCTAssertGreaterThanOrEqual(attachedSize.height, withAttachment.height)
        XCTAssertNil(NoteContentSizing.fittedSize(for: Note(shape: .line)))
    }

    func testShortTextStaysAtMinimumHeight() {
        let oneLiner = NoteContentSizing.height(for: "New idea", fontSize: 15, width: 190)
        XCTAssertEqual(oneLiner, NoteContentSizing.height(for: "", fontSize: 15, width: 200))
        XCTAssertGreaterThanOrEqual(oneLiner, NoteContentSizing.minimumHeight)
        XCTAssertLessThan(oneLiner, 60)
    }

    func testLongTextNeedsTallerNote() {
        let line = "The quick brown fox jumps over the lazy dog again and again"
        let long = Array(repeating: line, count: 6).joined(separator: " ")
        let tall = NoteContentSizing.height(for: long, fontSize: 15, width: 190)
        let short = NoteContentSizing.height(for: line, fontSize: 15, width: 190)
        XCTAssertGreaterThan(tall, 150)
        XCTAssertGreaterThan(tall, short)
    }

    func testWiderNoteNeedsLessHeightForSameText() {
        let text = Array(repeating: "english words with spaces ", count: 20).joined()
        let narrow = NoteContentSizing.height(for: text, fontSize: 15, width: 190)
        let wide = NoteContentSizing.height(for: text, fontSize: 15, width: 600)
        XCTAssertLessThan(wide, narrow)
        XCTAssertGreaterThan(narrow, NoteContentSizing.minimumHeight)
    }

    func testLargerFontNeedsMoreHeightForSameText() {
        let text = Array(repeating: "english words with spaces ", count: 20).joined()
        let small = NoteContentSizing.height(for: text, fontSize: 12, width: 190)
        let big = NoteContentSizing.height(for: text, fontSize: 30, width: 190)
        XCTAssertGreaterThan(big, small)
    }
}
