import CoreGraphics
import Foundation

/// The still image the fold is demonstrated on when there is no live capture.
///
/// Drawn in code rather than shipped as an asset so the repository stays free of
/// binary art and the preview always matches the current palette. The scene
/// carries fine detail all the way to the top — stars overhead, a soft moon,
/// ridge lines below — so that the top-weighted defocus is easy to judge while
/// tuning and obvious to the user in the settings preview.
enum PreviewArtwork {

    static let size = CGSize(width: 1280, height: 800)

    /// - Parameter grain: the anti-banding noise layer. Worth keeping on screen,
    ///   where it hides the steps in an eight-bit gradient, but worth dropping
    ///   for GIF export: a 256-colour palette turns the noise into per-pixel
    ///   flicker that defeats inter-frame compression.
    static func make(size requested: CGSize = size, grain: Bool = true) -> CGImage {
        let width = Int(requested.width)
        let height = Int(requested.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // A 1x1 image keeps the renderer's fallback path total.
            return fallbackPixel()
        }

        let w = CGFloat(width)
        let h = CGFloat(height)
        // Core Graphics is bottom-up here, so the sky goes down first and the
        // ridge layers stack on top of it.
        drawSky(in: context, width: w, height: h)
        drawStars(in: context, width: w, height: h)
        drawMoon(in: context, width: w, height: h)
        drawClouds(in: context, width: w, height: h)
        drawRidges(in: context, width: w, height: h)
        if grain { drawGrain(in: context, width: w, height: h) }

        return context.makeImage() ?? fallbackPixel()
    }

    // MARK: - Layers

