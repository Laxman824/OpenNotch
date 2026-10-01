import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

// "Who is using my microphone / camera?" — macOS only shows an orange or green
// dot. OpenNotch names the app: in the closed notch while it lasts, and in a
// short pop-up when it starts. CoreAudio's per-process list (macOS 14.2+)
// tells us which apps are recording; CoreMediaIO says whether any camera is
// on (macOS doesn't expose which app holds the camera). No permission needed.

struct PrivacyState: Equatable {
    var micApps: [String] = []
    var camera = false
    var active: Bool { !micApps.isEmpty || camera }
}

final class PrivacyMonitor: @unchecked Sendable {
    var onChange: (@MainActor (PrivacyState) -> Void)?
    private let q = DispatchQueue(label: "opennotch.privacy")
    private var timer: DispatchSourceTimer?
    private var last = PrivacyState()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let s = PrivacyState(micApps: Self.micApps(), camera: Self.cameraOn())
        guard s != last else { return }
        last = s
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?(s) } }
    }

    /// Apps currently recording from any input device (not us).
    static func micApps() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for id in ids {
            var running: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            sz = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            _ = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &pid)
            if pid == me { continue }
            var bundle: Unmanaged<CFString>?
            sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            let bid = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            let name = NSRunningApplication(processIdentifier: pid).flatMap { appName($0) }
                ?? bid?.components(separatedBy: ".").last?.capitalized ?? "An app"
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Helpers (e.g. "Google Chrome Helper") report under their parent app's name.
    private static func appName(_ app: NSRunningApplication) -> String? {
        guard var n = app.localizedName else { return nil }
        for suffix in [" Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper"] where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
        }
        return n
    }

    /// Is any camera running right now?
    static func cameraOn() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        for d in devices {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var on: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &on) == noErr, on != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Ears

struct PrivacyLeftEar: View {
    let state: PrivacyState
    var body: some View {
        HStack(spacing: 4) {
            if !state.micApps.isEmpty {
                Image(systemName: "mic.fill").foregroundStyle(.orange)
            }
            if state.camera {
                Image(systemName: "video.fill").foregroundStyle(.green)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .symbolEffect(.pulse, options: .repeating.speed(0.4))
    }
}

struct PrivacyRightEar: View {
    let state: PrivacyState
    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(state.micApps.isEmpty ? "CAMERA ON" : state.camera ? "MIC + CAMERA" : "MICROPHONE")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.8)
                .foregroundStyle(state.micApps.isEmpty ? Color.green : Color.orange)
            Text(state.micApps.isEmpty ? "In use" : state.micApps.joined(separator: ", "))
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6).padding(.trailing, 14)
    }
}

/// When another activity owns the ears: the system-style dots at the edge.
struct PrivacyDots: View {
    let state: PrivacyState
    var body: some View {
        HStack(spacing: 3) {
            if !state.micApps.isEmpty { Circle().fill(Color.orange).frame(width: 6, height: 6) }
            if state.camera { Circle().fill(Color.green).frame(width: 6, height: 6) }
        }
        .help(([state.micApps.isEmpty ? nil : "Microphone: " + state.micApps.joined(separator: ", "),
                state.camera ? "Camera on" : nil].compactMap { $0 }).joined(separator: " · "))
        .accessibilityLabel("Microphone or camera in use")
    }
}
