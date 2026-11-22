import AppKit
import SwiftUI

// The closed notch while the AI works: Puff acts out each kind of work in the left ear and the right ear says what's
// happening in a few friendly words. Thinking → hand to chin + thought bubble; searching → peering with a magnifier
// that sweeps; the web → a spinning globe; reading → eyes running along the lines of a page; writing a file → a
// scribbling pencil; mail → envelopes flying in; calendar → a flipping calendar; weather → a drifting sun; commands →
// a blinking terminal; music → a dance with floating notes; memory → a glowing brain; writing the answer → a pencil;
// when it's done → a wave and a confetti pop; when it fails → a little rain cloud.
// Puff is cached frames on a CALayer (PerchSprites, like the perch) and every prop moves with Core Animation, so
// nothing redraws SwiftUI per frame (rule 7); the words change at most every 3 s.

/// The rules, pure (checked by `--checks`).
enum WorkingLogic {
    enum Activity: Equatable { case thinking, tool(String) }

    /// What Puff acts out.
    enum Scene: String, Equatable, CaseIterable {
        case thinking, answering, search, web, read, write, mail, calendar, weather, command, music, memory, people,
             photos, tool, done, snag
    }

    /// How the prop moves (Core Animation).
    enum Motion: Equatable { case bubble, scan, spin, page, scribble, flyIn, flip, drift, blink, notes, glow, bob, flash,
                             wobble, confetti, rain }

    struct Look: Equatable {
        let clip: String          // PerchSprites clip
        let symbol: String?       // SF Symbol prop (nil = the thought bubble / confetti)
        let motion: Motion
        let tint: NSColor
    }

    static func activity(lastTool: String) -> Activity {
        let t = lastTool.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? .thinking : .tool(t)
    }

    /// The scene for this moment. `answering` = answer text is streaming; `finale` = a turn just ended.
    static func scene(lastTool: String, answering: Bool, finale: Finale?) -> Scene {
        if let finale { return finale == .done ? .done : .snag }
        guard case .tool(let verb) = activity(lastTool: lastTool) else { return answering ? .answering : .thinking }
        let v = verb.lowercased()
        let table: [([String], Scene)] = [        // specific words first
            (["weather", "forecast"], .weather),
            (["calendar", "event", "remind", "schedul", "invite", "meeting"], .calendar),
            (["mail", "draft", "inbox"], .mail),
            (["contact", "person"], .people),
            (["photo", "image", "screen", "capture"], .photos),
            (["music", "playing", "song"], .music),
            (["remember", "memor", "recall"], .memory),
            (["brows", "web", "http", "fetch", "page", "url"], .web),
            (["search", "find", "spotlight", "grep", "look"], .search),
            (["writ", "edit", "replac", "sav", "creat", "note"], .write),
            (["read", "pdf", "document", "list", "explor", "open"], .read),
            (["run", "exec", "command", "git", "test", "python", "script", "build"], .command),
        ]
        return table.first { $0.0.contains(where: v.contains) }?.1 ?? .tool
    }

