import SwiftUI

/// Which canvas edge the floating controls call home.
enum RemoteFloatingControlsEdge: String, CaseIterable, Equatable {
    case leading
    case trailing
}

/// Pure geometry for the draggable floating control cluster.
enum RemoteFloatingControlsLayout {
    /// Space between the cluster and the edge it rests on.
    static let edgeInset: CGFloat = 12
    /// How close to the vertical middle a drag must pass to snap there.
    static let magnetDistance: CGFloat = 44

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

    /// Whether a dragged center is close enough to the vertical middle
    /// to snap there.
    static func isWithinMagnet(
        centerY: CGFloat,
        canvasHeight: CGFloat
    ) -> Bool {
        abs(centerY - canvasHeight / 2) <= magnetDistance
    }

    /// Clamps a dragged center to keep the cluster fully inside the
    /// canvas and pins it to the vertical middle while the magnet holds,
    /// so deliberately off-center placement stays exactly where dropped.
    static func settlingCenter(
        rawCenter: CGPoint,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGPoint {
        let clamped = clampedY(
            rawCenter.y,
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
        let pinned = isWithinMagnet(
            centerY: clamped,
            canvasHeight: canvasSize.height
        )
        return CGPoint(
            x: clampedX(
                rawCenter.x,
                canvasSize: canvasSize,
                clusterSize: clusterSize
            ),
            y: pinned ? canvasSize.height / 2 : clamped
        )
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
/// common target gestures stay one tap away instead. The cluster sits on
/// the canvas border, which is letterbox margin while mirroring, and can
/// be repositioned: hold to drag it anywhere along the edges, where it
/// magnetically snaps to the vertical middle but also parks at any
/// deliberately chosen height. The placement survives relaunches.
struct RemoteFloatingControls: View {
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
    @State private var isPinnedToMiddle = false
    @State private var clusterSize = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            controls
                .position(
                    liveCenter ?? restingCenter(canvasSize: proxy.size)
                )
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: {
                    clusterSize = $0
                }
                .gesture(dragGesture(canvasSize: proxy.size))
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
        .background(
            .black.opacity(isDragging ? 0.75 : 0.6),
            in: .capsule
        )
        .glassEffect(.regular, in: .capsule)
        .opacity(acceptsInput || isDragging ? 1 : 0.4)
        .scaleEffect(isDragging ? 1.08 : 1)
        .animation(
            .spring(response: 0.25, dampingFraction: 0.7),
            value: isDragging
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-floating-controls")
    }

    private func control(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!acceptsInput)
        .accessibilityLabel(label)
    }

    private func dragGesture(canvasSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture())
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDrag(canvasSize: canvasSize)
                case let .second(true, drag?):
                    updateDrag(
                        translation: drag.translation,
                        canvasSize: canvasSize
                    )
                default:
                    break
                }
            }
            .onEnded { _ in
                endDrag(canvasSize: canvasSize)
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
        isDragging = true
        isPinnedToMiddle = false
        dragAnchor = anchor
        liveCenter = anchor
        DeviceHubHaptics.hardwareControl()
    }

    private func updateDrag(
        translation: CGSize,
        canvasSize: CGSize
    ) {
        guard let dragAnchor else {
            return
        }
        let settled = RemoteFloatingControlsLayout.settlingCenter(
            rawCenter: CGPoint(
                x: dragAnchor.x + translation.width,
                y: dragAnchor.y + translation.height
            ),
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
        let pinned = settled.y == canvasSize.height / 2
        if pinned != isPinnedToMiddle {
            isPinnedToMiddle = pinned
            DeviceHubHaptics.hardwareControl()
        }
        liveCenter = settled
    }

    private func endDrag(canvasSize: CGSize) {
        guard isDragging, let center = liveCenter else {
            isDragging = false
            dragAnchor = nil
            return
        }
        let edge = RemoteFloatingControlsLayout.nearestEdge(
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
        isPinnedToMiddle = false
        dragAnchor = nil
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
