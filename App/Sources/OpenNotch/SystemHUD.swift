import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps
import SwiftUI

// Short system pop-ups in the closed notch, Dynamic-Island style: volume,
// headphones connecting (with AirPods battery), charger in/out and low
// battery. Nothing here needs a permission: CoreAudio property listeners and
// IOKit power-source notifications. (Brightness has no public API — skipped.)

enum HUDKind: Equatable {
    case volume(level: Float, muted: Bool)
    case device(name: String, icon: String, battery: String?)
    case power(charging: Bool, plugged: Bool, percent: Int)
    /// tone: 1 heads-up (amber), 2 warning (red)
    case health(icon: String, title: String, detail: String, tone: Int)
    case awake(on: Bool, label: String)
}

/// Watches the system and reports changes. All CoreAudio reads happen on
/// `queue`; results hop to the main thread (rule §5.1/5.5).
final class SystemMonitor: @unchecked Sendable {
    var onHUD: (@MainActor (HUDKind) -> Void)?
    /// Updates a device pop-up in place once the (slow) battery lookup lands.
    var onBattery: (@MainActor (String, String) -> Void)?
    /// Plugged in or not — at start and on every change (energy saver).
    var onPowerState: (@MainActor (Bool) -> Void)?

    private let queue = DispatchQueue(label: "opennotch.system-monitor")
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: (Float, Bool)?
    private var volumeBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var ready = false                      // no pop-ups for the initial state
    private var powerSource: CFRunLoopSource?
    private var lastPower: (plugged: Bool, percent: Int)?
    private var warnedLow: Set<Int> = []

    func start() {
        queue.async { [self] in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
                self?.bindDefaultOutput(announce: true)
            }
            bindDefaultOutput(announce: false)
            ready = true
        }
        startPower()
    }

    // MARK: Audio

    private func bindDefaultOutput(announce: Bool) {
        for (a, b) in volumeBlocks {
            var a = a
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, b)
        }
        volumeBlocks = []
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return }
        let changed = id != device
        device = id
        lastVolume = readVolume()

        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(id, &a) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr { volumeBlocks.append((a, block)) }
        }

        guard announce, changed, ready else { return }
        let name = deviceName(id)
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(id))
        let icon = Self.icon(for: name, bluetooth: bluetooth, transport: transport(id))
        emit(.device(name: name, icon: icon, battery: nil))
        if bluetooth { lookUpBattery(name) }
    }

    private func volumeChanged() {
        guard ready, let v = readVolume() else { return }
        if let last = lastVolume, abs(last.0 - v.0) < 0.005, last.1 == v.1 { return }    // both channels fire
        lastVolume = v
        emit(.volume(level: v.0, muted: v.1))
    }

    private func readVolume() -> (Float, Bool)? {
        var vol = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &a),
              AudioObjectGetPropertyData(device, &a, 0, nil, &size, &vol) == noErr else { return nil }
        var mute = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyMute
        if AudioObjectHasProperty(device, &a) { _ = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &mute) }
        return (vol, mute != 0)
    }

    private func deviceName(_ id: AudioObjectID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return "Speakers" }
        return n.takeRetainedValue() as String
    }

    private func transport(_ id: AudioObjectID) -> UInt32 {
        var t = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t
    }

    static func icon(for name: String, bluetooth: Bool, transport: UInt32) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if bluetooth { return "headphones" }
        if transport == kAudioDeviceTransportTypeBuiltIn { return n.contains("headphone") ? "headphones" : "laptopcomputer" }
        if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { return "tv" }
        if transport == kAudioDeviceTransportTypeAirPlay { return "airplayaudio" }
        return "hifispeaker.fill"
    }

    /// AirPods' battery isn't in CoreAudio; system_profiler has it (~1 s, so
    /// off the main thread, once per connect).
    private func lookUpBattery(_ name: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = Self.battery(in: data, device: name) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onBattery?(name, text) }
            }
        }
    }

    /// "L 80% · R 79%" (or just "80%") for `device` from system_profiler JSON.
    static func battery(in data: Data, device: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for sec in sections {
            for entry in sec["device_connected"] as? [[String: Any]] ?? [] {
                for (n, info) in entry where n == device {
                    guard let d = info as? [String: Any] else { continue }
                    let l = d["device_batteryLevelLeft"] as? String, r = d["device_batteryLevelRight"] as? String
                    if let l, let r { return "L \(l) · R \(r)" }
                    if let m = (d["device_batteryLevelMain"] ?? d["device_batteryLevel"]) as? String { return m }
                    if let one = l ?? r { return one }
                }
            }
        }
        return nil
    }

    // MARK: Power

    private func startPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<SystemMonitor>.fromOpaque(ctx).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        lastPower = readPower().map { ($0.plugged, $0.percent) }
        if let p = lastPower { reportPowerState(p.plugged) }
    }

    private func reportPowerState(_ plugged: Bool) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onPowerState?(plugged) } }
    }

    private func powerChanged() {
        guard let p = readPower() else { return }
        defer { lastPower = (p.plugged, p.percent) }
        guard let last = lastPower else { return }
        if p.plugged != last.plugged {
            warnedLow = []
            reportPowerState(p.plugged)
            emit(.power(charging: p.charging, plugged: p.plugged, percent: p.percent))
        } else if !p.plugged, [20, 10, 5].contains(p.percent), !warnedLow.contains(p.percent), p.percent < last.percent {
            warnedLow.insert(p.percent)
            emit(.power(charging: false, plugged: false, percent: p.percent))
        }
    }

    private func readPower() -> (plugged: Bool, charging: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return (d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                    d[kIOPSIsChargingKey] as? Bool ?? false,
                    max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur)
        }
        return nil
    }

    private func emit(_ k: HUDKind) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onHUD?(k) }
        }
    }
}