    static func look(_ s: Scene, verb: String = "") -> Look {
        let blue = NSColor(red: 0.62, green: 0.85, blue: 1, alpha: 1)
        switch s {
        case .thinking: return Look(clip: "think", symbol: nil, motion: .bubble, tint: .white)
        case .answering: return Look(clip: "busy", symbol: "pencil.line", motion: .scribble, tint: NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1))
        case .search: return Look(clip: "search", symbol: "magnifyingglass", motion: .scan, tint: blue)
        case .web: return Look(clip: "search", symbol: "globe.americas.fill", motion: .spin, tint: NSColor(red: 0.45, green: 0.8, blue: 1, alpha: 1))
        case .read: return Look(clip: "read", symbol: "book.pages.fill", motion: .page, tint: NSColor(red: 0.95, green: 0.8, blue: 0.6, alpha: 1))
        case .write: return Look(clip: "busy", symbol: "pencil", motion: .scribble, tint: NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1))
        case .mail: return Look(clip: "busy", symbol: "envelope.fill", motion: .flyIn, tint: NSColor(red: 0.6, green: 0.8, blue: 1, alpha: 1))
        case .calendar: return Look(clip: "read", symbol: "calendar", motion: .flip, tint: NSColor(red: 1, green: 0.5, blue: 0.5, alpha: 1))
        case .weather: return Look(clip: "think", symbol: "sun.max.fill", motion: .drift, tint: NSColor(red: 1, green: 0.82, blue: 0.3, alpha: 1))
        case .command: return Look(clip: "busy", symbol: "apple.terminal.fill", motion: .blink, tint: NSColor(red: 0.5, green: 1, blue: 0.6, alpha: 1))
        case .music: return Look(clip: "dance", symbol: "music.note", motion: .notes, tint: NSColor(red: 1, green: 0.55, blue: 0.8, alpha: 1))
        case .memory: return Look(clip: "think", symbol: "brain.head.profile.fill", motion: .glow, tint: NSColor(red: 0.85, green: 0.7, blue: 1, alpha: 1))
        case .people: return Look(clip: "read", symbol: "person.crop.circle.fill", motion: .bob, tint: blue)
        case .photos: return Look(clip: "search", symbol: "camera.fill", motion: .flash, tint: .white)
        case .tool: return Look(clip: "busy", symbol: toolSymbol(verb), motion: .wobble, tint: blue)
        case .done: return Look(clip: "wave", symbol: nil, motion: .confetti, tint: .white)
        case .snag: return Look(clip: "idle", symbol: "cloud.drizzle.fill", motion: .rain, tint: NSColor(red: 0.7, green: 0.78, blue: 0.9, alpha: 1))
        }
    }

    static let thinkingLines = ["Thinking…", "Pondering…", "Connecting dots…", "Brewing an idea…", "Mulling it over…"]
    static let slowLines = ["Still on it…", "Nearly there…", "Bear with me…"]
    static let answeringLines = ["Writing it up…", "Putting it together…"]

    /// The right ear: a tool's verb (short), else a line that changes every 3 s (slow ones after 20 s).
    /// A plan adds its step: "2/5 · Checking calendar".
    static func line(lastTool: String, step: (done: Int, total: Int)?, elapsed: TimeInterval,
                     answering: Bool = false, finale: Finale? = nil) -> String {
        if let finale { return finale == .done ? "All done! ✨" : "Hit a snag" }
        let beat = max(0, Int(elapsed / 3))
        var text: String
        switch activity(lastTool: lastTool) {
        case .tool(let verb): text = short(verb)
        case .thinking where answering: text = answeringLines[beat % answeringLines.count]
        case .thinking:
            text = elapsed >= 20 ? slowLines[beat % slowLines.count] : thinkingLines[beat % thinkingLines.count]
        }
        if let s = step, s.total > 1 { text = "\(min(s.total, s.done + 1))/\(s.total) · " + text }
        return text
    }

    /// "Checking your calendar for tomorrow…" → "Checking calendar…": filler words go only when it's too long.
    static func short(_ verb: String, max: Int = 18) -> String {
        var v = verb.trimmingCharacters(in: CharacterSet(charactersIn: "… .")).trimmingCharacters(in: .whitespaces)
        if v.count > max {
            for filler in [" your ", " the ", " a ", " an ", " my "] {
                v = v.replacingOccurrences(of: filler, with: " ", options: .caseInsensitive)
            }
        }
        return v.count <= max ? v : String(v.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The streamed answer counts as "being written" for this long after the last chunk.
    static func answering(lastTextAt: Date?, now: Date) -> Bool {
        lastTextAt.map { now.timeIntervalSince($0) < 0.8 } ?? false
    }
}

/// How a turn ended, shown for a moment in the closed notch.
enum Finale: Equatable { case done, snag }

/// Left ear: Puff working.
struct WorkingPuff: NSViewRepresentable {
    let backend: Backend
    let finale: Finale?
    func makeNSView(context: Context) -> WorkingPuffView { WorkingPuffView(backend: backend) }
    func updateNSView(_ v: WorkingPuffView, context: Context) { v.finale = finale }
}

/// Right ear: what's happening, in a few words.
struct WorkingStatus: View {
    @ObservedObject var backend: Backend
    let finale: Finale?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = backend.turnStarted.map { ctx.date.timeIntervalSince($0) } ?? 0
            let text = WorkingLogic.line(lastTool: backend.lastTool, step: backend.planProgress, elapsed: elapsed,
                                         answering: WorkingLogic.answering(lastTextAt: backend.lastTextAt, now: ctx.date),
                                         finale: finale)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(finale == .done ? Color(red: 0.6, green: 1, blue: 0.7) : .white.opacity(0.82))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .id(text)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .animation(.easeOut(duration: 0.3), value: text)
        }
    }
}

