import AVFoundation
import Speech
import SwiftUI

@MainActor
final class DictationController: ObservableObject {
    enum DictationPhase: Equatable {
        case idle
        case requestingAuthorization
        case listening
        case reconnecting
        case unavailable(String)
    }

    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var finalText = ""
    @Published private(set) var interimText = ""

    var preferredLocaleIdentifier: String?
    private(set) var activeLocale: Locale?
    var onUtterance: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var activeRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private let configurationMonitor = AudioEngineConfigurationMonitor()
    private let audioRecovery = AudioRecoveryScheduler()
    private var stableInputTask: Task<Void, Never>?
    private var awaitingSpeechAfterRecovery = false
    private var lastObservedTranscript = ""
    private var lastTranscriptActivity = Date()
    private var lastBestTranscript = ""
    private var transcriptBaseOffset = 0
    // Callbacks from a cancelled or superseded recognition task must not drive the live session.
    private var recognitionGeneration = 0

    // These writing systems do not separate words with spaces.
    private static let spacelessJoinLanguages: Set<String> = ["th", "ja", "zh", "km", "lo", "my"]
    private static let autoSendSilenceSeconds: TimeInterval = 2.0

    private var joinLocale: Locale { activeLocale ?? Locale.current }

    var combinedText: String {
        Self.joined([finalText, interimText], locale: joinLocale)
    }

    static func joined(_ parts: [String], locale: Locale) -> String {
        let separator = spacelessJoinLanguages.contains(locale.language.languageCode?.identifier ?? "") ? "" : " "
        return parts.filter { !$0.isEmpty }.joined(separator: separator)
    }

    static func mergedInput(base: String, combined: String, locale: Locale) -> String {
        Self.joined([
            base.trimmingCharacters(in: .whitespacesAndNewlines),
            combined.trimmingCharacters(in: .whitespacesAndNewlines),
        ], locale: locale)
    }

    func mergedInput(base: String, combined: String) -> String {
        Self.mergedInput(base: base, combined: combined, locale: joinLocale)
    }

    static func resolveLocale(preferred: String?, supported: [Locale]) -> Locale? {
        if let preferred, !preferred.isEmpty,
           let exact = supported.first(where: { normalizedIdentifier($0.identifier) == normalizedIdentifier(preferred) }) {
            return exact
        }
        for language in Locale.preferredLanguages {
            if let exact = supported.first(where: { normalizedIdentifier($0.identifier) == normalizedIdentifier(language) }) {
                return exact
            }
            let code = Locale(identifier: language).language.languageCode?.identifier
            if let code,
               let sameLanguage = supported
                   .filter({ $0.language.languageCode?.identifier == code })
                   .min(by: { $0.identifier < $1.identifier }) {
                return sameLanguage
            }
        }
        return supported.first(where: { normalizedIdentifier($0.identifier) == "en-us" })
    }

