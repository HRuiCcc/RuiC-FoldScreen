import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders

/// Single-slot handoff for captured frames.
///
/// ScreenCaptureKit delivers on its own queue while Metal draws on the main
/// thread, so the newest frame is parked behind a lock and the renderer takes
/// whatever is current. Dropping stale frames is deliberate: the overlay only
/// ever wants the most recent desktop.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func put(_ frame: CVPixelBuffer) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}

/// Draws the folded desktop.
///
/// The fold itself is a fragment shader; everything here is the scaffolding
/// around it: compiling that shader at runtime, building the defocus ladder once
/// per source size, and handing Metal a texture for each frame.
final class FoldRenderer: NSObject, MTKViewDelegate {

    /// One frame's worth of input, supplied by the controller.
    struct Scene {
        var uniforms: FoldUniforms
        /// Live desktop frame, or `nil` to draw the built-in preview image.
        var source: CVPixelBuffer?
    }

    /// Sigmas for the defocus ladder, at a working width of 512. Fixed by design:
    /// the ladder defines the range of blur, and the shader picks a point along
    /// it per pixel, so changing the blur amount never rebuilds these kernels.
    private static let ladderSigmas: [Float] = [3, 8, 20, 44]
    private static let ladderReferenceWidth: Float = 512
    private static let workingWidthCap = 512

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// The built-in preview image, used whenever there is no live capture.
    private let preview: MTLTexture

    /// Defocus ladder, rebuilt only when the source resolution changes.
    private var ladder: [MTLTexture] = []
    private var kernels: [MPSImageGaussianBlur] = []
    private var scaler: MPSImageBilinearScale
    private var ladderSize: (width: Int, height: Int) = (0, 0)

    /// Supplies the uniforms and source frame for each draw. Called on the main
    /// thread, which is where MTKView draws.
    var scene: @MainActor () -> Scene = { Scene(uniforms: FoldUniforms(), source: nil) }