@MainActor
final class WorkingPuffView: NSView {
    private let backend: Backend
    var finale: Finale?
    private let sprites = PerchSprites()
    private let puff = CALayer()
    private let prop = CALayer()
    private let extras = (0..<3).map { _ in CALayer() }     // bubble dots, notes, raindrops
    private let confetti = CAEmitterLayer()
    private var timer: Timer?
    private var shown: WorkingLogic.Scene?
    private var shownVerb = ""
    private var finaleStart = Date.distantPast
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(backend: Backend) {
        self.backend = backend
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        puff.contentsGravity = .resizeAspect
        puff.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(puff)
        prop.contentsGravity = .resizeAspect
        layer?.addSublayer(prop)
        extras.forEach { $0.contentsGravity = .resizeAspect; layer?.addSublayer($0) }
        confetti.emitterShape = .point
        confetti.birthRate = 0
        confetti.emitterCells = Self.confettiCells()
        layer?.addSublayer(confetti)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1 / PerchSprites.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
        DispatchQueue.main.async { [weak self] in self?.entrance() }
    }

    /// Puff hops out from behind the notch (the ear's inner edge) and lands with a squash.
    private func entrance() {
        guard !reduceMotion, bounds.width > 10 else { return }
        let from = bounds.width * 0.6 + 8                           // behind the notch, to the right
        let t0 = CACurrentMediaTime()
        func kf(_ path: String, _ v: [Any], _ times: [NSNumber], _ d: Double) {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = v; a.keyTimes = times; a.duration = d; a.beginTime = t0
            a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: max(1, v.count - 1))
            a.isAdditive = true
            puff.add(a, forKey: "enter-" + path)
        }
        kf("transform.translation.x", [from, from * 0.35, 0, 0], [0, 0.45, 0.7, 1], 0.7)
        kf("transform.translation.y", [-6, 14, 0, 0], [0, 0.45, 0.7, 1], 0.7)
        kf("transform.scale.y", [0, 0.06, -0.2, 0.08, 0], [0, 0.6, 0.72, 0.86, 1], 0.7)
        kf("transform.scale.x", [0, -0.04, 0.18, -0.05, 0], [0, 0.6, 0.72, 0.86, 1], 0.7)
        kf("opacity", [-1, 0, 0, 0], [0, 0.25, 0.7, 1], 0.7)
        prop.opacity = 1
    }

    /// The cinematic close-up when the work is done: Puff dips out of the notch, grows, holds a beat, tucks back.
    private func closeUp() {
        guard !reduceMotion else { return }
        let t0 = CACurrentMediaTime()
        let times: [NSNumber] = [0, 0.18, 0.78, 1]
        func kf(_ path: String, _ v: [Any]) {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = v; a.keyTimes = times; a.duration = 1.7; a.beginTime = t0
            a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 1.4, 0.4, 1),     // overshoot in
                                 CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(name: .easeIn)]
            a.isAdditive = true
            puff.add(a, forKey: "closeup-" + path)
        }
        kf("transform.scale.x", [0, 0.6, 0.6, 0])
        kf("transform.scale.y", [0, 0.6, 0.6, 0])
        kf("transform.translation.y", [0, -24, -24, 0])                 // down, below the notch's edge
        kf("transform.translation.x", [0, 10, 10, 0])                   // towards the middle
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        if s != sprites.scale { sprites.scale = s; sprites.clear() }
        ([puff, prop] + extras).forEach { $0.contentsScale = s }
    }

    private func tick() {
        guard bounds.width > 10 else { return }
        let now = Date()
        let clock = now.timeIntervalSinceReferenceDate
        let size = min(bounds.height - 4, 32)
        let scene = WorkingLogic.scene(lastTool: backend.lastTool,
                                       answering: WorkingLogic.answering(lastTextAt: backend.lastTextAt, now: now), finale: finale)
        let verb = backend.lastTool
        let look = WorkingLogic.look(scene, verb: verb)

        var key = PerchSprites.Key(clip: look.clip, frame: 0, gazeX: 0, blink: false,
                                   mood: scene == .done ? .happy : scene == .snag ? .sad : scene == .thinking ? .thinking : .working,
                                   expression: nil, palette: UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora")
        let n = PerchSprites.frames(look.clip)
        if look.clip == "wave" {                                   // plays once, then holds
            key.frame = min(n - 1, Int(now.timeIntervalSince(finaleStart) * PerchSprites.fps))
        } else if !reduceMotion {
            key.frame = Int(clock * PerchSprites.fps) % n
        }

        let cx = bounds.width * 0.4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let img = sprites.image(key, size: size) { puff.contents = img }
        puff.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        puff.position = CGPoint(x: cx, y: 1 + (reduceMotion ? 0 : bob(look.clip, frame: key.frame) * size))
        prop.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        CATransaction.commit()

        if scene != shown || (scene == .tool && verb != shownVerb) {
            if scene == .done || scene == .snag, shown != .done, shown != .snag {
                finaleStart = now
                if scene == .done { closeUp() }
            }
            shown = scene
            shownVerb = verb
            stage(scene, look: look, cx: cx, size: size)
        }
    }

    private func bob(_ clip: String, frame: Int) -> CGFloat {
        let t = Double(frame) / PerchSprites.fps
        switch clip {
        case "think": return PerchPose.thinking(t: t).bob
        case "busy": return PerchPose.busy(t: 1000 + t).bob
        case "read": return PerchPose.reading(t: t).bob
        case "search": return PerchPose.searching(t: t).bob
        case "dance": return PerchPose.dance(t: 1000 + t).bob
        default: return 0
        }
    }

    /// Set up the prop for a scene: where it sits and how it moves. Core Animation runs it off the main thread.
    private func stage(_ scene: WorkingLogic.Scene, look: WorkingLogic.Look, cx: CGFloat, size: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ([prop] + extras).forEach { $0.removeAllAnimations(); $0.isHidden = true; $0.opacity = 1; $0.transform = CATransform3DIdentity }
        let hand = CGPoint(x: cx + size * 0.55, y: size * 0.34)          // by Puff's right hand
        let head = CGPoint(x: cx + size * 0.32, y: size * 0.8)           // up and to the right of Puff's head
        if let sym = look.symbol {
            prop.contents = Self.symbol(sym, tint: look.tint)
            prop.isHidden = false
            prop.position = scene == .snag ? CGPoint(x: cx + 2, y: size * 0.98)
                : [.weather, .memory].contains(scene) ? head : hand
        }
        CATransaction.commit()
        let reduce = reduceMotion
        func anim(_ layer: CALayer, _ key: String, _ a: CAAnimation) { if !reduce { layer.add(a, forKey: key) } }
        if look.symbol != nil && scene != .snag {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.2; pop.toValue = 1; pop.damping = 9; pop.initialVelocity = 6
            pop.duration = pop.settlingDuration
            anim(prop, "pop", pop)
        }

        switch look.motion {
        case .bubble:
            for (i, d) in extras.enumerated() {
                let r = CGFloat(2.2 + Double(i) * 0.9)
                d.contents = nil
                d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
                d.cornerRadius = r
                d.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
                d.position = CGPoint(x: head.x + CGFloat(i) * 5.5, y: head.y + CGFloat(i) * 3.2)
                d.isHidden = false
                d.opacity = reduce ? 0.8 : 0.15
                let a = keyframes("opacity", [0.15, 1, 0.15], 1.2, delay: Double(i) * 0.2)
                anim(d, "pulse", a)
                anim(d, "pop", keyframes("transform.scale", [0.8, 1.15, 0.8], 1.2, delay: Double(i) * 0.2))
            }
        case .scan:                         // the magnifier sweeps, in step with Puff's eyes (3 s)
            anim(prop, "scan", keyframes("position.x", [hand.x - 9, hand.x + 6, hand.x - 9], 3, timing: .easeInEaseOut))
            anim(prop, "tilt", keyframes("transform.rotation.z", [0.25, -0.25, 0.25], 3))
        case .spin:
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = 4; a.repeatCount = .infinity
            anim(prop, "spin", a)
            anim(prop, "bob", bobAnim(2, 1.1))
        case .page:                         // a page turning: squash on x, now and then
            anim(prop, "page", keyframes("transform.scale.x", [1, 1, -0.2, 1, 1], 2.4, keyTimes: [0, 0.6, 0.72, 0.84, 1]))
        case .scribble:                     // little loops, like writing
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: hand.x - 3, y: hand.y - 2, width: 6, height: 4))
            let a = CAKeyframeAnimation(keyPath: "position")
            a.path = path; a.duration = 0.45; a.repeatCount = .infinity; a.calculationMode = .paced
            anim(prop, "scribble", a)
            anim(prop, "tilt", keyframes("transform.rotation.z", [-0.3, 0.1, -0.3], 0.45))
        case .flyIn:                        // an envelope glides in from the notch side and lands in Puff's hands
            anim(prop, "fly", keyframes("position.x", [hand.x + 26, hand.x, hand.x], 1.8, keyTimes: [0, 0.4, 1],
                                        timing: .easeOut))
            anim(prop, "fade", keyframes("opacity", [0, 1, 1, 0], 1.8, keyTimes: [0, 0.25, 0.85, 1]))
            anim(prop, "arc", keyframes("position.y", [hand.y + 7, hand.y, hand.y], 1.8, keyTimes: [0, 0.4, 1]))
        case .flip:
            anim(prop, "flip", keyframes("transform.scale.y", [1, 1, 0.1, 1], 1.6, keyTimes: [0, 0.7, 0.82, 1]))
            anim(prop, "bob", bobAnim(1.5, 0.8))
        case .drift:
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = 2 * Double.pi; a.duration = 8; a.repeatCount = .infinity
            anim(prop, "spin", a)
            anim(prop, "drift", keyframes("position.x", [head.x, head.x + 4, head.x], 3, timing: .easeInEaseOut))
        case .blink:
            anim(prop, "blink", keyframes("opacity", [1, 1, 0.35, 1], 0.9, keyTimes: [0, 0.5, 0.6, 1]))
            anim(prop, "bob", bobAnim(1.2, 0.3))
        case .notes:
            prop.isHidden = true
            for (i, d) in extras.enumerated() {
                d.contents = Self.symbol(i == 1 ? "music.note.list" : "music.note", tint: look.tint)
                d.backgroundColor = nil; d.cornerRadius = 0
                d.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
                d.position = CGPoint(x: head.x + CGFloat(i) * 6 - 2, y: size * 0.55)
                d.isHidden = false
                d.opacity = reduce ? 0.9 : 0
                anim(d, "rise", keyframes("position.y", [size * 0.5, size * 1.05], 1.8, delay: Double(i) * 0.6))
                anim(d, "fade", keyframes("opacity", [0, 1, 0], 1.8, delay: Double(i) * 0.6))
                anim(d, "sway", keyframes("position.x", [d.position.x, d.position.x + 3, d.position.x], 0.9, delay: Double(i) * 0.6))
            }
        case .glow:
            anim(prop, "glow", keyframes("transform.scale", [0.85, 1.2, 0.85], 1.4, timing: .easeInEaseOut))
            anim(prop, "shine", keyframes("opacity", [0.55, 1, 0.55], 1.4))
        case .bob:
            anim(prop, "bob", bobAnim(2.5, 0.7))
        case .flash:
            anim(prop, "flash", keyframes("opacity", [1, 1, 0.2, 1, 1], 1.5, keyTimes: [0, 0.55, 0.6, 0.7, 1]))
            anim(prop, "click", keyframes("transform.scale", [1, 1, 1.25, 1, 1], 1.5, keyTimes: [0, 0.55, 0.6, 0.7, 1]))
        case .wobble:
            let w = CABasicAnimation(keyPath: "transform.rotation.z")
            w.fromValue = -0.22; w.toValue = 0.22; w.duration = 0.55; w.autoreverses = true; w.repeatCount = .infinity
            w.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim(prop, "wobble", w)
            anim(prop, "bob", bobAnim(2.5, 0.8))
        case .confetti:
            guard !reduce else { return }
            confetti.emitterPosition = CGPoint(x: cx, y: size * 0.9)
            confetti.beginTime = CACurrentMediaTime()
            confetti.birthRate = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.confetti.birthRate = 0 }
        case .rain:                         // a little cloud over Puff with drops falling
            anim(prop, "drift", keyframes("position.x", [cx - 2, cx + 3, cx - 2], 2.4, timing: .easeInEaseOut))
            for (i, d) in extras.enumerated() {
                d.contents = nil
                d.bounds = CGRect(x: 0, y: 0, width: 1.6, height: 4)
                d.cornerRadius = 0.8
                d.backgroundColor = NSColor(red: 0.6, green: 0.8, blue: 1, alpha: 0.9).cgColor
                d.position = CGPoint(x: cx - 4 + CGFloat(i) * 4, y: size * 0.85)
                d.isHidden = false
                d.opacity = reduce ? 0.7 : 0
                anim(d, "fall", keyframes("position.y", [size * 0.85, size * 0.55], 0.7, delay: Double(i) * 0.23))
                anim(d, "fade", keyframes("opacity", [0, 0.9, 0], 0.7, delay: Double(i) * 0.23))
            }
        }
    }

    private func keyframes(_ path: String, _ values: [Any], _ duration: Double, keyTimes: [NSNumber]? = nil,
                           delay: Double = 0, timing: CAMediaTimingFunctionName? = nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        a.keyTimes = keyTimes
        a.duration = duration
        a.repeatCount = .infinity
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
        if let timing { a.timingFunction = CAMediaTimingFunction(name: timing) }
        return a
    }

    private func bobAnim(_ by: CGFloat, _ duration: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "position.y")
        a.byValue = by; a.duration = duration; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isAdditive = true
        return a
    }

    private static var symbolCache: [String: CGImage] = [:]
    private static func symbol(_ name: String, tint: NSColor) -> CGImage? {
        let cacheKey = name + tint.description
        if let hit = symbolCache[cacheKey] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [tint]))
        guard let img = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil))?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: 26, height: 26))
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: 2)])
        symbolCache[cacheKey] = cg
        return cg
    }

    /// Small coloured bits for the "done" pop.
    private static func confettiCells() -> [CAEmitterCell] {
        let colors: [NSColor] = [.systemPink, .systemYellow, .systemTeal, .systemPurple, .systemGreen, .systemOrange]
        return colors.enumerated().map { i, c in
            let cell = CAEmitterCell()
            let img = NSImage(size: NSSize(width: 4, height: i % 2 == 0 ? 4 : 2.4), flipped: false) { r in
                c.setFill()
                (i % 2 == 0 ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)).fill()
                return true
            }
            cell.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            cell.birthRate = 40
            cell.lifetime = 0.9
            cell.velocity = 55
            cell.velocityRange = 20
            cell.emissionLongitude = .pi / 2          // up (layer y is up)
            cell.emissionRange = .pi / 1.6
            cell.yAcceleration = -140                 // falls back down
            cell.spin = 4; cell.spinRange = 6
            cell.scale = 1; cell.scaleRange = 0.4
            cell.alphaSpeed = -1.0
            return cell
        }
    }
}
