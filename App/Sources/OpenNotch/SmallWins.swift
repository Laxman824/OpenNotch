import AVFoundation
import Darwin
import IOKit.pwr_mgt
import SwiftUI

// Three small everyday wins:
//   * Keep awake — a power assertion (no `caffeinate` process), ☕ in the ears.
//   * Health pop-ups — sustained CPU load, memory pressure, heat, low disk.
//   * Camera mirror — check yourself before a call; the camera turns off the
//     moment the mirror closes.

// MARK: - Pure logic (checked by app/checks/health_cases.swift)

enum HealthLogic {
    /// Busy fraction 0…1 between two samples of (user, system, idle, nice) ticks.
    static func cpuUsage(prev: [UInt32], now: [UInt32]) -> Double? {
        guard prev.count == 4, now.count == 4 else { return nil }
        // Ticks are 32-bit counters that wrap — subtract with overflow.
        let d = (0..<4).map { Double(now[$0] &- prev[$0]) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return (d[0] + d[1] + d[3]) / total
    }

    /// First process line of `ps -Aceo pcpu,comm -r` (or `rss,comm -m`): (value, name).
    static func topProcess(_ psOutput: String) -> (Double, String)? {
        for line in psOutput.split(separator: "\n").dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let v = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "ps" { continue }
            return (v, name)
        }
        return nil
    }

    /// "1:05:00" left, "42m", "∞".
    static func awakeLabel(until: Date?, now: Date = Date()) -> String {
        guard let until else { return "" }
        if until == .distantFuture { return "∞" }
        let s = max(0, Int(until.timeIntervalSince(now)))
        return s >= 3600 ? String(format: "%d:%02dh", s / 3600, s / 60 % 60) : "\(max(1, (s + 59) / 60))m"
    }
}

// MARK: - Keep awake

@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    /// nil = off; `.distantFuture` = until turned off.
    @Published private(set) var until: Date?
    var isOn: Bool { until != nil }
    var onChange: ((Bool) -> Void)?
    private var assertion = IOPMAssertionID(0)
    private var expiry: Timer?

    /// `minutes` nil = indefinitely.
    func start(minutes: Int?) {
        releaseAssertion()
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "OpenNotch: keep awake" as CFString, &assertion) == kIOReturnSuccess
        guard ok else { AppLog.write("keep awake: assertion failed"); return }
        until = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        expiry?.invalidate()
        if let m = minutes {
            expiry = Timer.scheduledTimer(withTimeInterval: TimeInterval(m * 60), repeats: false) { _ in
                Task { @MainActor in KeepAwake.shared.stop() }
            }
        }
        onChange?(true)
    }

    func stop() {
        guard isOn else { return }
        releaseAssertion()
        expiry?.invalidate()
        until = nil
        onChange?(false)
    }

    func toggle() { isOn ? stop() : start(minutes: nil) }

    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}

// MARK: - Health

/// Samples on its own queue; each alert kind is rate-limited.
final class HealthMonitor: @unchecked Sendable {
    var onAlert: (@MainActor (HUDKind) -> Void)?
    private let q = DispatchQueue(label: "opennotch.health")
    private var timer: DispatchSourceTimer?
    private var memory: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var prevTicks: [UInt32]?
    private var busySince: Date?
    private var lastShown: [String: Date] = [:]
    private var tick = 0

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t

