import AppKit
import Darwin
import ImageIO
import IOKit.ps
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - System stats

/// CPU, memory, disk, network and battery — sampled once a second, and only
/// while the module is on screen.
@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memUsed: Double = 0
    @Published private(set) var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var netHistory: [Double] = []
    @Published private(set) var battery: (percent: Int, charging: Bool, onAC: Bool)?

    private var timer: Timer?
    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var prevNet: (UInt64, UInt64, Date)?

    func startSampling() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stopSampling() { timer?.invalidate(); timer = nil }

    private func sample() {
        // CPU
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let t = info.cpu_ticks
            if let p = prevTicks {
                let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1), idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
                let total = user + sys + idle + nice
                cpu = total > 0 ? (user + sys + nice) / total : 0
                cpuHistory = Array((cpuHistory + [cpu]).suffix(60))
            }
            prevTicks = t
        }
        // Memory
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let vkr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vkr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            memUsed = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }
        // Disk
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
        // Network
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var p = ifaddr
            while let a = p {
                let name = String(cString: a.pointee.ifa_name)
                if a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
                   let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    inB += UInt64(data.pointee.ifi_ibytes)
                    outB += UInt64(data.pointee.ifi_obytes)
                }
                p = a.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        let now = Date()
        if let (pi, po, pt) = prevNet {
            let dt = max(0.1, now.timeIntervalSince(pt))
            netIn = inB >= pi ? Double(inB - pi) / dt : 0
            netOut = outB >= po ? Double(outB - po) / dt : 0
            netHistory = Array((netHistory + [netIn + netOut]).suffix(60))
        }
        prevNet = (inB, outB, now)
        // Battery
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                battery = (cur * 100 / max, d[kIOPSIsChargingKey] as? Bool ?? false,
                           (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            }
        }
    }
}

func formatBytes(_ b: Double) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    f.allowsNonnumericFormatting = false      // "0 KB", not "Zero KB"
    return f.string(fromByteCount: Int64(b))
}

struct Ring: View {
    let value: Double
    let label: String
    let detail: String
    let colors: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: value)
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 74, height: 74)
            Text(label).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.glow[0]
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 1, 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                    let y = g.size.height * (1 - CGFloat(v / maxV))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

struct SystemView: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Ring(value: stats.cpu, label: "CPU", detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                     colors: [Theme.glow[0], Theme.glow[1]])
                Ring(value: stats.memTotal > 0 ? stats.memUsed / stats.memTotal : 0, label: "Memory",
                     detail: "\(formatBytes(stats.memUsed)) / \(formatBytes(stats.memTotal))", colors: [Theme.glow[1], Theme.glow[2]])
                Ring(value: stats.diskTotal > 0 ? 1 - stats.diskFree / stats.diskTotal : 0, label: "Disk",
                     detail: "\(formatBytes(stats.diskFree)) free", colors: [Theme.glow[2], Theme.glow[3]])
                if let b = stats.battery {
                    Ring(value: Double(b.percent) / 100, label: b.charging ? "Charging" : (b.onAC ? "On power" : "Battery"),
                         detail: b.charging ? "⚡︎ plugged in" : "\(b.percent)%",
                         colors: b.percent < 20 && !b.onAC ? [.red, .orange] : [.green, .mint])
                }
            }
            HStack(spacing: 14) {
                statCard("CPU load", stats.cpuHistory, "\(Int(stats.cpu * 100))%", Theme.glow[0])
                statCard("Network", stats.netHistory,
                         "↓ \(formatBytes(stats.netIn))/s  ↑ \(formatBytes(stats.netOut))/s", Theme.glow[2])
            }
        }
        .padding(18)
        .onAppear { stats.startSampling() }
        .onDisappear { stats.stopSampling() }
    }

    private func statCard(_ title: String, _ values: [Double], _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(value).font(.system(size: 11).monospacedDigit())
            }
            Sparkline(values: values, color: color).frame(height: 40)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
    }
}

// MARK: - Screen time

/// Today's app usage, counted locally. Counting pauses when you're idle for
/// two minutes, when the screen sleeps, and when the Mac sleeps.
@MainActor
final class ScreenTimeTracker: ObservableObject {
    @Published private(set) var today: [String: Double] = [:]        // bundle id → seconds
    @Published private(set) var names: [String: String] = [:]
    private var timer: Timer?
    private var asleep = false
    private var lastTick = Date()
    private var day = TimerStore.dayKey(Date())
    private var path: String { opennotchDir("screentime") + "/\(day).json" }