    init(previewImage: CGImage) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FoldRendererError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw FoldRendererError.noCommandQueue
        }
        self.device = device
        self.queue = queue
        self.scaler = MPSImageBilinearScale(device: device)

        // The shader is compiled from source at launch. That keeps the project
        // buildable with the command line tools alone, with no Xcode and no
        // offline Metal compiler in the loop.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: FoldShaderSource.text, options: nil)
        } catch {
            throw FoldRendererError.shaderCompilationFailed(String(describing: error))
        }
        guard let vertexFunction = library.makeFunction(name: "foldVertex"),
            let fragmentFunction = library.makeFunction(name: "foldFragment")
        else {
            throw FoldRendererError.missingShaderFunction
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        self.preview = try FoldRenderer.makeTexture(device: device, from: previewImage)
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: - View

    /// A view wired to draw this renderer. Starts paused; the controller decides
    /// when the fold is worth animating.
    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.delegate = self
        view.isPaused = true
        return view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let scene = MainActor.assumeIsolated { self.scene() }

        // Prefer the live desktop; fall back to the preview image, which is what
        // makes the settings preview work with no screen recording permission.
        var liveTexture: MTLTexture?
        var retained: CVMetalTexture?
        if let buffer = scene.source, let cache = textureCache {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0, &retained)
            if let retained { liveTexture = CVMetalTextureGetTexture(retained) }
        }
        let sharp = liveTexture ?? preview

        var uniforms = scene.uniforms
        uniforms.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))

        let levels = defocusLevels(for: sharp, commandBuffer: commandBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encode(into: encoder, sharp: sharp, levels: levels, uniforms: uniforms)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        // The capture texture is only valid while its pixel buffer is retained.
        let held = (retained, scene.source)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        commandBuffer.commit()
    }

    // MARK: - Offscreen rendering

    /// Renders one frame through the exact pipeline the overlay uses and returns
    /// it as an image.
    ///
    /// The QA harness drives this, which means the frames it inspects cannot
    /// drift from what the app actually shows.
    func snapshot(
        size: CGSize, uniforms: FoldUniforms, source: CGImage? = nil, sourceBuffer: CVPixelBuffer? = nil
    ) throws -> CGImage {
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
            let commandBuffer = queue.makeCommandBuffer()
        else { throw FoldRendererError.renderTargetAllocationFailed }

        var sharp = preview
        var retained: CVMetalTexture?
        if let sourceBuffer, let cache = textureCache {
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, sourceBuffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(sourceBuffer), CVPixelBufferGetHeight(sourceBuffer), 0,
                &retained)
            if let retained, let texture = CVMetalTextureGetTexture(retained) { sharp = texture }
        } else if let source {
            sharp = try FoldRenderer.makeTexture(device: device, from: source)
        }

        var adjusted = uniforms
        adjusted.aspect = Float(width) / Float(height)

        let levels = defocusLevels(for: sharp, commandBuffer: commandBuffer)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw FoldRendererError.encoderUnavailable
        }
        encode(into: encoder, sharp: sharp, levels: levels, uniforms: adjusted)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw FoldRendererError.imageAssemblyFailed }

        withExtendedLifetime(retained) {}
        return image
    }

    // MARK: - Internals

    private func encode(
        into encoder: MTLRenderCommandEncoder, sharp: MTLTexture, levels: [MTLTexture],
        uniforms: FoldUniforms
    ) {
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sharp, index: 0)
        for (index, texture) in levels.enumerated() {
            encoder.setFragmentTexture(texture, index: index + 1)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Downscales the source and blurs it at each ladder sigma.
    ///
    /// Returns the four defocused levels, or four references to `sharp` when the
    /// source cannot be scaled, in which case the shader's cross-fade collapses
    /// to the untouched desktop.
    private func defocusLevels(for source: MTLTexture, commandBuffer: MTLCommandBuffer)
        -> [MTLTexture]
    {
        // Working on a quarter-size copy keeps the cost flat regardless of the
        // capture resolution, which matters because Retina frames are large.
        let width = max(1, min(source.width / 4, Self.workingWidthCap))
        let height = max(1, source.height * width / source.width)
        prepareLadder(width: width, height: height)
        guard ladder.count == Self.ladderSigmas.count + 1 else {
            return Array(repeating: source, count: Self.ladderSigmas.count)
        }
        scaler.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: ladder[0])
        for (index, kernel) in kernels.enumerated() {
            kernel.encode(
                commandBuffer: commandBuffer, sourceTexture: ladder[0],
                destinationTexture: ladder[index + 1])
        }
        return Array(ladder.dropFirst())
    }

    private func prepareLadder(width: Int, height: Int) {
        guard ladderSize.width != width || ladderSize.height != height || ladder.isEmpty else {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        let textures = (0...Self.ladderSigmas.count).compactMap { _ in
            device.makeTexture(descriptor: descriptor)
        }
        guard textures.count == Self.ladderSigmas.count + 1 else {
            ladder = []
            kernels = []
            ladderSize = (0, 0)
            return
        }

        // Sigmas scale with the working width so the blur reads the same on a
        // low-resolution preview and a Retina capture.
        let scale = Float(width) / Self.ladderReferenceWidth
        kernels = Self.ladderSigmas.map { sigma in
            let kernel = MPSImageGaussianBlur(device: device, sigma: max(0.5, sigma * scale))
            kernel.edgeMode = .clamp
            return kernel
        }
        ladder = textures
        ladderSize = (width, height)
    }

    private static func makeTexture(device: MTLDevice, from image: CGImage) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FoldRendererError.previewTextureAllocationFailed
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        pixels.withUnsafeMutableBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}

enum FoldRendererError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case shaderCompilationFailed(String)
    case missingShaderFunction
    case previewTextureAllocationFailed
    case renderTargetAllocationFailed
    case encoderUnavailable
    case imageAssemblyFailed

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "这台 Mac 没有可用的 Metal 设备。"
        case .noCommandQueue: return "无法创建 Metal 命令队列。"
        case .shaderCompilationFailed(let detail): return "折叠着色器编译失败：\(detail)"
        case .missingShaderFunction: return "着色器缺少 foldVertex / foldFragment 入口。"
        case .previewTextureAllocationFailed: return "无法分配预览贴图。"
        case .renderTargetAllocationFailed: return "无法分配离屏渲染目标。"
        case .encoderUnavailable: return "无法创建 Metal 渲染编码器。"
        case .imageAssemblyFailed: return "无法把渲染结果组装成图像。"
        }
    }
}