    // Identifiers arrive with mixed separators and case (Speech uses hyphens, other Locale input may use underscores).
    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageName(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    func toggle() {
        switch phase {
        case .listening, .requestingAuthorization, .reconnecting:
            stop()
        case .idle, .unavailable:
            start()
        }
    }

    func start() {
        guard phase != .listening, phase != .requestingAuthorization, phase != .reconnecting else { return }
        audioRecovery.cancel()
        phase = .requestingAuthorization
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.handleAuthorization(status)
            }
        }
    }

    func stop() {
        switch phase {
        case .listening:
            endSession()
        case .requestingAuthorization:
            stopSilenceDetection()
            phase = .idle
        case .reconnecting:
            audioRecovery.cancel()
            phase = .idle
        case .idle, .unavailable:
            break
        }
    }

    private func handleAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) {
        guard phase == .requestingAuthorization else { return }
        switch status {
        case .authorized:
            beginListening()
        case .denied:
            phase = .unavailable("Allow speech recognition in System Settings › Privacy & Security, then try again.")
        case .restricted:
            phase = .unavailable("Speech recognition is restricted on this device.")
        default:
            phase = .unavailable("Speech recognition is not available right now. Try again.")
        }
    }

    private func beginListening(preserving retainedText: String = "") {
        let locale = Self.resolveLocale(preferred: preferredLocaleIdentifier, supported: Array(SFSpeechRecognizer.supportedLocales()))
        activeLocale = locale
        guard let locale else {
            phase = .unavailable("Speech recognition is not available right now. Try again.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            phase = .unavailable("\(Self.languageName(locale)) speech recognition is not available right now. Try again.")
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            phase = .unavailable("No microphone was found. Connect one and try again.")
            return
        }
        lastObservedTranscript = ""
        lastTranscriptActivity = Date()
        lastBestTranscript = ""
        transcriptBaseOffset = 0
        finalText = retainedText
        interimText = ""
        awaitingSpeechAfterRecovery = !retainedText.isEmpty
        audioEngine = engine
        activeRecognizer = recognizer
        configurationMonitor.watch(engine) { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.handleAudioConfigurationChange(engine)
        }
        startRecognitionTask()
        phase = .listening
        do {
            engine.prepare()
            try engine.start()
        } catch {
            tearDownAudio()
            phase = .unavailable("Microphone is unavailable. \(error.localizedDescription)")
            return
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateSilenceCommit() }
        }
        stableInputTask?.cancel()
        stableInputTask = Task { [weak self, weak engine] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, let engine, self.audioEngine === engine, self.phase == .listening else { return }
            self.audioRecovery.markStable()
        }
    }

    private func handleAudioConfigurationChange(_ engine: AVAudioEngine) {
        guard phase == .listening, audioEngine === engine else { return }
        let retainedText = combinedText
        tearDownAudio()
        finalText = retainedText
        interimText = ""
        phase = .reconnecting
        let scheduled = audioRecovery.schedule { [weak self] in
            guard let self, self.phase == .reconnecting else { return }
            self.beginListening(preserving: retainedText)
        }
        if !scheduled { phase = .unavailable("The audio device keeps changing. Check the microphone and start again.") }
    }

    private func startRecognitionTask() {
        guard let recognizer = activeRecognizer, let engine = audioEngine else { return }
        recognitionGeneration += 1
        let generation = recognitionGeneration
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in newRequest.append(buffer) }
        request?.endAudio()
        task?.cancel()
        request = newRequest
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                self.handleRecognitionResult(result, error: error)
            }
        }
    }

    // A restarted request begins with an empty transcript, so the session offset resets with it.
    private func restartRecognition() {
        guard let activeRecognizer, activeRecognizer.isAvailable else {
            endSession()
            phase = .unavailable("Speech recognition stopped. Try again.")
            return
        }
        lastBestTranscript = ""
        transcriptBaseOffset = 0
        startRecognitionTask()
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard phase == .listening else { return }
        if let result {
            let best = result.bestTranscription.formattedString
            lastBestTranscript = best
            interimText = String(best.dropFirst(transcriptBaseOffset))
            if !interimText.isEmpty { awaitingSpeechAfterRecovery = false }
            if result.isFinal {
                if !awaitingSpeechAfterRecovery { commitUtterance() }
                if phase == .listening { restartRecognition() }
                return
            }
        }
        if error != nil {
            if !awaitingSpeechAfterRecovery { commitUtterance() }
            if phase == .listening { restartRecognition() }
        }
    }

    private func endSession() {
        let retainedText = combinedText
        audioRecovery.cancel()
        tearDownAudio()
        finalText = retainedText
        interimText = ""
        awaitingSpeechAfterRecovery = false
        phase = .idle
    }

    private func tearDownAudio() {
        stopSilenceDetection()
        stableInputTask?.cancel(); stableInputTask = nil
        configurationMonitor.stop()
        let engine = audioEngine
        let recognitionRequest = request
        let recognitionTask = task
        audioEngine = nil
        activeRecognizer = nil
        request = nil
        task = nil
        recognitionGeneration += 1
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }

    private func commitUtterance() {
        let text = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptBaseOffset = lastBestTranscript.count
        finalText = ""
        interimText = ""
        lastObservedTranscript = ""
        lastTranscriptActivity = Date()
        guard !text.isEmpty else { return }
        onUtterance?(text)
    }

    private func evaluateSilenceCommit() {
        guard phase == .listening else { return }
        let transcript = combinedText
        if transcript != lastObservedTranscript {
            lastObservedTranscript = transcript
            lastTranscriptActivity = Date()
            if !interimText.isEmpty { awaitingSpeechAfterRecovery = false }
            return
        }
        guard !awaitingSpeechAfterRecovery else { return }
        guard Self.shouldAutoSend(
            transcriptIsEmpty: transcript.isEmpty,
            secondsSinceSpeech: Date().timeIntervalSince(lastTranscriptActivity),
            silenceLimit: Self.autoSendSilenceSeconds
        ) else { return }
        commitUtterance()
    }

    static func shouldAutoSend(transcriptIsEmpty: Bool, secondsSinceSpeech: TimeInterval, silenceLimit: TimeInterval) -> Bool {
        !transcriptIsEmpty && secondsSinceSpeech >= silenceLimit
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    deinit {
        silenceTimer?.invalidate()
        stableInputTask?.cancel()
    }
}
