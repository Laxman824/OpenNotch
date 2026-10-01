import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct Capture: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var transcript: String?
    var date = Date()
    var annotated = false
}

/// Screenshots + voice annotations.
///
///   ⌃⌥ (tap, nothing else)  → clean full-display screenshot, saved at once
///   hold ⌥ (alone, 0.35s)   → draw over the screen and talk; release to capture
///   ⌃⌥S / ⌃⌥A               → the same two, as ordinary hotkeys
///
/// The modifier-only gestures need Accessibility permission (macOS only lets
/// trusted apps watch modifier keys globally); the hotkeys work without it.
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var captures: [Capture] = []
    @Published var editing: Capture?
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var annotating = false

    var onCaptured: ((Capture) -> Void)?
    weak var clipboard: ClipboardStore?
    weak var panel: NSWindow?

    private let indexPath = opennotchDir("captures") + "/index.json"
    private var hotkeys: [HotKey] = []
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var chordArmed = false
    private var optionDown: Date?
    private var optionTimer: Timer?
    private var overlay: AnnotationOverlay?

    init() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
           let saved = try? JSONDecoder().decode([Capture].self, from: data) {
            captures = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    var hotKeysFailed: [String] { hotkeys.filter { !$0.registered }.map(\.name) }

    func install() {
        hotkeys = [
            HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), id: 2, name: "⌃⌥S") { [weak self] in
                Task { @MainActor in await self?.screenshot() }
            },
            HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), id: 3, name: "⌃⌥A") { [weak self] in
                Task { @MainActor in self?.toggleAnnotation() }
            },
        ]
        installGestures()
    }

    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        // The user flips the switch in Settings; pick it up when they come back.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted() { self.trusted = true; self.installGestures(); t.invalidate() }
            }
        }
    }

    private func installGestures() {
        guard AXIsProcessTrusted(), flagsMonitor == nil else { return }
        trusted = true
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor in self?.flags(e.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                self.chordArmed = false                               // a real shortcut, not our gesture
                if e.type == .keyDown { self.cancelOptionHold() }
            }
        }
    }

    private func flags(_ f: NSEvent.ModifierFlags) {
        let relevant = f.intersection([.control, .option, .command, .shift])
        if relevant == [.control, .option] {
            chordArmed = true
            cancelOptionHold()
        } else if relevant.isEmpty {
            if chordArmed { chordArmed = false; Task { await screenshot() } }
            if annotating && overlay?.holdMode == true { finishAnnotation() }
            cancelOptionHold()
        } else if relevant == [.option] {
            if !annotating {
                optionDown = Date()
                optionTimer?.invalidate()
                optionTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.optionDown != nil else { return }
                        self.startAnnotation(hold: true)
                    }
                }
            }
        } else {
            chordArmed = false
            cancelOptionHold()
        }
    }

    private func cancelOptionHold() {
        optionDown = nil
        optionTimer?.invalidate()
    }

    // MARK: screenshot

    func screenshot() async {
        guard let path = await ScreenGrab.capture(hiding: panel ?? NSWindow()) else {
            onCaptured?(Capture(path: "", transcript: "Screen capture failed — allow OpenNotch in System Settings › Privacy › Screen Recording."))
            return
        }
        NSSound(named: "Grab")?.play()
        add(Capture(path: path))
    }

    private func add(_ c: Capture) {
        captures.insert(c, at: 0)
        save()
        clipboard?.addImage(path: c.path)
        onCaptured?(c)
    }

    func delete(_ c: Capture) {
        try? FileManager.default.removeItem(atPath: c.path)
        captures.removeAll { $0.id == c.id }
        save()
    }

    func replace(_ c: Capture, with image: NSImage) -> Capture? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let path = c.path.replacingOccurrences(of: ".png", with: "") + "-edited.png"
        try? png.write(to: URL(fileURLWithPath: path))
        var n = c
        n.id = UUID()
        n.path = path
        n.date = Date()
        captures.insert(n, at: 0)
        save()
        clipboard?.addImage(path: path)
        return n
    }

    private func save() {
        if let data = try? JSONEncoder().encode(captures) { try? data.write(to: URL(fileURLWithPath: indexPath)) }
    }

    // MARK: voice annotation

    func toggleAnnotation() { annotating ? finishAnnotation() : startAnnotation(hold: false) }

    private func startAnnotation(hold: Bool) {
        guard !annotating else { return }
        annotating = true
        let o = AnnotationOverlay(holdMode: hold)
        o.show()
        overlay = o
    }

    private func finishAnnotation() {
        guard annotating, let o = overlay else { return }
        annotating = false
        overlay = nil
        o.finish { [weak self] path, transcript in
            guard let self, let path else { return }
            self.add(Capture(path: path, transcript: transcript, annotated: true))
        }
    }
}

// MARK: - Annotation overlay