// MARK: - Views (the notch's ears while a pop-up shows)

struct HUDLeftEar: View {
    var hud: HUDKind
    var body: some View {
        Group {
            switch hud {
            case .volume(let level, let muted):
                Image(systemName: muted || level < 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(level))
                    .foregroundStyle(muted ? AnyShapeStyle(Color.white.opacity(0.6))
                                           : AnyShapeStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[1]],
                                                                          startPoint: .leading, endPoint: .trailing)))
            case .device(_, let icon, _):
                Image(systemName: icon)
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: icon)
            case .power(let charging, let plugged, let percent):
                Image(systemName: plugged ? "battery.100percent.bolt" : Self.batteryIcon(percent))
                    .foregroundStyle(plugged ? AnyShapeStyle(Color.green)
                                             : AnyShapeStyle(percent <= 20 ? Color.red : Color.white))
                    .symbolEffect(.pulse, isActive: charging || percent <= 10)
            case .health(let icon, _, _, let tone):
                Image(systemName: icon)
                    .foregroundStyle(tone >= 2 ? Color.red : Color.orange)
                    .symbolEffect(.bounce, value: icon)
            case .awake(let on, _):
                Image(systemName: on ? "cup.and.saucer.fill" : "moon.zzz.fill")
                    .foregroundStyle(on ? Color(red: 1.0, green: 0.72, blue: 0.4) : Theme.secondary)
                    .symbolEffect(.bounce, value: on)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .contentTransition(.symbolEffect(.replace))
    }

    static func batteryIcon(_ p: Int) -> String {
        p > 87 ? "battery.100percent" : p > 62 ? "battery.75percent" : p > 37 ? "battery.50percent"
            : p > 12 ? "battery.25percent" : "battery.0percent"
    }
}

struct HUDRightEar: View {
    var hud: HUDKind
    var body: some View {
        Group {
            switch hud {
            case .volume(let level, let muted):
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.16))
                            Capsule().fill(LinearGradient(colors: [Theme.glow[0], Theme.glow[1], .white],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(5, g.size.width * CGFloat(muted ? 0 : level)))
                                .opacity(muted ? 0 : 1)
                        }
                    }
                    .frame(height: 5)
                    Text(muted ? "—" : "\(Int((level * 100).rounded()))")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .animation(.spring(duration: 0.22, bounce: 0.2), value: level)
            case .device(let name, _, let battery):
                twoLine(top: "CONNECTED", main: name, sub: battery)
            case .power(let charging, let plugged, let percent):
                twoLine(top: plugged ? (charging ? "CHARGING" : "PLUGGED IN") : (percent <= 20 ? "LOW BATTERY" : "ON BATTERY"),
                        main: "\(percent)%", sub: nil,
                        color: plugged ? .green : (percent <= 20 ? .red : Theme.secondary))
            case .health(_, let title, let detail, let tone):
                twoLine(top: tone >= 2 ? "WARNING" : "HEADS UP", main: title, sub: detail,
                        color: tone >= 2 ? .red : .orange)
            case .awake(let on, let label):
                twoLine(top: on ? "KEEP AWAKE" : "SLEEP AS USUAL", main: on ? label : "Off", sub: nil,
                        color: Color(red: 1.0, green: 0.72, blue: 0.4))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
    }

    private func twoLine(top: String, main: String, sub: String?, color: Color = Theme.glow[0]) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(top).font(.system(size: 7, weight: .heavy, design: .rounded)).tracking(0.8).foregroundStyle(color)
            Text(main).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if let sub { Text(sub).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.secondary) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
