import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import Foundation

/// Screen-first product logic for discovering, pairing, viewing, and
/// controlling exactly one nearby device.
@Reducer
public struct RemoteSessionFeature {
    /// Bounds one connection attempt so a stalled handshake surfaces as an
    /// automatic failure instead of an endless connecting state.
    static let connectAttemptTimeout: Duration = .seconds(15)

    /// Base delay before an automatically retryable failure reconnects.
    static let reconnectBaseDelay: Duration = .seconds(3)

    /// Ceiling for the exponential automatic-retry backoff.
    static let reconnectMaxDelay: Duration = .seconds(30)

    /// Gap between the two home taps that open the target's app switcher,
    /// paced to sit inside the system's double-click window.
    static let appSwitcherHomeTapGap: Duration = .milliseconds(200)

    /// Grows the delay between consecutive automatic reconnects that never
    /// delivered a frame, so a deterministic downstream failure cannot
    /// hot-loop the connection.
    static func reconnectDelay(
        afterAttempts attempts: Int
    ) -> Duration {
        let seconds = min(
            reconnectMaxDelay.components.seconds,
            reconnectBaseDelay.components.seconds
                << min(attempts, 4)
        )
        return .seconds(seconds)
    }

    enum CancelID {
        case appSwitcherGesture
        case availability
        case commands
        case connect
        case connectTimeout
        case frames
        case lifecycle
        case reconnect
        case rosterLoad
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.deviceHub) var deviceHub
    @Dependency(\.uuid) var uuid

    let sessionCoordinator: DeviceSessionCoordinator

    public init() {
        sessionCoordinator = DeviceSessionCoordinator()
    }

    public var body: some ReducerOf<Self> {
        CombineReducers {
            Reduce(reduceLifecycle)
            Reduce(reduceSelection)
            Reduce(reducePresentation)
            Reduce(reduceConnection)
            Reduce(reduceMedia)
            Reduce(reduceInput)
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
