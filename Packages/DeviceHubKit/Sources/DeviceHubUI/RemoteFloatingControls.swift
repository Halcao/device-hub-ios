import SwiftUI

/// Which canvas edge the floating controls call home.
enum RemoteFloatingControlsEdge: String, CaseIterable, Equatable {
    case leading
    case trailing
}

/// Pure geometry for the draggable floating control cluster.
enum RemoteFloatingControlsLayout {
    static let edgeInset: CGFloat = 12

    static func restingCenter(
        edge: RemoteFloatingControlsEdge,
        verticalFraction: Double,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> CGPoint {
        let x: CGFloat = edge == .leading
            ? edgeInset + clusterSize.width / 2
            : canvasSize.width - edgeInset - clusterSize.width / 2
        let travel = canvasSize.height - clusterSize.height
        let y: CGFloat = travel > 0
            ? clusterSize.height / 2 + CGFloat(verticalFraction) * travel
            : canvasSize.height / 2
        return clamp(CGPoint(x: x, y: y), canvasSize: canvasSize, clusterSize: clusterSize)
    }

    static func verticalFraction(
        centerY: CGFloat,
        canvasSize: CGSize,
        clusterSize: CGSize
    ) -> Double {
        let travel = canvasSize.height - clusterSize.height
        guard travel > 0 else { return 0.5 }
        let raw = (centerY - clusterSize.height / 2) / travel
        return Double(min(max(raw, 0), 1))
    }

    static func nearestEdge(centerX: CGFloat, canvasWidth: CGFloat) -> RemoteFloatingControlsEdge {
        centerX * 2 < canvasWidth ? .leading : .trailing
    }

    /// Keeps the cluster inside the canvas. The horizontal bounds carry
    /// the same edge inset the resting positions use, so a drag and a
    /// drop agree on where the edge is; the vertical bounds do not, so
    /// the cluster can be parked flush with the top or bottom.
    static func clamp(_ point: CGPoint, canvasSize: CGSize, clusterSize: CGSize) -> CGPoint {
        let minX = edgeInset + clusterSize.width / 2
        let maxX = canvasSize.width - edgeInset - clusterSize.width / 2
        let minY = clusterSize.height / 2
        let maxY = canvasSize.height - clusterSize.height / 2
        return CGPoint(
            x: maxX > minX ? min(max(point.x, minX), maxX) : canvasSize.width / 2,
            y: maxY > minY ? min(max(point.y, minY), maxY) : canvasSize.height / 2
        )
    }
}

/// Always-reachable target controls pinned to the canvas edge.
struct RemoteFloatingControls: View {
    /// How long the cluster sits untouched before it fades back.
    private static let idleDelay: TimeInterval = 4
    /// What the cluster fades to once idle: visible enough to find,
    /// faint enough to stop competing with the mirrored screen.
    private static let idleOpacity: Double = 0.25

    let acceptsInput: Bool
    let homeButtonTapped: () -> Void
    let appSwitcherButtonTapped: () -> Void
    let lockButtonTapped: () -> Void

    @AppStorage("devicehub.remoteFloatingControls.edge")
    private var storedEdgeRaw = RemoteFloatingControlsEdge.trailing.rawValue
    @AppStorage("devicehub.remoteFloatingControls.verticalFraction")
    private var storedVerticalFraction = 0.5

    @State private var center: CGPoint?
    @State private var dragAnchor: CGPoint?
    @State private var clusterSize = CGSize.zero
    @State private var isIdle = false
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            cluster
                .onGeometryChange(for: CGSize.self) { $0.size } action: { clusterSize = $0 }
                .position(center ?? restingCenter(canvasSize: proxy.size))
                .gesture(drag(canvasSize: proxy.size))
                .onAppear(perform: scheduleIdleFade)
                .onDisappear { idleTask?.cancel() }
        }
    }

    private var cluster: some View {
        VStack(spacing: 10) {
            icon("house.fill").onTapGesture { activate(homeButtonTapped) }
            icon("rectangle.on.rectangle").onTapGesture { activate(appSwitcherButtonTapped) }
            icon("lock.fill").onTapGesture { activate(lockButtonTapped) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: .capsule)
        .opacity(clusterOpacity)
    }

    private var clusterOpacity: Double {
        if center != nil {
            return 1
        }
        if isIdle {
            return Self.idleOpacity
        }
        return acceptsInput ? 1 : 0.4
    }

    /// A tap on a faded cluster only brings it back: at idle opacity the
    /// icons are too faint to aim at, and every one of these actions
    /// lands on the target device.
    private func activate(_ action: () -> Void) {
        guard acceptsInput else {
            return
        }
        let wasIdle = isIdle
        wake()
        guard !wasIdle else {
            return
        }
        action()
    }

    /// Cancels any pending fade, restores full opacity, and restarts the
    /// idle countdown.
    private func wake() {
        if isIdle {
            withAnimation(.easeOut(duration: 0.2)) {
                isIdle = false
            }
        }
        scheduleIdleFade()
    }

    private func scheduleIdleFade() {
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.idleDelay))
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeOut(duration: 0.45)) {
                isIdle = true
            }
        }
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: 42, height: 42)
    }

    private func drag(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = center ?? restingCenter(canvasSize: canvasSize)
                    wake()
                }
                center = RemoteFloatingControlsLayout.clamp(
                    CGPoint(
                        x: dragAnchor!.x + value.translation.width,
                        y: dragAnchor!.y + value.translation.height
                    ),
                    canvasSize: canvasSize,
                    clusterSize: clusterSize
                )
            }
            .onEnded { _ in
                dragAnchor = nil
                scheduleIdleFade()
                guard let final = center else { return }
                let edge = RemoteFloatingControlsLayout.nearestEdge(
                    centerX: final.x,
                    canvasWidth: canvasSize.width
                )
                let fraction = RemoteFloatingControlsLayout.verticalFraction(
                    centerY: final.y,
                    canvasSize: canvasSize,
                    clusterSize: clusterSize
                )
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    storedEdgeRaw = edge.rawValue
                    storedVerticalFraction = fraction
                    center = nil
                }
            }
    }

    private func restingCenter(canvasSize: CGSize) -> CGPoint {
        RemoteFloatingControlsLayout.restingCenter(
            edge: RemoteFloatingControlsEdge(rawValue: storedEdgeRaw) ?? .trailing,
            verticalFraction: storedVerticalFraction,
            canvasSize: canvasSize,
            clusterSize: clusterSize
        )
    }
}

#if DEBUG
    #Preview("iPhone, live", traits: .fixedLayout(width: 393, height: 852)) {
        previewBackground(enabled: true)
    }

    #Preview("iPad, live", traits: .fixedLayout(width: 1024, height: 768)) {
        previewBackground(enabled: true, scheme: .dark)
    }

    @MainActor
    private func previewBackground(enabled: Bool, scheme: ColorScheme = .light) -> some View {
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
