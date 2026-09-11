import Foundation

/// Pure fold mathematics. No AppKit, no Metal, no I/O.
///
/// This is the module every other layer asks "how folded should the desktop be
/// right now?". Keeping it free of frameworks is what makes the fold behaviour
/// testable without a display, a sensor, or a GPU.
enum FoldKinematics {

    /// Lid travel, in degrees, that maps to a complete fold.
    ///
    /// The lid only has to move a little before the effect reads as "closing".
    /// Spreading the full fold over a wide span keeps the motion gradual instead
    /// of snapping shut in the last few degrees.
    static let defaultSpan: Double = 34

    /// Converts a lid angle into a closure fraction in `0...1`.
    ///
    /// `angle` is the raw lid angle in degrees: roughly `0` when shut and around
    /// `135` when wide open. The desktop stays untouched while the lid is above
    /// `clearAngle`, then folds in as the lid travels down over `span` degrees.
    ///
    /// The curve is a quintic smootherstep (`6t⁵ − 15t⁴ + 10t³`) rather than a
    /// cubic smoothstep. Both start and end at rest, but the quintic is also
    /// free of the small acceleration discontinuity at each end, so the desktop
    /// eases into and out of the fold instead of visibly ticking.
    static func closure(angle: Double, clearAngle: Double, span: Double = defaultSpan) -> Double {
        // Guard against a degenerate span so a user-edited preference can never
        // divide by zero or invert the fold direction.
        let travel = max(1, span)
        let t = min(1, max(0, (clearAngle - angle) / travel))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Exponential approach used to damp the closure fraction frame to frame.
    ///
    /// Framed as a half-life in seconds: after `halfLife`, the remaining
    /// distance to the target has halved. Half-life is far easier to reason
    /// about than a raw per-frame coefficient, and it stays correct if the
    /// frame rate changes.
    static func approach(
        current: Double, target: Double, dt: Double, halfLife: Double = 0.07
    ) -> Double {
        let step = min(max(dt, 0), 0.25)
        guard halfLife > 0 else { return target }
        let remaining = pow(0.5, step / halfLife)
        let next = target + (current - target) * remaining
        // Snap once the difference is below display precision, so the caller can
        // detect a settled fold by comparing against the target directly.
        return abs(next - target) < 0.0005 ? target : next
    }

    /// Geometry of the fold: the display plane rotated about its bottom edge.
    ///
    /// The lid hinge sits along the bottom of the screen, so that edge is the
    /// fixed axis. Tilting the plane by `tilt` radians and viewing it from
    /// `distance` screen-heights away gives a real perspective projection rather
    /// than an ad-hoc squash. `cos`/`sin` are precomputed here so the shader does
    /// no trigonometry per pixel.
    struct Projection {
        /// Tilt of the display plane away from the viewer, in radians.
        var tilt: Double
        /// Viewer distance from the hinge, measured in screen heights.
        var distance: Double

        var cosTilt: Double { cos(tilt) }
        var sinTilt: Double { sin(tilt) }

        /// Depth slope: how quickly a point recedes per unit of height above the hinge.
        var recession: Double { sinTilt / max(0.05, distance) }

        /// Height above the hinge, in `0...1`, that a source point at `height`
        /// projects to on screen. Used by the tests to check the mapping really
        /// is a contraction that leaves the hinge fixed.
        func project(height: Double) -> Double {
            height * cosTilt / (1 + height * recession)
        }

        /// Inverse of `project`: the source height a destination pixel samples.
        ///
        /// Returns `nil` when the destination lies past the projected top edge,
        /// where the display has folded out of view and there is nothing to show.
        func sourceHeight(forDestination destination: Double) -> Double? {
            let denominator = cosTilt - destination * recession
            guard denominator > 0.0001 else { return nil }
            return destination / denominator
        }
    }

    /// Builds the projection for a given closure and style.
    ///
    /// `tilt` is the tilt at full closure; it scales linearly with the closure
    /// fraction so the motion stays continuous from the very first degree of lid
    /// travel.
    static func projection(closure: Double, maxTilt: Double, distance: Double) -> Projection {
        Projection(tilt: maxTilt * min(max(closure, 0), 1), distance: distance)
    }
}
