import AppKit
import SwiftUI

/// Ledge's face. A procedural, state-driven character drawn every frame —
/// not a video model. Meta's Muse Realtime Avatar streams diffusion video at
/// 25fps with ~870ms latency; this runs locally at display rate with zero
/// latency, and — the part a video avatar can't do — its expression is driven
/// by what the *agent* is actually doing: listening, thinking, running a tool,
/// talking, waiting on approval, done, failed, offline.
enum AvatarMood: Hashable {
    case idle, listening, thinking, working, talking, alert, happy, sad, sleeping
}

struct AvatarPalette: Identifiable, Equatable {
    let id: String
    let name: String
    let head: [Color]      // body gradient
    let eye: Color         // glowing eyes / antenna

    static let all: [AvatarPalette] = [
        AvatarPalette(id: "aurora", name: "Aurora",
                      head: [Color(red: 0.42, green: 0.55, blue: 1.0), Color(red: 0.74, green: 0.42, blue: 1.0),
                             Color(red: 1.0, green: 0.48, blue: 0.70)],
                      eye: Color(red: 0.62, green: 0.93, blue: 1.0)),
        AvatarPalette(id: "ocean", name: "Ocean",
                      head: [Color(red: 0.16, green: 0.72, blue: 0.98), Color(red: 0.20, green: 0.40, blue: 0.95)],
                      eye: Color(red: 0.75, green: 1.0, blue: 0.95)),
        AvatarPalette(id: "ember", name: "Ember",
                      head: [Color(red: 1.0, green: 0.62, blue: 0.28), Color(red: 0.95, green: 0.28, blue: 0.36)],
                      eye: Color(red: 1.0, green: 0.93, blue: 0.70)),
        AvatarPalette(id: "mint", name: "Mint",
                      head: [Color(red: 0.36, green: 0.92, blue: 0.70), Color(red: 0.10, green: 0.60, blue: 0.62)],
                      eye: Color(red: 0.85, green: 1.0, blue: 0.90)),
        AvatarPalette(id: "stark", name: "Stark",
                      head: [Color(red: 0.86, green: 0.18, blue: 0.20), Color(red: 0.98, green: 0.74, blue: 0.24)],
                      eye: Color(red: 0.60, green: 0.92, blue: 1.0)),
        AvatarPalette(id: "mono", name: "Graphite",
                      head: [Color(white: 0.78), Color(white: 0.42)],
                      eye: Color.white),
    ]

    static func named(_ id: String) -> AvatarPalette { all.first { $0.id == id } ?? all[0] }
}

/// Maps live agent state to a mood. Transient moods (happy/sad) hold briefly
/// after a turn ends, then relax to idle.
@MainActor
func currentMood(backend: Backend, listening: Bool, now: Date) -> AvatarMood {
    if !backend.connected { return .sleeping }
    if !backend.approvals.isEmpty { return .alert }
    switch backend.voicePhase {                                   // hands-free conversation
    case .speaking: return .talking
    case .listening, .hearing: return .listening
    case .standby: return .sleeping
    case .thinking, .starting: return backend.lastTool.isEmpty ? .thinking : .working
    case .off: break
    }
    if listening { return .listening }
    if backend.busy {
        if let t = backend.lastTextAt, now.timeIntervalSince(t) < 0.35 { return .talking }
        return backend.lastTool.isEmpty ? .thinking : .working
    }
    if let t = backend.lastErrorAt, now.timeIntervalSince(t) < 2.5 { return .sad }
    if let t = backend.lastDoneAt, now.timeIntervalSince(t) < 1.8 { return .happy }
    return .idle
}

struct AssistantFace: View {
    var size: CGFloat
    @ObservedObject var backend: Backend
    var tracksCursor = true
    /// Wiggle-wave when it appears (peek-a-boo).
    var greets = false
    @AppStorage("avatarPalette") private var paletteID = "aurora"
    @AppStorage("character.style") private var style = "puff"
    @Environment(\.notchContentVisible) private var visible
    @StateObject private var brain = CharacterBrain()
    @ObservedObject private var policy = AnimationPolicy.shared

