import SwiftUI

/// Always-reachable target controls pinned to the canvas edge.
///
/// The controller's own edge swipes can still collide with iPadOS system
/// gestures even while the bottom-edge deferral is active, so the most
/// common target gestures stay one tap away instead. The cluster sits on
/// the canvas border, which is letterbox margin while mirroring.
struct RemoteFloatingControls: View {
    let acceptsInput: Bool
    let homeButtonTapped: () -> Void
    let appSwitcherButtonTapped: () -> Void
    let lockButtonTapped: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            control(
                "Home",
                systemImage: "house.fill",
                action: homeButtonTapped
            )
            control(
                "App Switcher",
                systemImage: "rectangle.on.rectangle",
                action: appSwitcherButtonTapped
            )
            control(
                "Lock",
                systemImage: "lock.fill",
                action: lockButtonTapped
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.black.opacity(0.6), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .opacity(acceptsInput ? 1 : 0.4)
        .disabled(!acceptsInput)
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
        .accessibilityLabel(label)
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
            .padding(.trailing, 12)
        }
        .preferredColorScheme(scheme)
    }
#endif
