import Foundation
import IOKit.hid

/// Where lid angles come from.
///
/// The seam exists because the angle genuinely has more than one source: the
/// real HID sensor on a MacBook, and a scripted sweep used by the offline
/// harness and tests. Both adapters below satisfy this protocol, so the rest of
/// the app never learns which one it is talking to.
protocol LidAngleSource: AnyObject {
    /// Latest angle in degrees, or `nil` while no reading is available.
    var onAngle: ((Double?) -> Void)? { get set }

    /// Whether the underlying source exists at all.
    ///
    /// Distinct from `onAngle` delivering `nil`: a sensor that is present but
    /// has not produced its first reading yet is available, and callers must not
    /// treat that as missing hardware. Checking this instead of the last reading
    /// removes a race at launch, where the effect starts before the first poll.
    var isAvailable: Bool { get }

    func start()
    func stop()

    /// Poll at full rate while the effect is live, and slowly while idle so the
    /// app costs nothing in the background.
    func setPolling(active: Bool)

    /// Re-open the device. Used after sleep/wake, when the HID device is replaced.
    func reconnect()
}

// MARK: - Real sensor

/// Reads the MacBook lid angle from the built-in HID sensor.
///
/// Apple does not document this sensor. The lid reports as an Apple-vendor HID
/// device with primary usage page `0x20` and usage `0x8A`, exposing the angle as
/// a feature report: two little-endian bytes at offset 1, in degrees. Access is
/// read-only and non-exclusive — no kext, no root, no driver install.
///
/// Because the report layout is undocumented, every value is validated before
/// use. A model that reports something else degrades to "no sensor" rather than
/// producing nonsense angles.
final class HIDLidAngleSource: LidAngleSource {
    var onAngle: ((Double?) -> Void)?

    /// True once a lid device was found and opened.
    var isAvailable: Bool { device != nil }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.ruic.foldscreen.lid", qos: .userInteractive)
    private var active = false

    /// Apple's USB vendor id. The lid sensor is an internal Apple HID service.
    private static let appleVendorID = 0x05AC
    /// Usage page/usage of the lid angle sensor, as observed on Apple silicon.
    private static let sensorUsagePage = 0x20
    private static let sensorUsage = 0x8A

    private static let idleInterval = DispatchTimeInterval.milliseconds(200)
    private static let activeInterval = DispatchTimeInterval.milliseconds(16)

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.appleVendorID,
            kIOHIDPrimaryUsagePageKey: Self.sensorUsagePage,
            kIOHIDPrimaryUsageKey: Self.sensorUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        // A failed open simply leaves `device` nil; callers see "no sensor".
        IOHIDManagerOpen(manager, 0)
        device = Self.firstOpenableDevice(in: manager)
    }

    /// Opens the first matching device that accepts a connection. Probing with
    /// `IOHIDDeviceOpen` is the only way to know a candidate is usable.
    private static func firstOpenableDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return devices.first { IOHIDDeviceOpen($0, 0) == kIOReturnSuccess }
    }

    /// One sensor reading, or `nil` if the device is missing or the report does
    /// not look like an angle.
    func read() -> Double? {
        guard let device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        let status = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard status == kIOReturnSuccess, length >= 3 else { return nil }
        // Report id at 0, then a little-endian 16-bit angle in degrees.
        let degrees = Int(bytes[1]) | Int(bytes[2]) << 8
        // A real MacBook never opens past ~140°, and an angle below zero means a
        // different report layout. Reject both rather than fold on garbage.
        guard (0...180).contains(degrees) else { return nil }
        return Double(degrees)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.idleInterval, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let angle = self.read()
            DispatchQueue.main.async { [weak self] in self?.onAngle?(angle) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setPolling(active: Bool) {
        guard active != self.active else { return }
        self.active = active
        timer?.schedule(
            deadline: .now(),
            repeating: active ? Self.activeInterval : Self.idleInterval,
            leeway: active ? .milliseconds(2) : .milliseconds(8))
    }

    func reconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if let device = self.device { IOHIDDeviceClose(device, 0) }
            self.device = Self.firstOpenableDevice(in: self.manager)
        }
    }

    deinit {
        timer?.cancel()
        if let device { IOHIDDeviceClose(device, 0) }
        IOHIDManagerClose(manager, 0)
    }
}

// MARK: - Scripted source

/// Replays a list of angles on a timer.
///
/// Used by the offline render harness and the self-test so the fold can be
/// exercised end to end without a physical lid, and so the app can preview the
/// motion on hardware whose sensor is unsupported.
final class ScriptedLidAngleSource: LidAngleSource {
    var onAngle: ((Double?) -> Void)?

    var isAvailable: Bool { !angles.isEmpty }

    private let angles: [Double]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "app.ruic.foldscreen.scripted")
    private var timer: DispatchSourceTimer?
    private var index = 0

    init(angles: [Double], interval: TimeInterval = 0.05) {
        self.angles = angles
        self.interval = interval
    }

    /// A symmetric open → shut → open sweep, the same motion the live effect sees.
    static func sweep(from open: Double = 118, to shut: Double = 12, steps: Int = 60)
        -> ScriptedLidAngleSource
    {
        let half = max(2, steps / 2)
        var values: [Double] = []
        for i in 0...half {
            let t = Double(i) / Double(half)
            values.append(open - (open - shut) * (t * t * (3 - 2 * t)))
        }
        for i in stride(from: half - 1, through: 0, by: -1) {
            let t = Double(i) / Double(half)
            values.append(open - (open - shut) * (t * t * (3 - 2 * t)))
        }
        return ScriptedLidAngleSource(angles: values)
    }

    func start() {
        guard timer == nil, !angles.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let angle = self.angles[self.index % self.angles.count]
            self.index += 1
            DispatchQueue.main.async { [weak self] in self?.onAngle?(angle) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setPolling(active: Bool) {}
    func reconnect() {}
}