    var body: some View {
        let fps: Double = policy.eco ? 20 : (size < 24 ? 30 : 60)
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !visible)) { ctx in
            let mood = currentMood(backend: backend, listening: backend.listening, now: ctx.date)
            let gaze = tracksCursor ? Self.gaze() : .zero
            if style == "robot" {
                AvatarCanvas(size: size, mood: mood, palette: AvatarPalette.named(paletteID),
                             t: ctx.date.timeIntervalSinceReferenceDate, level: backend.micLevel, gaze: gaze,
                             speech: backend.voicePhase == .speaking ? backend.speechLevel : nil)
            } else {
                let _ = brain.step(ctx.date, doneAt: backend.lastDoneAt, dragging: ToolHost.notch?.fileDrag ?? false)
                PuffCanvas(size: size, mood: mood, palette: AvatarPalette.named(paletteID),
                           t: ctx.date.timeIntervalSinceReferenceDate, gaze: gaze,
                           phys: PuffPhysics(squash: brain.squash, hop: brain.hop, sway: brain.sway,
                                             eyeBoost: brain.eyeBoost, expression: brain.current,
                                             hearts: brain.hearts.map { (ctx.date.timeIntervalSince($0.born), $0.x) }),
                           speech: backend.voicePhase == .speaking ? backend.speechLevel : nil,
                           level: backend.micLevel)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { if style != "robot" { brain.poke() } }
        .onContinuousHover { phase in
            guard style != "robot" else { return }
            switch phase {
            case .active(let p): brain.hover(true); brain.pet(x: p.x)
            case .ended: brain.hover(false)
            }
        }
        .onAppear {
            if greets { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { brain.wave() } }
        }
        .accessibilityLabel(UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge")
        .accessibilityHint("Tap to poke")
    }

    /// Where the eyes look: toward the pointer, measured from the notch (the
    /// avatar always lives near the top-centre of the screen). -1…1 per axis.
    static func gaze() -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        else { return .zero }
        let m = NSEvent.mouseLocation
        let f = screen.frame
        let dx = (m.x - f.midX) / (f.width / 2)
        let dy = (f.maxY - 120 - m.y) / (f.height / 2)
        return CGPoint(x: max(-1, min(1, dx * 1.6)), y: max(-1, min(1, dy * 1.6)))
    }
}

