import Foundation

/// Character of the fold. Each preset biases the shader's look rather than
/// changing the geometry, so switching presets never moves the hinge.
enum FoldPreset: Int, CaseIterable, Identifiable, Sendable {
    case veil
    case crease
    case haze

    var id: Int { rawValue }

    /// Shown in settings. The app speaks Chinese; the code stays in English.
    var title: String {
        switch self {
        case .veil: return "轻纱"
        case .crease: return "折痕"
        case .haze: return "雾面"
        }
    }

    var detail: String {
        switch self {
        case .veil: return "均衡。折角柔和，中间区域保持清晰。"
        case .crease: return "折痕更硬，两侧收得更紧，立体感最强。"
        case .haze: return "更重的虚化，顶部泛一点冷光。"
        }
    }
}

/// Everything the user can change, in one value type.
///
/// Keeping the settings as a plain struct means persistence, the renderer, and
/// the settings UI all agree on one shape, and the whole configuration can be
/// compared, reset, or round-tripped through `UserDefaults` in one step.
struct FoldSettings: Equatable, Sendable {
    var preset: FoldPreset = .veil

    /// How far the upper corners draw inward, 0...1.
    var perspective: Double = 0.75
    /// How much the desktop softens toward the top edge, 0...1.
    var blur: Double = 0.9
    /// Depth of the shading along the folded sides, 0...1.
    var shade: Double = 0.35

    /// Lid angle at and above which the desktop is left alone, in degrees.
    var clearAngle: Double = 104

    /// Follow the physical lid, or hold a fixed angle for demos.
    var followLid: Bool = true
    var manualAngle: Double = 110

    /// Play a soft click once the desktop has finished unfolding.
    var sound: Bool = false

    static let `default` = FoldSettings()

    /// Restores whatever the user last chose.
    static func load(from defaults: UserDefaults = .standard) -> FoldSettings {
        var settings = FoldSettings()
        if defaults.object(forKey: Keys.preset) != nil {
            settings.preset =
                FoldPreset(rawValue: defaults.integer(forKey: Keys.preset)) ?? .veil
        }
        if defaults.object(forKey: Keys.perspective) != nil {
            settings.perspective = defaults.double(forKey: Keys.perspective)
        }
        if defaults.object(forKey: Keys.blur) != nil {
            settings.blur = defaults.double(forKey: Keys.blur)
        }
        if defaults.object(forKey: Keys.shade) != nil {
            settings.shade = defaults.double(forKey: Keys.shade)
        }
        if defaults.object(forKey: Keys.clearAngle) != nil {
            settings.clearAngle = defaults.double(forKey: Keys.clearAngle)
        }
        if defaults.object(forKey: Keys.followLid) != nil {
            settings.followLid = defaults.bool(forKey: Keys.followLid)
        }
        if defaults.object(forKey: Keys.manualAngle) != nil {
            settings.manualAngle = defaults.double(forKey: Keys.manualAngle)
        }
        if defaults.object(forKey: Keys.sound) != nil {
            settings.sound = defaults.bool(forKey: Keys.sound)
        }
        return settings.clamped()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: Keys.preset)
        defaults.set(perspective, forKey: Keys.perspective)
        defaults.set(blur, forKey: Keys.blur)
        defaults.set(shade, forKey: Keys.shade)
        defaults.set(clearAngle, forKey: Keys.clearAngle)
        defaults.set(followLid, forKey: Keys.followLid)
        defaults.set(manualAngle, forKey: Keys.manualAngle)
        defaults.set(sound, forKey: Keys.sound)
    }

    /// Keeps every value inside the range the UI offers, so a hand-edited
    /// preference file cannot drive the shader somewhere undefined.
    func clamped() -> FoldSettings {
        var copy = self
        copy.perspective = min(1, max(0, perspective))
        copy.blur = min(1, max(0, blur))
        copy.shade = min(1, max(0, shade))
        copy.clearAngle = min(135, max(80, clearAngle))
        copy.manualAngle = min(135, max(12, manualAngle))
        return copy
    }

    private enum Keys {
        static let preset = "fold.preset"
        static let perspective = "fold.perspective"
        static let blur = "fold.blur"
        static let shade = "fold.shade"
        static let clearAngle = "fold.clearAngle"
        static let followLid = "fold.followLid"
        static let manualAngle = "fold.manualAngle"
        static let sound = "fold.sound"
    }
}

/// Mirrors `FoldUniforms` in `Shaders/Fold.metal` byte for byte.
///
/// Eight 4-byte floats: order and count are load-bearing, because the renderer
/// hands this straight to `setFragmentBytes`.
struct FoldUniforms {
    var closure: Float = 0
    var kappa: Float = 0
    var maxBlur: Float = 0
    var pinch: Float = 0
    var shade: Float = 0
    var style: Float = 0
    var aspect: Float = 1.6
    /// Padding only: keeps the struct 32 bytes wide for the GPU.
    var pad: Float = 0
}

/// Turns a closure fraction and the user's settings into shader uniforms.
///
/// This is the one place that decides how a slider becomes geometry, which keeps
/// the tuning in a single readable spot instead of spread between the renderer,
/// the shader, and the UI.
enum FoldTuning {
    /// Tilt of the display plane at full closure, in degrees.
    static func maxTiltDegrees(perspective: Double) -> Double {
        8 + 30 * min(max(perspective, 0), 1)
    }

    /// Distance from the eye to the hinge, in screen heights. Larger values
    /// flatten the perspective; this range keeps the fold pronounced but sane.
    static let viewDistance: Double = 2.6

    /// Blur radius in pixels at the top edge, at a working width of 512.
    static let maxBlurRadius: Double = 50

    /// Builds the uniforms for a closure fraction.
    ///
    /// `workingWidth` rescales the blur radius so the look does not change when
    /// the capture resolution changes, which is what makes the settings preview
    /// and the live overlay match.
    static func uniforms(
        closure: Double, settings: FoldSettings, aspect: Double, workingWidth: Double
    ) -> FoldUniforms {
        let projection = FoldKinematics.projection(
            closure: closure,
            maxTilt: maxTiltDegrees(perspective: settings.perspective) * .pi / 180,
            distance: viewDistance)

        var uniforms = FoldUniforms()
        uniforms.closure = Float(min(max(closure, 0), 1))
        uniforms.kappa = Float(projection.recession)
        uniforms.maxBlur = Float(maxBlurRadius * settings.blur * workingWidth / 512)
        // The top edge narrows by roughly the same amount the plane recedes, so
        // the pinch stays consistent with the tilt instead of being a free knob.
        uniforms.pinch = Float(0.42 * settings.perspective)
        uniforms.shade = Float(settings.shade)
        uniforms.style = Float(settings.preset.rawValue)
        uniforms.aspect = Float(aspect)
        return uniforms
    }
}