    private static func drawSky(in context: CGContext, width: CGFloat, height: CGFloat) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // (location, red, green, blue). The last stop is well lifted so the
        // bottom of the screen stays clearly readable once the top has softened.
        let stops: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.00, 0.10, 0.12, 0.24),  // indigo overhead
            (0.34, 0.24, 0.22, 0.40),  // violet
            (0.62, 0.52, 0.38, 0.47),  // mauve
            (0.84, 0.82, 0.62, 0.49),  // warm dusk
            (1.00, 0.95, 0.88, 0.74),  // pale sand along the hinge
        ]
        let colors = stops.map {
            CGColor(colorSpace: colorSpace, components: [$0.1, $0.2, $0.3, 1])!
        }
        guard
            let gradient = CGGradient(
                colorsSpace: colorSpace, colors: colors as CFArray,
                locations: stops.map { $0.0 })
        else { return }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    }

    /// A starfield across the upper two thirds.
    ///
    /// Small point highlights are the most honest test of the blur: they stay
    /// crisp near the hinge and smear into soft dots near the top, which is
    /// exactly the gradient the effect is going for.
    private static func drawStars(in context: CGContext, width: CGFloat, height: CGFloat) {
        // A tiny deterministic generator keeps the artwork identical on every
        // launch without shipping a seed file.
        var state: UInt64 = 0x5DEE_CE66_D1CE_4E5B
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context.saveGState()
        for _ in 0..<190 {
            let x = random() * width
            // Densest overhead, thinning out toward the horizon.
            let vertical = pow(random(), 0.7)
            let y = height * (0.42 + 0.55 * vertical)
            let brightness = 0.55 + 0.45 * random()
            let radius = (0.6 + 1.5 * pow(random(), 3)) * (width / 1280)
            context.setFillColor(
                CGColor(
                    colorSpace: colorSpace,
                    components: [brightness, brightness, min(1, brightness * 1.05), 0.35 + 0.55 * random()])!)
            context.fillEllipse(
                in: CGRect(
                    x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    /// A low moon, sitting where the defocus is strongest.
    private static func drawMoon(in context: CGContext, width: CGFloat, height: CGFloat) {
        let center = CGPoint(x: width * 0.68, y: height * 0.745)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(colorSpace: colorSpace, components: [1.00, 0.97, 0.88, 1.00])!,
            CGColor(colorSpace: colorSpace, components: [0.98, 0.88, 0.72, 0.55])!,
            CGColor(colorSpace: colorSpace, components: [0.95, 0.78, 0.62, 0.22])!,
            CGColor(colorSpace: colorSpace, components: [0.90, 0.68, 0.58, 0.00])!,
        ]
        guard
            let glow = CGGradient(
                colorsSpace: colorSpace, colors: colors as CFArray,
                locations: [0, 0.16, 0.42, 1])
        else { return }
        context.drawRadialGradient(
            glow, startCenter: center, startRadius: 0, endCenter: center,
            endRadius: width * 0.24, options: [])
    }

    /// Layered ridges across the lower half, each a little lighter than the one
    /// behind it so the scene reads as depth rather than as a silhouette.
    private static func drawRidges(in context: CGContext, width: CGFloat, height: CGFloat) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let layers = 6
        for layer in stride(from: layers, through: 0, by: -1) {
            let t = CGFloat(layer) / CGFloat(layers)
            let baseline = height * (0.05 + 0.105 * t)
            let amplitude = height * (0.105 - 0.013 * t)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            let steps = 140
            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let x = progress * width
                let wave =
                    sin(progress * 5.1 + CGFloat(layer) * 1.35) * amplitude
                    + sin(progress * 10.7 + CGFloat(layer) * 0.7) * amplitude * 0.26
                path.addLine(to: CGPoint(x: x, y: baseline + wave))
            }
            path.addLine(to: CGPoint(x: width, y: 0))
            path.closeSubpath()

            // Front layers are lighter, so the nearest ridge separates cleanly
            // from the ones behind it.
            let shade = 0.20 + 0.30 * (1 - t)
            context.setFillColor(
                CGColor(
                    colorSpace: colorSpace,
                    components: [shade * 0.78, shade * 0.84, shade * 1.06, 1])!)
            context.addPath(path)
            context.fillPath()
        }
    }

    /// Thin cloud bands across the middle of the frame.
    ///
    /// The scene was otherwise all sky at the top and all ridge at the bottom,
    /// which left the middle of the blur ramp with nothing to show it off. These
    /// sit exactly where the defocus is partway through, so the transition from
    /// crisp to soft runs across a single element.
    private static func drawClouds(in context: CGContext, width: CGFloat, height: CGFloat) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // (centre x, centre y, half width, half height, alpha)
        let bands: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.22, 0.44, 0.26, 0.011, 0.16),
            (0.78, 0.52, 0.31, 0.014, 0.20),
            (0.46, 0.60, 0.22, 0.009, 0.13),
            (0.10, 0.66, 0.20, 0.012, 0.17),
            (0.66, 0.36, 0.18, 0.008, 0.10),
        ]
        context.saveGState()
        for (cx, cy, halfWidth, halfHeight, alpha) in bands {
            context.setFillColor(
                CGColor(
                    colorSpace: colorSpace,
                    components: [0.98, 0.93, 0.90, alpha])!)
            context.fillEllipse(
                in: CGRect(
                    x: (cx - halfWidth) * width, y: (cy - halfHeight) * height,
                    width: halfWidth * 2 * width, height: halfHeight * 2 * height))
        }
        context.restoreGState()
    }

    /// A faint film of noise over the finished image.
    ///
    /// An eight-bit gradient across a tall screen bands visibly, and the fold
    /// makes it worse by stretching the sky vertically. A little grain costs
    /// nothing and hides the steps.
    private static func drawGrain(in context: CGContext, width: CGFloat, height: CGFloat) {
        let tile = 64
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 0, count: tile * tile * 4)
        for index in 0..<(tile * tile) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8((state >> 40) & 0xFF)
            // Mid grey with a narrow spread, so drawing it plainly nudges each
            // pixel by a fraction of a level rather than washing the image out.
            pixels[index * 4 + 0] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 255
        }
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let noise = CGImage(
                width: tile, height: tile, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: tile * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        context.saveGState()
        context.setAlpha(0.020)
        context.setBlendMode(.normal)
        let columns = Int(ceil(width / CGFloat(tile)))
        let rows = Int(ceil(height / CGFloat(tile)))
        for row in 0..<rows {
            for column in 0..<columns {
                context.draw(
                    noise,
                    in: CGRect(
                        x: CGFloat(column * tile), y: CGFloat(row * tile),
                        width: CGFloat(tile), height: CGFloat(tile)))
            }
        }
        context.restoreGState()
    }

    private static func fallbackPixel() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(
            CGColor(colorSpace: colorSpace, components: [0.07, 0.08, 0.11, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
