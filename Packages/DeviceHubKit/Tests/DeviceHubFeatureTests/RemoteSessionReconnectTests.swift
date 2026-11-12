import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import os
import Testing

@MainActor
@Suite("Automatic reconnection")
struct RemoteSessionReconnectTests {
    @Test("A stalled connect attempt is abandoned and retried")
    func stalledConnectAttemptIsRetried() async {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6000)
        let clock = TestClock()
        let firstAttempt = fixtureUUID(1)
        let secondAttempt = fixtureUUID(2)
        let connectCount = OSAllocatedUnfairLock(initialState: 0)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = UUIDGenerator(sequentialUUIDs([firstAttempt, secondAttempt]))
            $0.deviceHub.connect = { _ in
                connectCount.withLock { $0 += 1 }
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }

        await store.send(.availabilitySnapshotReceived([target])) {
            $0.session = ActiveRemoteSession(
                attemptID: firstAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await clock.advance(by: .seconds(15))
        await store.receive(\.connectAttemptTimedOut) {
            $0.session?.connectionError = .connectionLost
            $0.remediation = DeviceHubRemediation(error: .connectionLost)
        }

        await clock.advance(by: .seconds(3))
        await store.receive(\.reconnectScheduled) {
            $0.automaticReconnectAttempts = 1
            $0.remediation = nil
            $0.session = ActiveRemoteSession(
                attemptID: secondAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.automaticReconnectAttempts = 0
            $0.lifecycle = .background
            $0.session = nil
        }

        await clock.advance(by: .seconds(60))
        #expect(connectCount.withLock { $0 } == 2)
    }

    @Test("Consecutive frameless automatic failures back off exponentially")
    func automaticallyRetryableFailureReconnects() async {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6100)
        let clock = TestClock()
        let firstAttempt = fixtureUUID(3)
        let secondAttempt = fixtureUUID(4)
        let thirdAttempt = fixtureUUID(13)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = UUIDGenerator(
                sequentialUUIDs([firstAttempt, secondAttempt, thirdAttempt])
            )
            $0.deviceHub.connect = { _ in
                throw DeviceHubError.deviceOffline
            }
        }

        await store.send(.availabilitySnapshotReceived([target])) {
            $0.session = ActiveRemoteSession(
                attemptID: firstAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.receive(\.connectionResponse) {
            $0.session?.connectionError = .deviceOffline
            $0.remediation = DeviceHubRemediation(error: .deviceOffline)
        }

        await clock.advance(by: .seconds(3))
        await store.receive(\.reconnectScheduled) {
            $0.automaticReconnectAttempts = 1
            $0.remediation = nil
            $0.session = ActiveRemoteSession(
                attemptID: secondAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.receive(\.connectionResponse) {
            $0.session?.connectionError = .deviceOffline
            $0.remediation = DeviceHubRemediation(error: .deviceOffline)
        }

        // The second frame-less reconnect waits twice as long.
        await clock.advance(by: .seconds(6))
        await store.receive(\.reconnectScheduled) {
            $0.automaticReconnectAttempts = 2
            $0.remediation = nil
            $0.session = ActiveRemoteSession(
                attemptID: thirdAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.receive(\.connectionResponse) {
            $0.session?.connectionError = .deviceOffline
            $0.remediation = DeviceHubRemediation(error: .deviceOffline)
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.automaticReconnectAttempts = 0
            $0.lifecycle = .background
            $0.session = nil
        }

        await clock.advance(by: .seconds(60))
    }

    @Test("A failed attempt reconnects when the roster reports the target again")
    func failedAttemptReconnectsWhenTargetBecomesReachable() async {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6200)
        let clock = TestClock()
        let failedAttempt = fixtureUUID(5)
        let nextAttempt = fixtureUUID(6)

        var failedSession = ActiveRemoteSession(
            attemptID: failedAttempt,
            device: target,
            evaluatedAt: time
        )
        failedSession.connectionError = .deviceOffline

        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id,
                session: failedSession
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .constant(nextAttempt)
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }

        var offline = target
        offline.reachability = .unavailable

        await store.send(.availabilitySnapshotReceived([offline])) {
            $0.roster = DeviceRoster(devices: [offline])
            $0.session = nil
        }

        await store.send(.availabilitySnapshotReceived([target])) {
            $0.roster = DeviceRoster(devices: [target])
            $0.session = ActiveRemoteSession(
                attemptID: nextAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }

        await clock.advance(by: .seconds(60))
    }

    @Test("Returning to the foreground through inactive restarts the roster")
    func foregroundReturnRestartsRosterPipeline() async {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6400)
        let clock = TestClock()
        let attempt = fixtureUUID(10)
        let availability = AsyncStream<[DeviceSummary]>.makeStream()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .constant(attempt)
            $0.deviceHub.pairedDevices = { [target] }
            $0.deviceHub.availability = { availability.stream }
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }

        // iOS delivers a full background → foreground cycle as
        // active → inactive → background → inactive → active.
        await store.send(.appLifecycleChanged(.inactive)) {
            $0.lifecycle = .inactive
        }
        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
        }
        await store.send(.appLifecycleChanged(.inactive))
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }

        await store.receive(\.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isObservingAvailability = true
            $0.isLoadingRoster = false
            $0.session = ActiveRemoteSession(
                attemptID: attempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.isObservingAvailability = false
            $0.lifecycle = .background
            $0.session = nil
        }
        await clock.advance(by: .seconds(60))
    }

    @Test("Automatic retry stops when the user stops viewing")
    func automaticRetryStopsWhenViewingStops() async {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6300)
        let clock = TestClock()
        let firstAttempt = fixtureUUID(7)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .constant(firstAttempt)
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }

        await store.send(.availabilitySnapshotReceived([target])) {
            $0.session = ActiveRemoteSession(
                attemptID: firstAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await clock.advance(by: .seconds(15))
        await store.receive(\.connectAttemptTimedOut) {
            $0.session?.connectionError = .connectionLost
            $0.remediation = DeviceHubRemediation(error: .connectionLost)
        }

        await store.send(.stopViewingButtonTapped) {
            $0.isViewingStopped = true
            $0.session = nil
        }

        await clock.advance(by: .seconds(60))
    }

    @Test("The reconnect delay doubles and caps at the ceiling")
    func reconnectDelayEscalatesAndCaps() {
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 0)
                == .seconds(3)
        )
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 1)
                == .seconds(6)
        )
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 2)
                == .seconds(12)
        )
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 3)
                == .seconds(24)
        )
        // 48s is clamped to the ceiling, where it stays.
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 4)
                == RemoteSessionFeature.reconnectMaxDelay
        )
        #expect(
            RemoteSessionFeature.reconnectDelay(afterAttempts: 9)
                == RemoteSessionFeature.reconnectMaxDelay
        )
    }

    @Test("A delivered frame resets the automatic reconnect backoff")
    func deliveredFrameResetsBackoff() async throws {
        let target = device(id: "target", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 6500)
        let clock = TestClock()
        let attemptID = fixtureUUID(1)
        let generation = SessionGeneration(rawValue: fixtureUUID(2))
        let sessionID = DeviceSessionID(rawValue: fixtureUUID(3))
        let nextAttempt = fixtureUUID(4)
        let firstFrame = try remoteFrame(
            generation: generation,
            receivedAt: time,
            sequenceNumber: 1
        )
        var remoteState = RemoteSessionState(
            deviceID: target.id,
            generation: generation
        )
        _ = remoteState.apply(
            SessionUpdate(generation: generation, event: .phaseChanged(.ready))
        )
        _ = remoteState.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        _ = remoteState.apply(
            SessionUpdate(
                generation: generation,
                event: firstFrame.metadata.sessionEventForTesting
            )
        )
        var session = ActiveRemoteSession(
            attemptID: attemptID,
            device: target,
            evaluatedAt: time
        )
        session.frame = firstFrame
        session.remoteState = remoteState
        session.sessionID = sessionID

        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                automaticReconnectAttempts: 2,
                roster: DeviceRoster(devices: [target]),
                selectedDeviceID: target.id,
                session: session
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .constant(nextAttempt)
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }

        // Delivering a frame proves this reconnect cadence works, so the
        // backoff must restart from the base delay.
        let secondFrame = try remoteFrame(
            generation: generation,
            receivedAt: time,
            sequenceNumber: 2
        )
        await store.send(
            .frameReceived(
                attemptID: attemptID,
                sessionID: sessionID,
                frame: secondFrame
            )
        ) {
            _ = $0.session?.remoteState?.apply(
                SessionUpdate(
                    generation: generation,
                    event: secondFrame.metadata.sessionEventForTesting
                )
            )
            $0.automaticReconnectAttempts = 0
            $0.session?.frame = secondFrame
        }

        await store.send(
            .sessionStreamFailed(
                attemptID: attemptID,
                sessionID: sessionID,
                error: .connectionLost
            )
        ) {
            $0.session?.connectionError = .connectionLost
            $0.remediation = DeviceHubRemediation(error: .connectionLost)
        }

        // Backoff was reset, so the reconnect fires after the base 3s —
        // not after the 12s a stale count of 2 would demand.
        await clock.advance(by: .seconds(3))
        await store.receive(\.reconnectScheduled) {
            $0.automaticReconnectAttempts = 1
            $0.remediation = nil
            $0.session = ActiveRemoteSession(
                attemptID: nextAttempt,
                device: target,
                evaluatedAt: time
            )
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.automaticReconnectAttempts = 0
            $0.lifecycle = .background
            $0.session = nil
        }

        await clock.advance(by: .seconds(60))
    }
}

private func sequentialUUIDs(_ uuids: [UUID]) -> @Sendable () -> UUID {
    let state = OSAllocatedUnfairLock(initialState: uuids)
    return {
        state.withLock { ids in
            ids.isEmpty ? fixtureUUID(99) : ids.removeFirst()
        }
    }
}
