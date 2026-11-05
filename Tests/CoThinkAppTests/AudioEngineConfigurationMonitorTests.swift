import AVFoundation
import XCTest
@testable import CoThinkApp

final class AudioEngineConfigurationMonitorTests: XCTestCase {
    @MainActor
    func testConfigurationNotificationDoesNotRestartAStillRunningEngine() async throws {
        let center = NotificationCenter()
        var engineRunning = true
        let monitor = AudioEngineConfigurationMonitor(center: center, isRunning: { _ in engineRunning })
        let engine = AVAudioEngine()
        var recoveries = 0
        monitor.watch(engine) { recoveries += 1 }
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recoveries, 0, "A running engine must not be stopped and recreated")
        engineRunning = false
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<20 where recoveries == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(recoveries, 1, "A stopped engine needs recovery")
        monitor.stop()
    }
    @MainActor
    func testRecoveryDoesNotRestartAfterMicrophoneIsStopped() async throws {
        let recovery = AudioRecoveryScheduler(baseDelay: 20_000_000, maximumAttempts: 2)
        var restarts = 0
        XCTAssertTrue(recovery.schedule { restarts += 1 })
        recovery.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(recovery.attempts, 0)
        XCTAssertTrue(recovery.schedule { restarts += 1 })
        for _ in 0..<30 where restarts == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(restarts, 1)
        XCTAssertTrue(recovery.schedule { restarts += 1 })
        XCTAssertFalse(recovery.schedule { restarts += 100 })
        recovery.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(restarts, 1)
    }

    @MainActor
    func testOnlyCurrentEngineConfigurationChangesTriggerRecovery() async throws {
        let center = NotificationCenter()
        let monitor = AudioEngineConfigurationMonitor(center: center)
        let oldEngine = AVAudioEngine(), currentEngine = AVAudioEngine()
        var changes = 0
        monitor.watch(oldEngine) { changes += 100 }
        center.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        monitor.watch(currentEngine) { changes += 1 }
        center.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        center.post(name: .AVAudioEngineConfigurationChange, object: currentEngine)
        for _ in 0..<20 where changes == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(changes, 1)
        monitor.stop()
        center.post(name: .AVAudioEngineConfigurationChange, object: currentEngine)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(changes, 1)
    }
}
