import SwiftUI

/// Voice visual for hands-free, in the spirit of Siri's waveform: layered,
/// tapered ribbons of light that swell with the live audio level.
///
///   listening → cool blues, driven by your mic
///   speaking  → purple / pink / orange, driven by Ledge's actual audio
///   thinking  → a quick rainbow shimmer, no audio
///   idle      → a dim, slow breath (standby)
struct SiriWave: View {
    enum Mode: Equatable { case listening, speaking, thinking, idle }

    var mode: Mode
    var level: CGFloat                 // 0…1, raw
    var ribbons = 4
    @State private var smooth = Smoother()
    @Environment(\.notchContentVisible) private var visible

    var body: some View {
        TimelineView(.animation(paused: !visible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let target: CGFloat = switch mode {
            case .thinking: 0.3 + 0.08 * CGFloat(sin(t * 3))
            case .idle: 0.05 + 0.03 * CGFloat(sin(t * 1.2))
            default: max(0.06, min(1, level * 1.4))
            }
            let amp = smooth.step(to: target)
            Canvas { c, size in
                draw(c, size: size, t: t, amp: amp)
            }
        }
        .allowsHitTesting(false)
    }

    private var palette: [Color] {
        switch mode {
        case .listening:
            return [Color(red: 0.25, green: 0.85, blue: 1.0), Color(red: 0.30, green: 0.50, blue: 1.0),
                    Color(red: 0.45, green: 1.0, blue: 0.85), Color(red: 0.55, green: 0.40, blue: 1.0)]
        case .speaking:
            return [Color(red: 0.72, green: 0.40, blue: 1.0), Color(red: 1.0, green: 0.40, blue: 0.70),
                    Color(red: 1.0, green: 0.62, blue: 0.30), Color(red: 0.40, green: 0.55, blue: 1.0)]
        case .thinking:
            return Array(Theme.glow.prefix(4))
        case .idle:
            return [Color(red: 0.35, green: 0.50, blue: 0.95), Color(red: 0.55, green: 0.40, blue: 0.9),
                    Color(red: 0.35, green: 0.50, blue: 0.95), Color(red: 0.55, green: 0.40, blue: 0.9)]
        }
    }

    private func draw(_ c: GraphicsContext, size: CGSize, t: Double, amp: CGFloat) {
        let w = size.width, mid = size.height / 2
        let colors = palette
        var ctx = c
        ctx.blendMode = .plusLighter

        for i in 0..<min(ribbons, colors.count) {
            let fi = Double(i)
            let freq = 1.25 + fi * 0.45
            let speed = (mode == .thinking ? 6.0 : 3.4) + fi * 0.8
            let dir: Double = i % 2 == 0 ? 1 : -1
            let hue = mode == .thinking ? sin(t * 1.3 + fi) * 0.5 : 0
            let a = amp * size.height * 0.5 * (1 - CGFloat(i) * 0.13)

            // A ribbon: the upper edge follows the wave, the lower edge follows
            // a flattened mirror of it, so it reads as a band of light.
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            for x in stride(from: 0, through: w, by: 2) {
                let rel = Double(x / w)
                let env = pow(1 - pow(2 * rel - 1, 2), 2.2)            // taper to points at both ends
                let s = sin(rel * freq * .pi * 2 + t * speed * dir + fi * 1.7 + hue)
                let y = CGFloat(s * env) * a
                top.append(CGPoint(x: x, y: mid - y))
                bottom.append(CGPoint(x: x, y: mid + y * 0.5))
            }
            var p = Path()
            p.addLines(top)
            p.addLines(bottom.reversed())
            p.closeSubpath()
            let color = colors[i]
            ctx.fill(p, with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.75), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: w, y: mid)))
        }

        // Bright core line — the "string" the ribbons vibrate around.
        var core = Path()
        core.move(to: CGPoint(x: w * 0.08, y: mid))
        core.addLine(to: CGPoint(x: w * 0.92, y: mid))
        ctx.stroke(core, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.35 + 0.4 * Double(amp)), .white.opacity(0)]),
            startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: w, y: mid)), lineWidth: 1)
    }
}

/// Fast attack, slow release — how a level meter should feel.
final class Smoother {
    private(set) var value: CGFloat = 0
    func step(to target: CGFloat) -> CGFloat {
        value += (target - value) * (target > value ? 0.35 : 0.08)
        return value
    }
}

extension HandsFree {
    /// Which wave to show, and which audio drives it.
    var waveMode: SiriWave.Mode {
        switch phase {
        case .listening, .hearing: return .listening
        case .speaking: return .speaking
        case .thinking, .starting: return .thinking
        case .standby, .off: return .idle
        }
    }

    var waveLevel: CGFloat { phase == .speaking ? speechLevel : level }
}