    func start() {
        load()
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.screensDidSleepNotification, true),
                              (NSWorkspace.didWakeNotification, false), (NSWorkspace.screensDidWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.asleep = value; self?.lastTick = Date() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = min(10, now.timeIntervalSince(lastTick))
        lastTick = now
        let key = TimerStore.dayKey(now)
        if key != day { save(); day = key; today = [:] }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard !asleep, idle < 120, let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier else { return }
        today[id, default: 0] += dt
        if names[id] == nil { names[id] = app.localizedName ?? id }
        if Int(now.timeIntervalSince1970) % 60 < 5 { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        today = obj["seconds"] as? [String: Double] ?? [:]
        names = obj["names"] as? [String: String] ?? [:]
    }

    func save() {
        let obj: [String: Any] = ["seconds": today, "names": names]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    var total: Double { today.values.reduce(0, +) }
    var ranked: [(String, Double)] { today.sorted { $0.value > $1.value } }
}

func durationText(_ s: Double) -> String {
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : (m > 0 ? "\(m)m" : "<1m")
}

struct ScreenTimeView: View {
    @ObservedObject var tracker: ScreenTimeTracker

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: durationText(tracker.total) + " today",
                         subtitle: "Counted on this Mac only · pauses when idle or asleep") { EmptyView() }
            if tracker.ranked.isEmpty {
                EmptyHint(icon: "hourglass", text: "Counting starts now. Check back in a bit.")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        let top = tracker.ranked.first?.1 ?? 1
                        ForEach(tracker.ranked.prefix(12), id: \.0) { id, secs in
                            HStack(spacing: 10) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                    appIcon(forPath: url.path, size: 22).resizable().frame(width: 22, height: 22)
                                } else {
                                    Image(systemName: "app").frame(width: 22)
                                }
                                Text(tracker.names[id] ?? id).font(.system(size: 12)).frame(width: 130, alignment: .leading).lineLimit(1)
                                GeometryReader { g in
                                    Capsule().fill(Theme.userBubble)
                                        .frame(width: max(4, g.size.width * CGFloat(secs / top)))
                                }
                                .frame(height: 8)
                                Text(durationText(secs)).font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.secondary).frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Image converter

@MainActor
final class ConvertStore: ObservableObject {
    enum Format: String, CaseIterable { case jpeg = "JPEG", png = "PNG", heic = "HEIC", pdf = "PDF" }
    @Published var inputs: [URL] = []
    @Published var format: Format = .jpeg
    @Published var quality: Double = 0.85
    @Published var maxSide: Int = 0          // 0 = original
    @Published private(set) var outputs: [URL] = []
    @Published private(set) var errors: [String] = []

    func add(_ urls: [URL]) {
        let imgs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
        inputs = Array(Set(inputs + imgs)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        outputs = []
        errors = urls.count > imgs.count ? ["Skipped \(urls.count - imgs.count) non-image file(s)."] : []
    }

    func convert() {
        outputs = []
        errors = []
        for url in inputs {
            do { outputs.append(try convertOne(url)) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private func convertOne(_ url: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw err("can't read image") }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceCreateThumbnailFromImageAlways: true]
        if maxSide > 0 { opts[kCGImageSourceThumbnailMaxPixelSize] = maxSide }
        else if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw err("decode failed") }
        let ext = format == .jpeg ? "jpg" : format.rawValue.lowercased()
        var out = url.deletingPathExtension().appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: out.path) {     // never overwrite: "photo (1).jpg"
            out = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n)).\(ext)")
            n += 1
        }
        if format == .pdf {
            let doc = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: img, size: .zero)) else { throw err("PDF failed") }
            doc.insert(page, at: 0)
            guard doc.write(to: out) else { throw err("PDF write failed") }
            return out
        }
        let type: UTType = format == .jpeg ? .jpeg : (format == .png ? .png : .heic)
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)
        else { throw err("\(format.rawValue) not supported") }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw err("write failed") }
        return out
    }

    private func err(_ s: String) -> NSError { NSError(domain: "convert", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

struct ConvertView: View {
    @ObservedObject var store: ConvertStore
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            ModuleHeader(title: "Convert images", subtitle: "New files are written next to the originals") {
                if !store.inputs.isEmpty {
                    Button("Clear") { store.inputs = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(ConvertStore.Format.allCases, id: \.self) { f in
                    Chip(label: f.rawValue, selected: store.format == f) { store.format = f }
                }
                Spacer()
                Menu(store.maxSide == 0 ? "Original size" : "Max \(store.maxSide)px") {
                    ForEach([0, 3840, 2048, 1280, 1024, 512], id: \.self) { s in
                        Button(s == 0 ? "Original size" : "Max \(s)px") { store.maxSide = s }
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize().font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 18)
            if store.format == .jpeg || store.format == .heic {
                HStack {
                    Text("Quality").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Slider(value: $store.quality, in: 0.3...1)
                    Text("\(Int(store.quality * 100))").font(.system(size: 11).monospacedDigit()).frame(width: 28)
                }
                .padding(.horizontal, 18)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(targeted ? Color.white.opacity(0.6) : Theme.hairline)
                if store.inputs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26, weight: .light))
                        Text("Drop images here").font(.system(size: 12))
                        Button("Choose…") { choose() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.glow[0])
                    }
                    .foregroundStyle(Theme.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.inputs, id: \.self) { u in
                                HStack {
                                    Image(systemName: store.outputs.contains { $0.deletingPathExtension().lastPathComponent.hasPrefix(u.deletingPathExtension().lastPathComponent) } ? "checkmark.circle.fill" : "photo")
                                        .foregroundStyle(store.outputs.isEmpty ? Theme.secondary : .green)
                                    Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                }
                            }
                            ForEach(store.errors, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 18)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { p in loadURLs(p) { store.add($0) }; return true }
            HStack {
                if !store.outputs.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.outputs) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                PillButton(label: "Convert \(store.inputs.count) to \(store.format.rawValue)", icon: "arrow.triangle.2.circlepath",
                           primary: true) { store.convert() }
                    .disabled(store.inputs.isEmpty)
                    .opacity(store.inputs.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { store.add(p.urls) }
    }
}

// MARK: - AI usage (Claude Code / Codex / OpenNotch)

/// Daily token totals parsed from local logs only — no accounts, no quota
/// calls. Per-file results are cached by (mtime, size) because ~/.claude
/// alone can be hundreds of MB.
@MainActor
final class UsageStore: ObservableObject {
    enum Source: String, CaseIterable { case claude = "Claude Code", codex = "Codex", assistant = "OpenNotch" }
    @Published var source: Source = .claude
    @Published private(set) var daily: [Source: [String: Int]] = [:]
    @Published private(set) var loading = false
    private var loaded = false

    func load(force: Bool = false) {
        guard !loading, force || !loaded else { return }
        loading = true
        Task.detached(priority: .utility) {
            let result = UsageParser.run()
            await MainActor.run {
                self.daily = result
                self.loading = false
                self.loaded = true
            }
        }
    }
}

enum UsageParser {
    typealias Daily = [String: Int]
    private static let cachePath = opennotchDir("") + "/usage_cache.json"

    static func run() -> [UsageStore.Source: Daily] {
        var cache = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cachePath)))) as? [String: [String: Any]] ?? [:]
        let home = NSHomeDirectory()
        var out: [UsageStore.Source: Daily] = [:]
        let sources: [(UsageStore.Source, String, (URL) -> Daily)] = [
            (.claude, "\(home)/.claude/projects", parseClaude),
            (.codex, "\(home)/.codex/sessions", parseCodex),
            (.assistant, AppPaths.root + "/traces", parseTraces),
        ]
        var fresh: [String: [String: Any]] = [:]
        for (src, dir, parse) in sources {
            var total: Daily = [:]
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir),
                                                         includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let stamp = "\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(v?.fileSize ?? 0)"
                var days: Daily
                if let c = cache[url.path], c["stamp"] as? String == stamp, let d = c["days"] as? Daily {
                    days = d
                } else {
                    days = parse(url)
                }
                fresh[url.path] = ["stamp": stamp, "days": days]
                for (k, n) in days { total[k, default: 0] += n }
            }
            out[src] = total
        }
        cache = fresh
        if let data = try? JSONSerialization.data(withJSONObject: cache) { try? data.write(to: URL(fileURLWithPath: cachePath)) }
        return out
    }

    private static func lines(_ url: URL, containing needle: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var result: [[String: Any]] = []
        let needleData = Data(needle.utf8)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var start = 0
            let n = buf.count
            while start < n {
                var end = start
                while end < n && buf[end] != 10 { end += 1 }
                let slice = Data(bytes: buf.baseAddress!.advanced(by: start), count: end - start)
                if slice.range(of: needleData) != nil,
                   let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                    result.append(obj)
                }
                start = end + 1
            }
        }
        return result
    }

    private static func day(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        // Timestamps are UTC; bucket by the local day.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) { return TimerStore.dayKey(d) }
        return String(iso.prefix(10))
    }

    static func parseClaude(_ url: URL) -> Daily {
        var seen = Set<String>()
        var out: Daily = [:]
        for obj in lines(url, containing: "\"usage\"") {
            guard let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let d = day(obj["timestamp"] as? String) else { continue }
            let id = (msg["id"] as? String ?? "") + (obj["requestId"] as? String ?? "")
            if !id.isEmpty { guard seen.insert(id).inserted else { continue } }
            let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + (u[$1] as? Int ?? 0) }
            out[d, default: 0] += n
        }
        return out
    }

    static func parseCodex(_ url: URL) -> Daily {
        var out: Daily = [:]
        var last = 0
        for obj in lines(url, containing: "token_count") {
            guard let p = obj["payload"] as? [String: Any], let info = p["info"] as? [String: Any],
                  let tot = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                  let d = day(obj["timestamp"] as? String) else { continue }
            if tot > last { out[d, default: 0] += tot - last; last = tot }     // cumulative → deltas
        }
        return out
    }

    static func parseTraces(_ url: URL) -> Daily {
        var out: Daily = [:]
        for obj in lines(url, containing: "llm.request") {
            guard let a = obj["attrs"] as? [String: Any], let start = obj["start"] as? Double else { continue }
            let n = (a["gen_ai.usage.input_tokens"] as? Int ?? 0) + (a["gen_ai.usage.output_tokens"] as? Int ?? 0)
            if n > 0 { out[TimerStore.dayKey(Date(timeIntervalSince1970: start)), default: 0] += n }
        }
        return out
    }
}