/// The drawing. Everything is a function of time `t` and `mood`, so there is
/// no animation state to get stuck — the face can't freeze mid-blink.
struct AvatarCanvas: View {
    let size: CGFloat
    let mood: AvatarMood
    let palette: AvatarPalette
    let t: Double
    let level: CGFloat
    let gaze: CGPoint
    var speech: CGFloat? = nil          // real TTS output level → lip-sync

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)
            let detailed = s >= 24
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)

            // ── Body motion: float + breathe, stronger when happy ──
            let bobAmp = mood == .happy ? 0.07 : (mood == .sleeping ? 0.012 : 0.03)
            let bobSpeed = mood == .happy ? 7.0 : (mood == .sleeping ? 0.9 : 1.7)
            let bob = CGFloat(sin(t * bobSpeed)) * s * bobAmp
            let breathe = 1 + CGFloat(sin(t * 1.3)) * 0.018
            let tilt: Double = mood == .listening ? 0.10 * sin(t * 1.1) + 0.06
                : mood == .sad ? -0.09
                : mood == .thinking ? 0.05 * sin(t * 0.8) : 0

            ctx.translateBy(x: c.x, y: c.y + bob)
            ctx.rotate(by: .radians(tilt))
            ctx.scaleBy(x: breathe, y: 1 / breathe)
            let headW = s * (detailed ? 0.80 : 0.94)
            let headH = headW * 0.86
            let headY = detailed ? s * 0.06 : 0
            let head = CGRect(x: -headW / 2, y: -headH / 2 + headY, width: headW, height: headH)

            let tint: [Color] = mood == .sad ? [Color.orange, Color.red.opacity(0.9)]
                : mood == .alert ? [Color.yellow, Color.orange] : palette.head
            let eyeColor = mood == .alert ? Color(red: 1, green: 0.95, blue: 0.7)
                : mood == .sad ? Color(red: 1, green: 0.85, blue: 0.7) : palette.eye

            // ── Antenna (thinks/works = pulses) ──
            if detailed {
                let stemTop = CGPoint(x: 0, y: head.minY - s * 0.13)
                var stem = Path()
                stem.move(to: CGPoint(x: 0, y: head.minY + 1))
                stem.addLine(to: stemTop)
                ctx.stroke(stem, with: .color(Color.white.opacity(0.55)), lineWidth: max(1, s * 0.025))
                let busy = mood == .thinking || mood == .working || mood == .talking
                let pulse = busy ? 0.5 + 0.5 * sin(t * 6) : 0.25
                let r = s * 0.05
                let ball = CGRect(x: -r, y: stemTop.y - r, width: r * 2, height: r * 2)
                // Glows are radial gradients, not blur filters: a blur is a
                // per-frame GPU pass, a gradient is nearly free.
                let halo = ball.insetBy(dx: -r * 1.6, dy: -r * 1.6)
                ctx.fill(Circle().path(in: halo), with: .radialGradient(
                    Gradient(colors: [eyeColor.opacity(0.8 * pulse), eyeColor.opacity(0)]),
                    center: CGPoint(x: halo.midX, y: halo.midY), startRadius: 0, endRadius: halo.width / 2))
                ctx.fill(Circle().path(in: ball), with: .color(eyeColor.opacity(0.55 + 0.45 * pulse)))
            }

            // ── Head: glossy gradient squircle ──
            let headPath = RoundedRectangle(cornerRadius: headW * 0.34, style: .continuous).path(in: head)
            let glowR = max(headW, headH) * 0.78                   // soft outer glow
            ctx.fill(Ellipse().path(in: CGRect(x: -glowR, y: head.midY - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [tint[0].opacity(mood == .sleeping ? 0.14 : 0.4), tint[0].opacity(0)]),
                                           center: CGPoint(x: 0, y: head.midY), startRadius: headW * 0.3, endRadius: glowR))
            ctx.fill(headPath, with: .linearGradient(Gradient(colors: tint),
                                                     startPoint: CGPoint(x: head.minX, y: head.minY),
                                                     endPoint: CGPoint(x: head.maxX, y: head.maxY)))
            // top-left highlight
            let hl = CGRect(x: head.minX + headW * 0.14, y: head.minY + headH * 0.06,
                            width: headW * 0.36, height: headH * 0.16)
            ctx.fill(Ellipse().path(in: hl), with: .color(.white.opacity(0.28)))

            // ── Visor ──
            let vW = headW * 0.80, vH = headH * 0.52
            let visor = CGRect(x: -vW / 2, y: head.midY - vH / 2 + headH * 0.05, width: vW, height: vH)
            let visorPath = RoundedRectangle(cornerRadius: vH * 0.42, style: .continuous).path(in: visor)
            ctx.fill(visorPath, with: .color(Color(white: 0.04).opacity(0.94)))
            if mood == .listening {
                let w = max(1, s * (0.02 + 0.05 * level))
                ctx.stroke(visorPath, with: .color(eyeColor.opacity(0.4 + 0.6 * Double(level))), lineWidth: w)
            } else {
                ctx.stroke(visorPath, with: .color(.white.opacity(0.10)), lineWidth: max(0.5, s * 0.012))
            }

            // Working: a scan line sweeping across the visor.
            if mood == .working && detailed {
                let x = visor.minX + visor.width * CGFloat((sin(t * 3.2) + 1) / 2)
                ctx.drawLayer { l in
                    l.clip(to: visorPath)
                    let band = CGRect(x: x - s * 0.05, y: visor.minY, width: s * 0.1, height: visor.height)
                    l.fill(Path(band), with: .linearGradient(
                        Gradient(colors: [eyeColor.opacity(0), eyeColor.opacity(0.4), eyeColor.opacity(0)]),
                        startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)))
                }
            }

            // ── Eyes ──
            var look = gaze
            if mood == .thinking { look = CGPoint(x: sin(t * 1.4) * 0.8, y: -0.7) }     // glancing up, pondering
            if mood == .working { look = CGPoint(x: sin(t * 3.2) * 0.6, y: 0.15) }      // following the scan
            if mood == .sleeping || mood == .happy { look = .zero }
            let eyeSpread = vW * 0.24
            let ex = look.x * vW * 0.09
            let ey = look.y * vH * 0.12
            let eyeW = vW * (mood == .working ? 0.15 : 0.13)
            var eyeH = vH * (mood == .listening || mood == .alert ? 0.58 : 0.48)
            if mood == .working { eyeH *= 0.62 }                                        // focused squint

            // Blink: every ~4s, occasionally a double blink. Deterministic in t.
            let period = 4.3
            let cycle = floor(t / period)
            let phase = t - cycle * period
            let doubleBlink = Int(cycle) % 3 == 0
            let blinking = phase > period - 0.13 || (doubleBlink && phase > period - 0.42 && phase < period - 0.30)
            let open: CGFloat = blinking ? 0.08 : 1

            for side in [-1.0, 1.0] {
                let cx = CGFloat(side) * eyeSpread + ex
                let cy = visor.midY + ey - (mood == .talking ? vH * 0.05 : 0)
                let lw = max(1, s * 0.035)
                switch mood {
                case .happy:                                                           // ^ ^
                    var p = Path()
                    p.move(to: CGPoint(x: cx - eyeW * 0.7, y: cy + eyeH * 0.18))
                    p.addQuadCurve(to: CGPoint(x: cx + eyeW * 0.7, y: cy + eyeH * 0.18),
                                   control: CGPoint(x: cx, y: cy - eyeH * 0.55))
                    ctx.stroke(p, with: .color(eyeColor), style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round))
                case .sleeping:                                                        // — —
                    var p = Path()
                    p.move(to: CGPoint(x: cx - eyeW * 0.6, y: cy + eyeH * 0.1))
                    p.addQuadCurve(to: CGPoint(x: cx + eyeW * 0.6, y: cy + eyeH * 0.1),
                                   control: CGPoint(x: cx, y: cy + eyeH * 0.35))
                    ctx.stroke(p, with: .color(eyeColor.opacity(0.6)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                case .sad:                                                             // worried, slanted
                    let r = CGRect(x: cx - eyeW / 2, y: cy - eyeH * open / 2 + eyeH * 0.1,
                                   width: eyeW, height: max(1, eyeH * open * 0.8))
                    ctx.fill(Capsule().path(in: r), with: .color(eyeColor))
                    var brow = Path()
                    brow.move(to: CGPoint(x: cx - eyeW * 0.8, y: cy - eyeH * 0.55 + CGFloat(side) * -eyeH * 0.12))
                    brow.addLine(to: CGPoint(x: cx + eyeW * 0.8, y: cy - eyeH * 0.55 + CGFloat(side) * eyeH * 0.12))
                    if detailed {
                        ctx.stroke(brow, with: .color(eyeColor.opacity(0.8)), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
                    }
                default:
                    let r = CGRect(x: cx - eyeW / 2, y: cy - eyeH * open / 2, width: eyeW, height: max(1, eyeH * open))
                    let g = r.insetBy(dx: -eyeW * 0.55, dy: -eyeW * 0.55)
                    ctx.fill(Ellipse().path(in: g), with: .radialGradient(
                        Gradient(colors: [eyeColor.opacity(0.5), eyeColor.opacity(0)]),
                        center: CGPoint(x: g.midX, y: g.midY), startRadius: 0, endRadius: max(g.width, g.height) / 2))
                    ctx.fill(Capsule().path(in: r), with: .color(eyeColor))
                    if detailed && !blinking {                                         // catchlight
                        let g = CGRect(x: r.minX + eyeW * 0.18, y: r.minY + eyeH * 0.12,
                                       width: eyeW * 0.32, height: eyeW * 0.32)
                        ctx.fill(Circle().path(in: g), with: .color(.white.opacity(0.85)))
                    }
                }
            }

            // ── Mouth: talks in time with streamed text, smiles when done ──
            if detailed {
                let my = visor.midY + vH * 0.30
                if mood == .talking {
                    let open = speech.map { 0.15 + 0.85 * Double(min(1, $0 * 1.6)) }
                        ?? 0.25 + 0.75 * abs(sin(t * 17) * sin(t * 6.3))
                    let w = vW * 0.14, h = max(1.5, vH * 0.20 * CGFloat(open))
                    ctx.fill(Capsule().path(in: CGRect(x: -w / 2, y: my - h / 2, width: w, height: h)),
                             with: .color(eyeColor.opacity(0.9)))
                } else if mood == .happy || mood == .idle {
                    var p = Path()
                    let w = vW * (mood == .happy ? 0.16 : 0.09)
                    p.move(to: CGPoint(x: -w / 2, y: my - vH * 0.02))
                    p.addQuadCurve(to: CGPoint(x: w / 2, y: my - vH * 0.02),
                                   control: CGPoint(x: 0, y: my + vH * (mood == .happy ? 0.14 : 0.07)))
                    ctx.stroke(p, with: .color(eyeColor.opacity(mood == .happy ? 0.95 : 0.55)),
                               style: StrokeStyle(lineWidth: max(1, s * 0.022), lineCap: .round))
                }
            }

            ctx.scaleBy(x: 1 / breathe, y: breathe)
            ctx.rotate(by: .radians(-tilt))

            // ── Floating extras ──
            if detailed {
                switch mood {
                case .thinking:                                                        // three orbiting dots
                    for i in 0..<3 {
                        let a = t * 2.4 + Double(i) * 2.094
                        let p = CGPoint(x: headW * 0.56 + CGFloat(cos(a)) * s * 0.05,
                                        y: head.minY - s * 0.02 + CGFloat(sin(a)) * s * 0.05)
                        let r = s * 0.028 * (1 + 0.3 * CGFloat(sin(a)))
                        ctx.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(eyeColor.opacity(0.8)))
                    }
                case .alert:                                                           // bouncing "!"
                    let y = head.minY - s * 0.06 - CGFloat(abs(sin(t * 5))) * s * 0.06
                    ctx.draw(Text("!").font(.system(size: s * 0.26, weight: .heavy, design: .rounded))
                                .foregroundColor(.yellow),
                             at: CGPoint(x: headW * 0.55, y: y))
                case .sleeping:                                                        // drifting z
                    let k = (t * 0.5).truncatingRemainder(dividingBy: 1)
                    ctx.draw(Text("z").font(.system(size: s * (0.14 + 0.08 * k), weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.7 * (1 - k))),
                             at: CGPoint(x: headW * 0.5 + CGFloat(k) * s * 0.08, y: head.minY - CGFloat(k) * s * 0.18))
                case .happy:                                                           // sparkle
                    let k = CGFloat((sin(t * 5) + 1) / 2)
                    ctx.draw(Text("✦").font(.system(size: s * (0.12 + 0.06 * k)))
                                .foregroundColor(eyeColor.opacity(0.9)),
                             at: CGPoint(x: -headW * 0.58, y: head.minY + s * 0.02))
                default: break
                }
            }
        }
    }
}

/// False for content that's mounted but not on screen (the pre-warmed
/// panel while the notch is closed) — per-frame animations pause.
private struct NotchContentVisibleKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var notchContentVisible: Bool {
        get { self[NotchContentVisibleKey.self] }
        set { self[NotchContentVisibleKey.self] = newValue }
    }
}