/// A clear window over the whole screen: drag to draw, talk to annotate.
@MainActor
final class AnnotationOverlay {
    let holdMode: Bool
    private var window: NSWindow?
    private let model = AnnotationModel()
    private let dictation = Dictation()

    init(holdMode: Bool) { self.holdMode = holdMode }

    func show() {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: AnnotationCanvas(model: model, dictation: dictation, holdMode: holdMode))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        dictation.start()
    }

    func finish(_ done: @escaping (String?, String?) -> Void) {
        model.capturing = true                                   // hide the hint pill, keep the ink
        dictation.onFinish = { [weak self] t in self?.model.transcript = t }
        dictation.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let dir = opennotchDir("captures")
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let path = "\(dir)/annotated-\(f.string(from: Date())).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-m", path]
            try? p.run()
            p.waitUntilExit()
            self.window?.orderOut(nil)
            self.window = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {   // let a final transcript land
                let text = (self.model.transcript.isEmpty ? self.dictation.transcript : self.model.transcript)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    try? text.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"),
                                    atomically: true, encoding: .utf8)
                }
                done(FileManager.default.fileExists(atPath: path) ? path : nil, text.isEmpty ? nil : text)
            }
        }
    }
}

@MainActor
final class AnnotationModel: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    @Published var current: [CGPoint] = []
    @Published var capturing = false
    @Published var transcript = ""
}

struct AnnotationCanvas: View {
    @ObservedObject var model: AnnotationModel
    @ObservedObject var dictation: Dictation
    let holdMode: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(model.capturing ? 0 : 0.06)
            Canvas { ctx, _ in
                for s in model.strokes + [model.current] where s.count > 1 {
                    var p = Path()
                    p.addLines(s)
                    ctx.stroke(p, with: .color(Color(red: 1, green: 0.25, blue: 0.4)),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { model.current.append($0.location) }
                .onEnded { _ in model.strokes.append(model.current); model.current = [] })
            if !model.capturing {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: dictation.listening)
                        .foregroundStyle(.red)
                    Text(dictation.transcript.isEmpty
                         ? (holdMode ? "Draw and talk · release ⌥ to capture" : "Draw and talk · ⌃⌥A to capture")
                         : dictation.transcript)
                        .lineLimit(2)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.8)))
                .padding(.top, 60)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Captures module + editor

struct CapturesView: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var backend: Backend
    @ObservedObject var hub: Hub

    var body: some View {
        if let c = store.editing {
            CaptureEditor(capture: c, store: store, backend: backend, hub: hub)
        } else {
            VStack(spacing: 0) {
                ModuleHeader(title: "Captures", subtitle: store.trusted
                             ? "Tap ⌃⌥ for a screenshot · hold ⌥ to draw and talk"
                             : "⌃⌥S screenshot · ⌃⌥A draw and talk") {
                    PillButton(label: "Screenshot", icon: "camera") { Task { await store.screenshot() } }
                }
                if !store.trusted {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised").foregroundStyle(.yellow)
                        Text("Allow Accessibility to use the tap-⌃⌥ and hold-⌥ gestures.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Allow") { store.requestTrust() }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.glow[0])
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.07)))
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }
                if store.captures.isEmpty {
                    EmptyHint(icon: "camera.viewfinder", text: "No captures yet.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(store.captures) { c in tile(c) }
                        }
                        .padding(14)
                    }
                }
            }
        }
    }

    private func tile(_ c: Capture) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let img = NSImage(contentsOfFile: c.path) {
                Image(nsImage: img).resizable().aspectRatio(16 / 10, contentMode: .fill)
                    .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if c.annotated {
                            Image(systemName: "pencil.tip.crop.circle.fill").foregroundStyle(.pink).padding(5)
                        }
                    }
            }
            Text(c.transcript ?? relativeTime(c.date)).font(.system(size: 10.5)).lineLimit(2)
                .foregroundStyle(c.transcript == nil ? Theme.tertiary : .white.opacity(0.85))
        }
        .onTapGesture { store.editing = c }
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: c.path)) ?? NSItemProvider() }
        .contextMenu {
            Button("Edit") { store.editing = c }
            Button("Ask Ledge about this") { ask(c) }
            Button("Copy image") { if let i = NSImage(contentsOfFile: c.path) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) }
            Divider()
            Button("Delete") { store.delete(c) }
        }
    }

    private func ask(_ c: Capture) {
        backend.attach(Attachment(kind: .screenshot, value: c.path))
        backend.send(c.transcript.map { "I annotated this screenshot and said: “\($0)”. Help me with it." }
                     ?? "Take a look at this screenshot and tell me what matters.")
        hub.module = .chat
    }
}

/// Crop, blur a region, or frame the shot — then save, copy or hand to Ledge.
struct CaptureEditor: View {
    let capture: Capture
    @ObservedObject var store: CaptureStore
    @ObservedObject var backend: Backend
    @ObservedObject var hub: Hub

