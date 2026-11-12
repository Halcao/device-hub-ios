import SwiftUI

/// Which canvas edge the floating controls call home.
enum RemoteFloatingControlsEdge: String, CaseIterable, Equatable {
    case leading
    case trailing
}

/// The target control a tap in the cluster activates.
enum RemoteFloatingControlSlot: Equatable {
    case home
    case appSwitcher
    case lock
}

/// Pure geometry for the draggable floating control cluster.
enum RemoteFloatingControlsLayout {
    /// Space between the cluster and the edge it rests on.
    static let edgeInset: CGFloat = 12

    /// Resting center for a stored edge and vertical fraction.
    static func center(
        edge: RemoteFloatingControlsEdge,
        verticalFraction: Double,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGPoint {
        let rawX: CGFloat = edge == .leading
            ? edgeInset + clusterSize.width / 2
            : canvasSize.width - edgeInset - clusterSize.width / 2
        return CGPoint(
            x: clampedX(rawX, canvasSize: canvasSize, clusterSize: clusterSize),
            y: centerY(
                fraction: verticalFraction,
                canvasSize: canvasSize,
                clusterSize: clusterSize
            )
        )
    }

    /// Vertical position of a fraction in `0 ... 1` over the travel the
    /// cluster can cover while staying fully inside the canvas.
    static func centerY(
        fraction: Double,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGFloat {
        let travel = canvasSize.height - clusterSize.height
        guard travel > 0 else {
            return canvasSize.height / 2
        }
        return clusterSize.height / 2 + CGFloat(fraction) * travel
    }

    /// Stored fraction for a resting center, clamped to the canvas.
    static func verticalFraction(
        centerY: CGFloat,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> Double {
        let travel = canvasSize.height - clusterSize.height
        guard travel > 0 else {
            return 0.5
        }
        let raw =
            (centerY - clusterSize.height / 2) / travel
        return Double(min(max(raw, 0), 1))
    }

    /// The edge whose inset is closest to a dragged center.
    static func nearestEdge(
        centerX: CGFloat,
        canvasWidth: CGFloat
    ) -> RemoteFloatingControlsEdge {
        centerX * 2 < canvasWidth ? .leading : .trailing
    }

    /// Clamps a dragged center to keep the cluster fully inside the
    /// canvas. The dropped height is preserved exactly: the cluster only
    /// ever snaps to an edge, never to a preferred height.
    static func clampedCenter(
        rawCenter: CGPoint,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clampedX(
                rawCenter.x,
                canvasSize: canvasSize,
                clusterSize: clusterSize
            ),
            y: clampedY(
                rawCenter.y,
                canvasSize: canvasSize,
                clusterSize: clusterSize
            )
        )
    }

    /// The control a cluster-local tap activates. The three icons are
    /// equal-height slices, so plain thirds track them without
    /// hard-coding the padding and spacing constants.
    static func slot(
        centerY: CGFloat,
        clusterHeight: CGFloat
    ) -> RemoteFloatingControlSlot {
        guard clusterHeight > 0 else {
            return .appSwitcher
        }
        let slice = centerY / clusterHeight
        if slice < 1.0 / 3.0 {
            return .home
        }
        if slice < 2.0 / 3.0 {
            return .appSwitcher
        }
        return .lock
    }

    /// Horizontal clamp that keeps the cluster inside the canvas with its
    /// edge inset, falling back to the middle when it cannot fit.
    private static func clampedX(
        _ x: CGFloat,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGFloat {
        let lower = edgeInset + clusterSize.width / 2
        let upper = canvasSize.width - edgeInset - clusterSize.width / 2
        guard lower < upper else {
            return canvasSize.width / 2
        }
        return min(max(x, lower), upper)
    }

    /// Vertical clamp that keeps the cluster inside the canvas, falling
    /// back to the middle when it is taller than the canvas.
    private static func clampedY(
        _ y: CGFloat,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGFloat {
        let lower = clusterSize.height / 2
        let upper = canvasSize.height - clusterSize.height / 2
        guard lower < upper else {
            return canvasSize.height / 2
        }
        return min(max(y, lower), upper)
    }
}

/// Always-reachable target controls pinned to the canvas edge.
///
/// The controller's own edge swipes can still collide with iPadOS system
/// gestures even while the bottom-edge deferral is active, so the most
/// common target gestures stay one tap away instead. Hold the cluster to
/// drag it: on release it springs to the nearest edge at the exact height
/// it was dropped, and the placement survives relaunches.
struct RemoteFloatingControls: View {
    /// How long a touch must hold before the cluster can be dragged.
    private static let holdDuration: TimeInterval = 0.35
    /// How far a touch may drift during the hold and still tap.
    private static let tapDriftTolerance: CGFloat = 20

    let acceptsInput: Bool
    let homeButtonTapped: () -> Void
    let appSwitcherButtonTapped: () -> Void
    let lockButtonTapped: () -> Void

    @AppStorage("devicehub.remoteFloatingControls.edge")
    private var storedEdgeRaw = RemoteFloatingControlsEdge.trailing.rawValue
    @AppStorage("devicehub.remoteFloatingControls.verticalFraction")
    private var storedVerticalFraction = 0.5

    @State private var liveCenter: CGPoint?
    @State private var dragAnchor: CGPoint?
    @State private var isDragging = false
    @State private var snapTargetEdge: RemoteFloatingControlsEdge?
    @State private var clusterSize = CGSize.zero
    @State private var holdCheckTask: Task<Void, Never>?
    @State private var touchStartedAt: Date?
    @State private var touchDrift = CGSize.zero
    @State private var touchAborted = false

    var body: some View {
        GeometryReader { proxy in
            controls
                .gesture(touchGesture(canvasSize: proxy.size))
                .position(
                    liveCenter ?? restingCenter(canvasSize: proxy.size)
                )
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: {
                    clusterSize = $0
                }
                .onDisappear {
                    holdCheckTask?.cancel()
                }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            control("Home", systemImage: "house.fill", action: homeButtonTapped)
            control(
                "App Switcher",
                systemImage: "rectangle.on.rectangle",
                action: appSwitcherButtonTapped
            )
            control("Lock", systemImage: "lock.fill", action: lockButtonTapped)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        // The whole capsule is one hit target. With only the icons
        // testable, presses on the padding and gaps fall through to the
        // mirrored screen behind the cluster.
        .contentShape(.capsule)
        // No opaque fill behind the glass: a background layered inside
        // the effect hides the refraction and highlights that make it
        // read as Liquid Glass.
        .glassEffect(.regular.interactive(), in: .capsule)
        .opacity(acceptsInput || isDragging ? 1 : 0.4)
        .scaleEffect(isDragging ? 1.08 : 1)
        .animation(
            .spring(response: 0.25, dampingFraction: 0.7),
            value: isDragging
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-floating-controls")
    }

    /// Plain icons, not buttons: a button wins touches from any
    /// container gesture, which is why hold-to-drag never fired. One
    /// gesture on the capsule owns every touch and routes quick taps
    /// itself; VoiceOver keeps direct actions.
    private func control(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: 42, height: 42)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard acceptsInput else {
                    return
                }
                action()
            }
    }

    private func touchGesture(canvasSize: CGSize) -> some Gesture {
        // minimumDistance 0 claims the touch immediately, so a
        // stationary hold can be timed here instead of depending on a
        // LongPressGesture that never wins recognition.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                touchChanged(value, canvasSize: canvasSize)
            }
            .onEnded { value in
                touchEnded(value, canvasSize: canvasSize)
            }
    }

    private func touchChanged(
        _ value: DragGesture.Value,
        canvasSize: CGSize
    ) {
        if isStaleTouch(now: value.time) {
            // A previous gesture never ended; treat this as a new one.
            touchStartedAt = nil
            touchAborted = false
        }
        if touchStartedAt == nil {
            touchStartedAt = value.time
            touchDrift = value.translation
            scheduleHoldCheck(canvasSize: canvasSize)
            return
        }
        advanceTouch(value, canvasSize: canvasSize)
    }

    private func advanceTouch(
        _ value: DragGesture.Value,
        canvasSize: CGSize
    ) {
        guard !touchAborted else {
            return
        }
        if isDragging {
            updateDrag(
                translation: value.translation,
                canvasSize: canvasSize
            )
            return
        }
        touchDrift = value.translation
        let drift =
            abs(value.translation.width) + abs(value.translation.height)
        if drift > Self.tapDriftTolerance {
            // Too much movement too early: neither a tap nor a hold.
            touchAborted = true
            holdCheckTask?.cancel()
        }
    }

    /// A touch record older than a second that never became a drag is
    /// left over from a gesture that never ended.
    private func isStaleTouch(now: Date) -> Bool {
        guard let touchStartedAt, !isDragging else {
            return false
        }
        return now.timeIntervalSince(touchStartedAt) > 1
    }

    private func scheduleHoldCheck(canvasSize: CGSize) {
        holdCheckTask?.cancel()
        holdCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled else {
                return
            }
            guard touchStartedAt != nil, !touchAborted, !isDragging else {
                return
            }
            beginDrag(canvasSize: canvasSize)
        }
    }

    private func touchEnded(
        _ value: DragGesture.Value,
        canvasSize: CGSize
    ) {
        holdCheckTask?.cancel()
        holdCheckTask = nil
        defer {
            touchStartedAt = nil
            touchDrift = .zero
            touchAborted = false
        }

        if isDragging {
            endDrag(canvasSize: canvasSize)
            return
        }

        // A quick, still touch is a tap; a slow release was a hold that
        // never became a drag and activates nothing.
        guard !touchAborted, let touchStartedAt else {
            return
        }
        let hold = value.time.timeIntervalSince(touchStartedAt)
        guard hold < Self.holdDuration, acceptsInput else {
            return
        }
        switch RemoteFloatingControlsLayout.slot(
            centerY: value.startLocation.y,
            clusterHeight: clusterSize.height
        ) {
        case .home:
            homeButtonTapped()
        case .appSwitcher:
            appSwitcherButtonTapped()
        case .lock:
            lockButtonTapped()
        }
    }

    private var storedEdge: RemoteFloatingControlsEdge {
        RemoteFloatingControlsEdge(rawValue: storedEdgeRaw) ?? .trailing
    }

    private func restingCenter(canvasSize: CGSize) -> CGPoint {
        RemoteFloatingControlsLayout.center(
            edge: storedEdge,
            verticalFraction: storedVerticalFraction,
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
    }

    private func beginDrag(canvasSize: CGSize) {
        guard !isDragging else {
            return
        }
        let anchor = restingCenter(canvasSize: canvasSize)
        let initial = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(
                x: anchor.x + touchDrift.width,
                y: anchor.y + touchDrift.height
            ),
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
        isDragging = true
        dragAnchor = anchor
        liveCenter = initial
        snapTargetEdge = RemoteFloatingControlsLayout.nearestEdge(
            centerX: initial.x,
            canvasWidth: canvasSize.width
        )
        DeviceHubHaptics.hardwareControl()
    }

    private func updateDrag(
        translation: CGSize,
        canvasSize: CGSize
    ) {
        guard let dragAnchor else {
            return
        }
        let center = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(
                x: dragAnchor.x + translation.width,
                y: dragAnchor.y + translation.height
            ),
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
        let targetEdge = RemoteFloatingControlsLayout.nearestEdge(
            centerX: center.x,
            canvasWidth: canvasSize.width
        )
        if targetEdge != snapTargetEdge {
            // One tick each time the release target flips to the other
            // edge: crossing the snap line is what sticking feels like.
            snapTargetEdge = targetEdge
            DeviceHubHaptics.hardwareControl()
        }
        liveCenter = center
    }

    private func endDrag(canvasSize: CGSize) {
        guard isDragging, let center = liveCenter else {
            isDragging = false
            dragAnchor = nil
            snapTargetEdge = nil
            return
        }
        let edge =
            snapTargetEdge ?? RemoteFloatingControlsLayout.nearestEdge(
                centerX: center.x,
                canvasWidth: canvasSize.width
            )
        let fraction = RemoteFloatingControlsLayout.verticalFraction(
            centerY: center.y,
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            storedEdgeRaw = edge.rawValue
            storedVerticalFraction = fraction
            liveCenter = nil
        }
        isDragging = false
        dragAnchor = nil
        snapTargetEdge = nil
        DeviceHubHaptics.hardwareControl()
    }
}

#if DEBUG
    #Preview("iPhone, live", traits: .fixedLayout(width: 393, height: 852)) {
        previewBackground(enabled: true)
    }

    #Preview("iPhone, input unavailable", traits: .fixedLayout(width: 393, height: 852)) {
        previewBackground(enabled: false)
    }

    #Preview("iPad, live", traits: .fixedLayout(width: 1024, height: 768)) {
        previewBackground(enabled: true, scheme: .dark)
    }

    #Preview("iPad, input unavailable", traits: .fixedLayout(width: 1024, height: 768)) {
        previewBackground(enabled: false, scheme: .dark)
    }

    @MainActor
    private func previewBackground(
        enabled: Bool,
        scheme: ColorScheme = .light
    ) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteFloatingControls(
                acceptsInput: enabled,
                homeButtonTapped: {},
                appSwitcherButtonTapped: {},
                lockButtonTapped: {}
            )
        }
        .preferredColorScheme(scheme)
    }
#endif
