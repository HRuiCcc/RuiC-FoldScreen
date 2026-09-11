// Draws the app icon and packs it into an .icns.
//
// Run by build.sh with the system Swift interpreter. Generating the icon in code
// keeps binary art out of the repository and makes the mark easy to redraw.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

/// Renders the mark at a given pixel size.
///
/// The mark is the effect itself, abstracted: a panel that is wider at the hinge
/// and narrower at the top, which is exactly the keystone the shader produces.
func drawIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // --- Rounded square background -------------------------------------------
    // macOS icons sit inside a superellipse-ish rounded square with roughly a
    // 22% corner radius and a small margin.
    let margin = size * 0.055
    let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.2237
    let background = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(background)
    context.clip()
    let skyColors = [
        CGColor(colorSpace: colorSpace, components: [0.09, 0.10, 0.17, 1])!,
        CGColor(colorSpace: colorSpace, components: [0.20, 0.17, 0.31, 1])!,
        CGColor(colorSpace: colorSpace, components: [0.34, 0.27, 0.42, 1])!,
    ]
    if let gradient = CGGradient(
        colorsSpace: colorSpace, colors: skyColors as CFArray, locations: [0, 0.55, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    // A soft glow behind the panel, so the mark does not sit flat on the field.
    if let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.98, 0.80, 0.62, 0.42])!,
            CGColor(colorSpace: colorSpace, components: [0.98, 0.80, 0.62, 0])!,
        ] as CFArray, locations: [0, 1])
    {
        let centre = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.62)
        context.drawRadialGradient(
            glow, startCenter: centre, startRadius: 0, endCenter: centre,
            endRadius: rect.width * 0.62, options: [])
    }
    context.restoreGState()

    // --- The folded panel ----------------------------------------------------
    // Wider along the bottom (the hinge) and narrower at the top, with a gentle
    // curve along the top edge so it reads as bending rather than as a plain
    // trapezoid.
    let inset = rect.width * 0.20
    let bottomY = rect.minY + rect.height * 0.22
    let topY = rect.minY + rect.height * 0.79
    let bottomHalf = (rect.width - inset * 2) / 2
    let topHalf = bottomHalf * 0.63

    let panel = CGMutablePath()
    panel.move(to: CGPoint(x: rect.midX - bottomHalf, y: bottomY))
    panel.addLine(to: CGPoint(x: rect.midX + bottomHalf, y: bottomY))
    panel.addLine(to: CGPoint(x: rect.midX + topHalf, y: topY - rect.height * 0.055))
    panel.addQuadCurve(
        to: CGPoint(x: rect.midX - topHalf, y: topY - rect.height * 0.055),
        control: CGPoint(x: rect.midX, y: topY + rect.height * 0.03))
    panel.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.05,
        color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.45]))
    context.addPath(panel)
    context.clip()
    let panelColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 0.99, 0.97, 1])!,
        CGColor(colorSpace: colorSpace, components: [0.80, 0.83, 0.90, 1])!,
    ]
    if let gradient = CGGradient(
        colorsSpace: colorSpace, colors: panelColors as CFArray, locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.midX, y: bottomY),
            end: CGPoint(x: rect.midX, y: topY), options: [])
    }
    context.restoreGState()

    // --- Crease ---------------------------------------------------------------
    // One highlight line where the panel bends, which is what makes the shape
    // read as a fold instead of a wedge.
    context.saveGState()
    context.setStrokeColor(
        CGColor(colorSpace: colorSpace, components: [0.42, 0.44, 0.58, 0.55])!)
    context.setLineWidth(max(1, size * 0.012))
    context.setLineCap(.round)
    let creaseY = bottomY + (topY - bottomY) * 0.46
    let creaseHalf = bottomHalf + (topHalf - bottomHalf) * 0.46
    context.move(to: CGPoint(x: rect.midX - creaseHalf * 0.97, y: creaseY))
    context.addQuadCurve(
        to: CGPoint(x: rect.midX + creaseHalf * 0.97, y: creaseY),
        control: CGPoint(x: rect.midX, y: creaseY + rect.height * 0.012))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon: cannot create \(url.lastPathComponent)", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon: cannot write \(url.lastPathComponent)", code: 2)
    }
}

// --- Build the iconset -------------------------------------------------------

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) pairs that iconutil expects.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

/// Rendered once per distinct pixel size and reused across variants.
var cache: [Int: CGImage] = [:]
for (points, scale) in variants {
    let pixels = points * scale
    let image: CGImage
    if let cached = cache[pixels] {
        image = cached
    } else {
        guard let drawn = drawIcon(pixels: pixels) else {
            FileHandle.standardError.write(Data("icon: failed at \(pixels)px\n".utf8))
            exit(1)
        }
        cache[pixels] = drawn
        image = drawn
    }
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try write(image, to: iconset.appendingPathComponent(name))
}

// --- Pack ---------------------------------------------------------------------

let icns = outputDirectory.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("icon: iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("icon: wrote \(icns.lastPathComponent)")
