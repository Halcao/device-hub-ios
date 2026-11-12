import ComposableArchitecture
import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("App switcher button")
struct RemoteSessionAppSwitcherTests {
    @Test("The button sends two paced home taps")
    func appSwitcherButtonSendsDoubleHome() async throws {
        let fixture = AppSwitcherFixture()
        let recorder = SessionRecorder()
        let clock = TestClock()
        let store = try await fixture.readyStore(
            recorder: recorder,
            clock: clock
        )

        await store.send(.appSwitcherButtonTapped)

        // The first home tap goes out immediately.
        await store.receive(\.buttonTapped)
        await store.receive(\.commandFinished)

        // The second follows inside the double-click window.
        await clock.advance(
            by: RemoteSessionFeature.appSwitcherHomeTapGap
        )
        await store.receive(\.buttonTapped)
        await store.receive(\.commandFinished)

        await recorder.waitForCommandCount(2)
        let recorded = await recorder.commands()
        expectNoDifference(recorded, [.buttonTap(.home), .buttonTap(.home)])

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }

    @Test("Teardown cancels the second home tap")
    func teardownCancelsSecondHomeTap() async throws {
        let fixture = AppSwitcherFixture()
        let recorder = SessionRecorder()
        let clock = TestClock()
        let store = try await fixture.readyStore(
            recorder: recorder,
            clock: clock
        )

        await store.send(.appSwitcherButtonTapped)
        await store.receive(\.buttonTapped)
        await store.receive(\.commandFinished)

        // Leaving the session must stop the shortcut: a lone second home
        // tap would send the target to its home screen instead.
        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await clock.advance(by: .milliseconds(700))
        await recorder.waitForCommandCount(2)
        let recorded = await recorder.commands()
        expectNoDifference(
            recorded,
            [.buttonTap(.home), .releaseAllInput]
        )
    }

    @Test("The button does nothing without an authorized live session")
    func appSwitcherButtonIsGatedOnAuthorization() async throws {
        let fixture = AppSwitcherFixture()
        let recorder = SessionRecorder()
        let store = try await fixture.readyStore(
            recorder: recorder,
            clock: TestClock()
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await recorder.waitForCommandCount(1)

        await store.send(.appSwitcherButtonTapped)
        let recorded = await recorder.commands()
        expectNoDifference(recorded, [.releaseAllInput])
    }
}

/// Establishes one input-authorized session over a recording transport.
private struct AppSwitcherFixture {
    let attemptID = fixtureUUID(60)
    let device = DeviceSummary(
        id: DeviceID(rawValue: "switcher"),
        name: "Test iPhone",
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: .reachable
    )
    let generation = SessionGeneration(rawValue: fixtureUUID(61))
    let sessionID = DeviceSessionID(rawValue: fixtureUUID(62))
    let time = Date(timeIntervalSince1970: 5300)

    @MainActor
    func readyStore(
        recorder: SessionRecorder,
        clock: TestClock<Duration>
    ) async throws -> TestStoreOf<RemoteSessionFeature> {
        let events = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frames = AsyncStream<RemoteDisplayFrame>.makeStream()
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.deviceHub.connect = { _ in
                transportSession(
                    id: sessionID,
                    device: device,
                    events: events.stream,
                    frames: frames.stream,
                    recorder: recorder
                )
            }
            $0.uuid = .constant(attemptID)
        }

        try await establishInputReadyRotationSession(
            in: store,
            context: RotationSessionTestContext(
                time: time,
                device: device,
                attemptID: attemptID,
                sessionID: sessionID,
                generation: generation
            )
        )
        #expect(store.state.acceptsInput)
        return store
    }
}