    enum Tool: String, CaseIterable { case crop = "Crop", blur = "Blur", frame = "Frame" }
    @State private var tool: Tool = .crop
    @State private var image: NSImage?
    @State private var selection: CGRect?
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { store.editing = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                ForEach(Tool.allCases, id: \.self) { t in
                    Chip(label: t.rawValue, icon: t == .crop ? "crop" : (t == .blur ? "eye.slash" : "square.on.square"),
                         selected: tool == t) {
                        tool = t
                        selection = nil
                        if t == .frame, let img = image { image = framed(img) }
                    }
                }
                Spacer()
                if selection != nil && tool != .frame {
                    PillButton(label: "Apply", icon: "checkmark") { apply() }
                }
                PillButton(label: "Save", icon: "square.and.arrow.down", primary: true) {
                    if let img = image, let n = store.replace(capture, with: img) { store.editing = n }
                }
            }
            .padding(.horizontal, 14).padding(.top, 8)
            GeometryReader { g in
                if let img = image {
                    let fit = fitRect(img.size, in: g.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height)
                            .position(x: fit.midX, y: fit.midY)
                        if let s = selection {
                            Rectangle().path(in: s)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            Rectangle().path(in: s).fill(Color.white.opacity(0.08))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            guard tool != .frame else { return }
                            let a = dragStart ?? v.startLocation
                            dragStart = a
                            selection = CGRect(x: min(a.x, v.location.x), y: min(a.y, v.location.y),
                                               width: abs(v.location.x - a.x), height: abs(v.location.y - a.y))
                                .intersection(fit)
                        }
                        .onEnded { _ in dragStart = nil })
                    .onAppear { canvas = fit }
                    .onChange(of: g.size) { _ in canvas = fitRect(img.size, in: g.size) }
                }
            }
            .padding(.horizontal, 14)
            HStack {
                Text(capture.transcript.map { "🎙 \($0)" } ?? "Drag to select · \(tool == .blur ? "blurs the area" : tool == .crop ? "crops to it" : "adds a backdrop")")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                Button("Copy") { if let i = image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]) } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Button("Ask Ledge") {
                    if let img = image, let n = store.replace(capture, with: img) {
                        backend.attach(Attachment(kind: .screenshot, value: n.path))
                        backend.send(capture.transcript.map { "I annotated this and said: “\($0)”. Help me with it." }
                                     ?? "Take a look at this screenshot.")
                        store.editing = nil
                        hub.module = .chat
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.glow[0])
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { image = NSImage(contentsOfFile: capture.path) }
    }

    @State private var canvas: CGRect = .zero

    private func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Selection (view coords) → image pixel rect (CoreGraphics, origin top-left).
    private func pixelRect(_ sel: CGRect, _ cg: CGImage) -> CGRect {
        let sx = CGFloat(cg.width) / canvas.width, sy = CGFloat(cg.height) / canvas.height
        return CGRect(x: (sel.minX - canvas.minX) * sx, y: (sel.minY - canvas.minY) * sy,
                      width: sel.width * sx, height: sel.height * sy).integral
    }

    private func apply() {
        guard let img = image, let sel = selection,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let r = pixelRect(sel, cg)
        switch tool {
        case .crop:
            if let c = cg.cropping(to: r) { image = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)) }
        case .blur:
            let ci = CIImage(cgImage: cg)
            let flipped = CGRect(x: r.minX, y: CGFloat(cg.height) - r.maxY, width: r.width, height: r.height)
            let pix = CIFilter.pixellate()
            pix.inputImage = ci.clampedToExtent()
            pix.scale = Float(max(12, min(r.width, r.height) / 8))
            let blurred = pix.outputImage!.cropped(to: flipped)
            let out = blurred.composited(over: ci)
            if let res = CIContext().createCGImage(out, from: ci.extent) {
                image = NSImage(cgImage: res, size: NSSize(width: res.width, height: res.height))
            }
        case .frame:
            break
        }
        selection = nil
    }

    private func framed(_ img: NSImage) -> NSImage {
        let pad = max(img.size.width, img.size.height) * 0.06
        let size = NSSize(width: img.size.width + pad * 2, height: img.size.height + pad * 2)
        return NSImage(size: size, flipped: false) { rect in
            let g = NSGradient(colors: [NSColor(red: 0.36, green: 0.55, blue: 1, alpha: 1),
                                        NSColor(red: 0.69, green: 0.40, blue: 1, alpha: 1),
                                        NSColor(red: 1, green: 0.48, blue: 0.70, alpha: 1)])
            g?.draw(in: rect, angle: -35)
            let inner = rect.insetBy(dx: pad, dy: pad)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = pad * 0.5
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowOffset = NSSize(width: 0, height: -pad * 0.15)
            shadow.set()
            NSBezierPath(roundedRect: inner, xRadius: pad * 0.25, yRadius: pad * 0.25).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: inner, xRadius: pad * 0.25, yRadius: pad * 0.25).addClip()
            img.draw(in: inner)
            return true
        }
    }
}
