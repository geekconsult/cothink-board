import AVFoundation
import Foundation

@MainActor
final class AudioEngineConfigurationMonitor {
    private let center: NotificationCenter
    private let isRunning: (AVAudioEngine) -> Bool
    private var observer: NSObjectProtocol?
    private var generation = UUID()

    init(center: NotificationCenter = .default, isRunning: @escaping (AVAudioEngine) -> Bool = { $0.isRunning }) {
        self.center = center
        self.isRunning = isRunning
    }

    func watch(_ engine: AVAudioEngine, onChange: @escaping @MainActor () -> Void) {
        stop()
        let token = generation
        observer = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.generation == token, !self.isRunning(engine) else { return }
                onChange()
            }
        }
    }

    func stop() {
        generation = UUID()
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }
}

@MainActor
final class AudioRecoveryScheduler {
    private let baseDelay: UInt64
    private let maximumAttempts: Int
    private var task: Task<Void, Never>?
    private(set) var attempts = 0

    init(baseDelay: UInt64 = 400_000_000, maximumAttempts: Int = 4) {
        self.baseDelay = baseDelay
        self.maximumAttempts = maximumAttempts
    }

    func schedule(_ operation: @escaping @MainActor () -> Void) -> Bool {
        attempts += 1
        guard attempts <= maximumAttempts else { return false }
        task?.cancel()
        let delay = UInt64(attempts) * baseDelay
        task = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            operation()
        }
        return true
    }

    func markStable() { attempts = 0 }

    func cancel() {
        task?.cancel()
        task = nil
        attempts = 0
    }

    deinit { task?.cancel() }
}
