import XCTest
@testable import CoThinkApp

final class DictationTextTests: XCTestCase {
    @MainActor
    func testThaiSegmentsJoinWithoutSpaces() {
        XCTAssertEqual(DictationController.joined(["สวัสดี", "ครับ"], locale: Locale(identifier: "th_TH")), "สวัสดีครับ")
    }

    @MainActor
    func testThaiMergedInputGluesBaseAndDictation() {
        XCTAssertEqual(
            DictationController.mergedInput(base: "สวัสดี", combined: "ครับทดสอบ", locale: Locale(identifier: "th_TH")),
            "สวัสดีครับทดสอบ"
        )
    }

    @MainActor
    func testEnglishJoinKeepsSingleSpaces() {
        XCTAssertEqual(DictationController.joined(["Hello", "world"], locale: Locale(identifier: "en_US")), "Hello world")
        XCTAssertEqual(
            DictationController.mergedInput(base: "Hello", combined: "world", locale: Locale(identifier: "en_US")),
            "Hello world"
        )
    }

    @MainActor
    func testSpacelessJoinLanguages() {
        XCTAssertEqual(DictationController.joined(["ก", "ข"], locale: Locale(identifier: "th_TH")), "กข")
        XCTAssertEqual(DictationController.joined(["あ", "い"], locale: Locale(identifier: "ja_JP")), "あい")
        XCTAssertEqual(DictationController.joined(["你", "好"], locale: Locale(identifier: "zh_CN")), "你好")
        XCTAssertEqual(DictationController.joined(["ក", "ខ"], locale: Locale(identifier: "km_KH")), "កខ")
        XCTAssertEqual(DictationController.joined(["ກ", "ຂ"], locale: Locale(identifier: "lo_LA")), "ກຂ")
        XCTAssertEqual(DictationController.joined(["က", "ခ"], locale: Locale(identifier: "my_MM")), "ကခ")
    }

    @MainActor
    func testResolveLocalePrefersExactPreferredMatch() {
        let supported = [Locale(identifier: "en_US"), Locale(identifier: "th_TH")]
        XCTAssertEqual(
            DictationController.resolveLocale(preferred: "th-TH", supported: supported)?.language.languageCode?.identifier,
            "th"
        )
    }

    @MainActor
    func testResolveLocaleAutomaticFallsBackToPreferredLanguageCode() {
        XCTAssertTrue(
            Locale.preferredLanguages.first?.hasPrefix("en") == true,
            "this expectation encodes a machine whose preferred languages start with en-TH"
        )
        let supported = [Locale(identifier: "en_US"), Locale(identifier: "th_TH")]
        XCTAssertEqual(
            DictationController.resolveLocale(preferred: nil, supported: supported)?.language.languageCode?.identifier,
            "en"
        )
    }

    @MainActor
    func testResolveLocaleReturnsNilWhenNothingMatches() {
        XCTAssertNil(DictationController.resolveLocale(preferred: "th-TH", supported: [Locale(identifier: "fr_FR")]))
    }

    @MainActor
    func testSilenceAutoSendDecision() {
        XCTAssertTrue(DictationController.shouldAutoSend(transcriptIsEmpty: false, secondsSinceSpeech: 2.0, silenceLimit: 2.0))
        XCTAssertFalse(DictationController.shouldAutoSend(transcriptIsEmpty: false, secondsSinceSpeech: 1.9, silenceLimit: 2.0))
        XCTAssertFalse(DictationController.shouldAutoSend(transcriptIsEmpty: true, secondsSinceSpeech: 2.0, silenceLimit: 2.0))
        XCTAssertFalse(DictationController.shouldAutoSend(transcriptIsEmpty: true, secondsSinceSpeech: 10.0, silenceLimit: 2.0))
    }
}