        let m = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: q)
        m.setEventHandler { [weak self, weak m] in
            guard let self, let m else { return }
            let critical = m.data.contains(.critical)
            let top = HealthLogic.topProcess(Self.run("/bin/ps", ["-Aceo", "rss,comm", "-m"]))
            // ps reports RSS in KB.
            let who = top.map { t -> String in
                let gb = t.0 / 1_048_576
                return " · \(t.1) uses " + (gb >= 1 ? String(format: "%.1f GB", gb) : "\(Int(t.0 / 1024)) MB")
            } ?? ""
            self.alert("memory", every: 30 * 60, .health(icon: "memorychip", title: critical ? "Memory critically low" : "Memory pressure high",
                                                          detail: "Close something heavy" + who, tone: critical ? 2 : 1))
        }
        m.resume()
        memory = m

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            let s = ProcessInfo.processInfo.thermalState
            guard s == .serious || s == .critical else { return }
            self?.q.async {
                self?.alert("thermal", every: 30 * 60, .health(icon: "thermometer.high", title: "Your Mac is running hot",
                                                               detail: s == .critical ? "It's slowing itself down — ease off heavy work"
                                                                                      : "Performance may drop for a bit", tone: s == .critical ? 2 : 1))
            }
        }
    }

    private func sample() {
        tick += 1
        if let now = Self.cpuTicks() {
            if let prev = prevTicks, let use = HealthLogic.cpuUsage(prev: prev, now: now) {
                if use > 0.85 {
                    busySince = busySince ?? Date()
                    if Date().timeIntervalSince(busySince!) >= 60 {
                        let top = HealthLogic.topProcess(Self.run("/bin/ps", ["-Aceo", "pcpu,comm", "-r"]))
                        alert("cpu", every: 30 * 60, .health(icon: "cpu", title: "CPU busy · \(Int(use * 100))%",
                                                             detail: top.map { "\($0.1) is using \(Int($0.0))%" } ?? "For over a minute",
                                                             tone: 1))
                    }
                } else if use < 0.6 {
                    busySince = nil
                }
            }
            prevTicks = now
        }
        if tick % 60 == 1 {                     // every 10 minutes
            let url = URL(fileURLWithPath: "/")
            if let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < 10_000_000_000 {
                let gb = Double(free) / 1_000_000_000
                alert("disk", every: 6 * 3600, .health(icon: "internaldrive", title: "Disk almost full",
                                                       detail: String(format: "%.1f GB left", gb), tone: gb < 3 ? 2 : 1))
            }
        }
    }

    private func alert(_ kind: String, every cooldown: TimeInterval, _ hud: HUDKind) {
        if let last = lastShown[kind], Date().timeIntervalSince(last) < cooldown { return }
        lastShown[kind] = Date()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onAlert?(hud) } }
    }

    private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Camera mirror

/// The capture session lives on its own queue (start/stop block); the view
/// only holds the preview layer.
final class CameraIO: @unchecked Sendable {
    let session = AVCaptureSession()
    private let q = DispatchQueue(label: "opennotch.camera")
    private var configured = false

    func start(_ done: @escaping @Sendable (Bool) -> Void) {
        q.async { [self] in
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    ?? AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                    session.addInput(input)
                    configured = true
                }
                session.commitConfiguration()
            }
            guard configured else { done(false); return }
            if !session.isRunning { session.startRunning() }
            done(session.isRunning)
        }
    }

    func stop() {
        q.async { [self] in if session.isRunning { session.stopRunning() } }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        mirror(layer)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if let l = v.layer as? AVCaptureVideoPreviewLayer { mirror(l) }
    }

    /// Like a mirror, not like how others see you.
    private func mirror(_ l: AVCaptureVideoPreviewLayer) {
        guard let c = l.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
    }
}

struct MirrorView: View {
    @ObservedObject var notch: NotchController
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notch.notchSize.height + 4)
            ZStack(alignment: .topTrailing) {
                CameraPreview(session: notch.camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    .accessibilityLabel("Camera preview")
                Button { notch.closeMirror() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .buttonStyle(HoverLift())
                .padding(8)
                .accessibilityLabel("Close camera mirror")
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Camera on · closes when you move away").font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.5)))
                .padding(8)
                .accessibilityHidden(true)
            }
            .scaleEffect(shown ? 1 : 0.92, anchor: .top)
            .opacity(shown ? 1 : 0)
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .onAppear { withAnimation(Motion.peek.delay(0.05)) { shown = true } }
        .onExitCommand { notch.closeMirror() }
    }
}

// MARK: - Ear views

struct AwakeEars: View {
    @ObservedObject var awake = KeepAwake.shared
    let side: Bool          // false = left (icon), true = right (time)

    var body: some View {
        if side {
            TimelineView(.periodic(from: .now, by: 20)) { ctx in
                Text(HealthLogic.awakeLabel(until: awake.until, now: ctx.date))
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.45))
            }
        } else {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.8, blue: 0.5), Color(red: 0.95, green: 0.55, blue: 0.3)],
                                                startPoint: .top, endPoint: .bottom))
                .symbolEffect(.pulse, options: .repeating.speed(0.3))
        }
    }
}
