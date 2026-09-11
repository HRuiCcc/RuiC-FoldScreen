import Combine
import CoreVideo
import Foundation
import MetalKit
import SwiftUI

/// The fold preview shown in settings.
///
/// Deliberately independent of `LiveFold`: it renders the built-in artwork
/// through the same shader, so it needs no screen recording permission and keeps
/// working before the effect has ever been enabled.
@MainActor
final class FoldPreview: ObservableObject {

    /// Lid angle being previewed, in degrees.
    @Published var angle: Double = 72
    @Published private(set) var isPlaying = false

    /// Length of one play-through, in seconds.
    private static let sweepDuration: Double = 4.4

    private let store: SettingsStore
    private let frames = FrameStore()
    private(set) var renderer: FoldRenderer?
    private(set) var loadFailure: String?

    private var ticker: Timer?
    private var startedAt = CACurrentMediaTime()

    init(store: SettingsStore) {
        self.store = store
        let artwork = PreviewArtwork.make()
        do {
            let renderer = try FoldRenderer(previewImage: artwork)
            renderer.scene = { [weak self] in
                guard let self else {
                    return FoldRenderer.Scene(uniforms: FoldUniforms(), source: nil)
                }
                let settings = self.store.settings
                let closure = FoldKinematics.closure(
                    angle: self.angle, clearAngle: settings.clearAngle)
                var uniforms = FoldTuning.uniforms(
                    closure: closure, settings: settings, aspect: 1.6,
                    workingWidth: Self.previewWorkingWidth)
                uniforms.aspect = 1.6
                return FoldRenderer.Scene(uniforms: uniforms, source: self.frames.current())
            }
            self.renderer = renderer
        } catch {
            // A missing GPU is not fatal for the rest of the app; the preview
            // just reports itself as unavailable.
            self.loadFailure = error.localizedDescription
        }
        // A still frame means the preview never needs a live capture.
        if let buffer = StillFrameSource(image: artwork) as DesktopFrames? {
            Task { try? await buffer.start(displayID: 0) }
        }
    }

    /// The preview draws at a fixed working width so it matches the overlay's
    /// blur scale rather than drifting with the preview's on-screen size.
    private static let previewWorkingWidth: Double = 512

    var isAvailable: Bool { renderer != nil }

    /// Plays one open → shut → open sweep.
    func play() {
        guard renderer != nil else { return }
        startedAt = CACurrentMediaTime()
        isPlaying = true
        startTicking()
    }

    func pause() {
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    /// Called when the user drags the angle slider, which takes over from the
    /// animation.
    func scrub() {
        pause()
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard isPlaying else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        let settings = store.settings
        let progress = (CACurrentMediaTime() - startedAt) / Self.sweepDuration
        if progress >= 1 {
            isPlaying = false
            angle = settings.clearAngle
            ticker?.invalidate()
            ticker = nil
            return
        }
        // Ease in and out of the sweep so the loop reads as one motion.
        let eased = pow(sin(progress * .pi), 2)
        let deepest = max(14, settings.clearAngle - 92)
        angle = settings.clearAngle - (settings.clearAngle - deepest) * eased
    }

    deinit {
        ticker?.invalidate()
    }
}

/// Hosts the preview's Metal view inside SwiftUI.
///
/// The view redraws on demand rather than running free: the preview is a still
/// image most of the time, and a settings window should not hold the GPU at
/// sixty frames a second while the user reads it.
struct FoldPreviewView: NSViewRepresentable {
    @ObservedObject var preview: FoldPreview

    func makeNSView(context: Context) -> MTKView {
        guard let renderer = preview.renderer else {
            let placeholder = MTKView()
            placeholder.clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1)
            return placeholder
        }
        let view = renderer.makeView()
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // `angle` changes on every animation tick, and touching the view here is
        // what turns that into a new frame.
        view.setNeedsDisplay(view.bounds)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}
