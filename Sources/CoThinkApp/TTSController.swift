import AVFoundation
import PiChatCore

/// Speaks agent replies with the on-device speech synthesizer.
/// Thai text gets the installed th_TH voice (Kanya), other text uses the system default.
@MainActor
final class TTSController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechStateDelegate()

    override init() {
        super.init()
        synthesizer.delegate = delegate
        delegate.onStateChange = { [weak self] speaking in
            Task { @MainActor in self?.isSpeaking = speaking }
        }
    }

    func speak(_ raw: String) {
        let text = Self.cleanedSpeechText(raw)
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if TextScript.isThai(text) {
            utterance.voice = AVSpeechSynthesisVoice(language: "th-TH") ?? utterance.voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US") ?? utterance.voice
        }
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Removes code blocks and markdown noise so the voice reads prose, not syntax.
    static func cleanedSpeechText(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "```") {
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])
            let closingIndex = after.range(of: "```")
            let remainder = closingIndex.map { String(after[$0.upperBound...]) } ?? after
            text = before + remainder
        }
        for symbol in ["**", "__", "`", "#", ">", "|"] {
            text = text.replacingOccurrences(of: symbol, with: " ")
        }
        let squashed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return squashed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SpeechStateDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onStateChange: ((Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStateChange?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onStateChange?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onStateChange?(false)
    }
}
