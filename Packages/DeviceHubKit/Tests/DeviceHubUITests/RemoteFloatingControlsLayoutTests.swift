import CoreGraphics
@testable import DeviceHubUI
import Testing

private let canvas = CGSize(width: 1000, height: 600)
private let cluster = CGSize(width: 60, height: 200)

@Suite("Remote floating controls layout")
struct RemoteFloatingControlsLayoutTests {
    @Test("Resting centers hug their edge and span the travel track")
    func restingCentersFollowEdgeAndFraction() {
        let leadingMiddle = RemoteFloatingControlsLayout.center(
            edge: .leading,
            verticalFraction: 0.5,
            canvasSize: canvas,
            clusterSize: cluster
        )
        let trailingMiddle = RemoteFloatingControlsLayout.center(
            edge: .trailing,
            verticalFraction: 0.5,
            canvasSize: canvas,
            clusterSize: cluster
        )

        #expect(leadingMiddle.x == 42)
        #expect(trailingMiddle.x == 958)
        #expect(leadingMiddle.y == 300)
        #expect(trailingMiddle.y == 300)

        let top = RemoteFloatingControlsLayout.center(
            edge: .trailing,
            verticalFraction: 0,
            canvasSize: canvas,
            clusterSize: cluster
        )
        let bottom = RemoteFloatingControlsLayout.center(
            edge: .trailing,
            verticalFraction: 1,
            canvasSize: canvas,
            clusterSize: cluster
        )
        #expect(top.y == 100)
        #expect(bottom.y == 500)
    }

    @Test("Vertical fractions clamp to the canvas bounds")
    func verticalFractionClamps() {
        let aboveTop = RemoteFloatingControlsLayout.verticalFraction(
            centerY: -50,
            canvasSize: canvas,
            clusterSize: cluster
        )
        let belowBottom = RemoteFloatingControlsLayout.verticalFraction(
            centerY: 900,
            canvasSize: canvas,
            clusterSize: cluster
        )
        let middle = RemoteFloatingControlsLayout.verticalFraction(
            centerY: 300,
            canvasSize: canvas,
            clusterSize: cluster
        )

        #expect(aboveTop == 0)
        #expect(belowBottom == 1)
        #expect(middle == 0.5)
    }

    @Test("Fraction and center round-trip across the track")
    func fractionAndCenterRoundTrip() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let center = RemoteFloatingControlsLayout.centerY(
                fraction: fraction,
                canvasSize: canvas,
                clusterSize: cluster
            )
            let restored = RemoteFloatingControlsLayout.verticalFraction(
                centerY: center,
                canvasSize: canvas,
                clusterSize: cluster
            )
            #expect(abs(restored - fraction) < 0.0001)
        }
    }

    @Test("The nearest edge follows the canvas midline")
    func nearestEdgeFollowsMidline() {
        #expect(
            RemoteFloatingControlsLayout.nearestEdge(
                centerX: 200,
                canvasWidth: 1000
            ) == .leading
        )
        #expect(
            RemoteFloatingControlsLayout.nearestEdge(
                centerX: 800,
                canvasWidth: 1000
            ) == .trailing
        )
        #expect(
            RemoteFloatingControlsLayout.nearestEdge(
                centerX: 500,
                canvasWidth: 1000
            ) == .trailing
        )
    }

    @Test("Dropped heights are preserved, including beside the middle")
    func droppedHeightsArePreservedBesideTheMiddle() {
        let nearMiddle = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(x: 900, y: 315),
            canvasSize: canvas,
            clusterSize: cluster
        )
        #expect(nearMiddle == CGPoint(x: 900, y: 315))

        let exactlyMiddle = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(x: 500, y: 300),
            canvasSize: canvas,
            clusterSize: cluster
        )
        #expect(exactlyMiddle == CGPoint(x: 500, y: 300))
    }

    @Test("A drop beside the middle parks beside the middle")
    func dropBesideMiddleParksBesideMiddle() {
        let fraction = RemoteFloatingControlsLayout.verticalFraction(
            centerY: 315,
            canvasSize: canvas,
            clusterSize: cluster
        )
        let parked = RemoteFloatingControlsLayout.center(
            edge: .trailing,
            verticalFraction: fraction,
            canvasSize: canvas,
            clusterSize: cluster
        )
        #expect(parked == CGPoint(x: 958, y: 315))
    }

    @Test("Dragged centers clamp inside the canvas")
    func draggedCentersClampInsideTheCanvas() {
        let clamped = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(x: -40, y: 900),
            canvasSize: canvas,
            clusterSize: cluster
        )
        #expect(clamped == CGPoint(x: 42, y: 500))
    }

    @Test("A canvas smaller than the cluster falls back to its middle")
    func canvasSmallerThanClusterFallsBackToMiddle() {
        let tiny = CGSize(width: 100, height: 100)
        let center = RemoteFloatingControlsLayout.center(
            edge: .trailing,
            verticalFraction: 0.2,
            canvasSize: tiny,
            clusterSize: cluster
        )
        // Width still fits the inset, so the edge wins; height does not.
        #expect(center == CGPoint(x: 58, y: 50))

        let clamped = RemoteFloatingControlsLayout.clampedCenter(
            rawCenter: CGPoint(x: 40, y: 80),
            canvasSize: tiny,
            clusterSize: cluster
        )
        #expect(clamped == CGPoint(x: 42, y: 50))

        let fraction = RemoteFloatingControlsLayout.verticalFraction(
            centerY: 40,
            canvasSize: tiny,
            clusterSize: cluster
        )
        #expect(fraction == 0.5)
    }
}