func compactNumber(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
    return "\(n)"
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    private let weeks = 20

    var body: some View {
        let days = store.daily[store.source] ?? [:]
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let sum: (Int) -> Int = { n in
            (0..<n).reduce(0) { acc, i in acc + (days[TimerStore.dayKey(cal.date(byAdding: .day, value: -i, to: today)!)] ?? 0) }
        }
        let maxV = max(1, days.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ForEach(UsageStore.Source.allCases, id: \.self) { s in
                    Chip(label: s.rawValue, selected: store.source == s) { store.source = s }
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.load(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                stat("Today", sum(1)); stat("7 days", sum(7)); stat("30 days", sum(30))
            }
            // Contribution-style grid: columns are weeks, rows are weekdays.
            let firstCol = cal.date(byAdding: .day, value: -(weeks * 7 - 1) - (cal.component(.weekday, from: today) - 1) + 6, to: today)!
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: w * 7 + d, to: firstCol)!
                            let n = days[TimerStore.dayKey(date)] ?? 0
                            let k = n == 0 ? 0 : 0.25 + 0.75 * sqrt(Double(n) / Double(maxV))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(date > today ? Color.clear
                                      : (n == 0 ? Color.white.opacity(0.06) : Theme.glow[1].opacity(k)))
                                .frame(width: 20, height: 20)
                                .help("\(TimerStore.dayKey(date)): \(compactNumber(n)) tokens")
                        }
                    }
                }
            }
            Text(store.source == .claude ? "Includes cache reads and writes, from ~/.claude/projects."
                 : store.source == .codex ? "From ~/.codex/sessions token_count events."
                 : "From OpenNotch's own traces (Application Support/OpenNotch/traces).")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .padding(18)
        .onAppear { store.load() }
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(compactNumber(n)).font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }
}
