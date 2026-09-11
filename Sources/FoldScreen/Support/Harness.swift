import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Command line harness: the parts of the app that can be checked without a
/// display, a lid, or a click.
///
/// GPU and sensor code is hard to test through the UI, so the interesting
/// behaviour is reachable from the command line instead. The render harness in
/// particular drives the *same* renderer the overlay uses, which is what makes
/// its output trustworthy as a visual reference.
enum Harness {

    // MARK: - Self test

    /// Returns the number of failures, printing each one.
    static func runSelfTest() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok   \(label)")
            } else {
                failures += 1
                let extra = detail()
                print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }

        print("FoldKinematics")
        // A wide-open lid leaves the desktop alone, and the effect is continuous:
        // nudging the lid must not make the desktop jump.
        check(
            "open lid is untouched",
            FoldKinematics.closure(angle: 130, clearAngle: 104) == 0)
        check(
            "at the clear angle the fold is zero",
            FoldKinematics.closure(angle: 104, clearAngle: 104) == 0)
        check(
            "a fully travelled lid folds completely",
            FoldKinematics.closure(angle: 104 - FoldKinematics.defaultSpan, clearAngle: 104) == 1)
        check(
            "closure never leaves 0...1",
            (0...200).allSatisfy {
                let value = FoldKinematics.closure(angle: Double($0), clearAngle: 104)
                return value >= 0 && value <= 1
            })
        var monotonic = true
        var previous = -1.0
        for step in stride(from: 140.0, through: 0.0, by: -1.0) {
            let value = FoldKinematics.closure(angle: step, clearAngle: 104)
            if value < previous - 1e-9 { monotonic = false }
            previous = value
        }
        check("closure rises monotonically as the lid closes", monotonic)
        // The quintic ease should be symmetric about the midpoint.
        let mid = FoldKinematics.closure(angle: 104 - FoldKinematics.defaultSpan / 2, clearAngle: 104)
        check("midpoint of the ease sits at one half", abs(mid - 0.5) < 1e-9, "got \(mid)")
        check(
            "a degenerate span cannot divide by zero",
            FoldKinematics.closure(angle: 104, clearAngle: 104, span: 0).isFinite)

        print("FoldKinematics.approach")
        check(
            "an unchanged value stays put",
            FoldKinematics.approach(current: 0.4, target: 0.4, dt: 1 / 60) == 0.4)
        check(
            "the target is reached exactly once it is close",
            FoldKinematics.approach(current: 0.5001, target: 0.5, dt: 1 / 60) == 0.5)
        var current = 0.0
        for _ in 0..<600 { current = FoldKinematics.approach(current: current, target: 1, dt: 1 / 60) }
        check("damping converges", current == 1, "got \(current)")
        check(
            "damping never overshoots",
            (0..<200).allSatisfy { step in
                let value = FoldKinematics.approach(
                    current: Double(step) / 200, target: 1, dt: 1 / 60)
                return value <= 1 + 1e-9
            })

        print("FoldKinematics.projection")
        let flat = FoldKinematics.projection(closure: 0, maxTilt: 0.6, distance: 2.6)
        check("no closure means no tilt", flat.tilt == 0)
        check("no tilt leaves heights alone", abs(flat.project(height: 0.5) - 0.5) < 1e-12)
        let folded = FoldKinematics.projection(closure: 1, maxTilt: 0.6, distance: 2.6)
        check("the hinge stays pinned", abs(folded.project(height: 0) - 0) < 1e-12)
        check("the top edge stays in frame", folded.project(height: 1) <= 1 + 1e-9)

        print("FoldTuning")
        let settings = FoldSettings.default
        let uniforms = FoldTuning.uniforms(
            closure: 1, settings: settings, aspect: 1.6, workingWidth: 512)
        check("uniforms carry the closure", uniforms.closure == 1)
        check("uniforms stay finite", uniforms.kappa.isFinite && uniforms.maxBlur.isFinite)
        check("kappa is positive when folded", uniforms.kappa > 0)
        // Doubling the working width must double the pixel radius, so the blur
        // looks identical at any capture resolution.
        let wide = FoldTuning.uniforms(
            closure: 1, settings: settings, aspect: 1.6, workingWidth: 1024)
        check(
            "blur radius tracks the working width",
            abs(wide.maxBlur - uniforms.maxBlur * 2) < 1e-4,
            "\(uniforms.maxBlur) vs \(wide.maxBlur)")
        check(
            "out of range settings are clamped",
            FoldSettings(perspective: 9, blur: -3, shade: 42, clearAngle: 900).clamped()
                == FoldSettings(perspective: 1, blur: 0, shade: 1, clearAngle: 135))

        print("PreviewArtwork")
        let artwork = PreviewArtwork.make(size: CGSize(width: 320, height: 200))
        check("preview artwork renders at the requested size", artwork.width == 320 && artwork.height == 200)

        print("LidSensor")
        let sensor = HIDLidAngleSource()
        if let angle = sensor.read() {
            check(
                "a reported angle is plausible", (0...180).contains(angle), "got \(angle)")
        } else {
            print("  note no lid sensor on this Mac; the app will ask for a manual angle")
        }

        print("FoldRenderer")
        do {
            let renderer = try FoldRenderer(previewImage: artwork)
            let frame = try renderer.snapshot(
                size: CGSize(width: 320, height: 200),
                uniforms: FoldTuning.uniforms(
                    closure: 0.7, settings: settings, aspect: 1.6, workingWidth: 320))
            check("the offscreen pipeline produces a frame", frame.width == 320 && frame.height == 200)
        } catch {
            check("the offscreen pipeline produces a frame", false, "\(error)")
        }

        return failures
    }

    // MARK: - Render harness

    /// Renders a closure sweep through the real pipeline, for visual review.
    ///
    /// `--render-frames <dir> [--size WxH] [--steps N] [--preset 0|1|2] [--hold <closure>]`
    static func renderFrames(_ arguments: [String]) -> Int {
        guard let directory = value(for: "--render-frames", in: arguments) else {
            print("--render-frames needs an output directory")
            return 1
        }
        let size = parseSize(value(for: "--size", in: arguments)) ?? CGSize(width: 960, height: 600)
        let steps = Int(value(for: "--steps", in: arguments) ?? "") ?? 7
        let preset = FoldPreset(rawValue: Int(value(for: "--preset", in: arguments) ?? "") ?? 0) ?? .veil
        let hold = value(for: "--hold", in: arguments).flatMap(Double.init)

        var settings = FoldSettings.default
        settings.preset = preset

        let folder = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let renderer = try FoldRenderer(previewImage: PreviewArtwork.make())
            let workingWidth = Double(min(1280 / 4, 512))

            for step in 0..<steps {
                let closure = hold ?? Double(step) / Double(max(1, steps - 1))
                let uniforms = FoldTuning.uniforms(
                    closure: closure, settings: settings, aspect: size.width / size.height,
                    workingWidth: workingWidth)
                let image = try renderer.snapshot(size: size, uniforms: uniforms)
                let name = String(format: "fold-%02d-%.2f.png", step, closure)
                try write(image, to: folder.appendingPathComponent(name))
            }
            print("rendered \(steps) frame(s) at \(Int(size.width))x\(Int(size.height)) → \(folder.path)")
            return 0
        } catch {
            print("render failed: \(error)")
            return 1
        }
    }

    // MARK: - Helpers

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else {
            return nil
        }
        let candidate = arguments[index + 1]
        return candidate.hasPrefix("--") ? nil : candidate
    }

    private static func parseSize(_ text: String?) -> CGSize? {
        guard let text else { return nil }
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw FoldRendererError.imageAssemblyFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FoldRendererError.imageAssemblyFailed
        }
    }
}
