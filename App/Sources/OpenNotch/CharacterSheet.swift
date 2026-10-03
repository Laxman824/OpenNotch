import AppKit
import SwiftUI

/// `OpenNotch --render-character out.png` — a contact sheet of every mood and
/// reaction, for reviewing the character without launching the app.
@MainActor
enum CharacterSheet {
    static let perchPoses: [(String, PerchPose.Pose)] = [
        ("idle", PerchPose.action(.idle, p: 0, t: 1000.3)), ("wave", PerchPose.action(.wave, p: 0.5, t: 1000.3)),
        ("stretch", PerchPose.action(.stretch, p: 0.5, t: 1000.3)), ("yawn", PerchPose.action(.yawn, p: 0.5, t: 1000.3)),
        ("kick", PerchPose.action(.kick, p: 0.5, t: 1000.17)), ("walk", PerchPose.action(.walk, p: 0.5, t: 1000.14)),
        ("typing", PerchPose.typing(t: 1000.07)), ("dance", PerchPose.dance(t: 1000.1)), ("asleep", PerchPose.asleep()),
        ("hero landing", PerchPose.hero()),
    ]

    static func render(to path: String) -> Int32 {
        let palette = AvatarPalette.named(UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora")
        let t = 1000.3                                     // a moment with eyes open
        let moods: [(String, AvatarMood, PuffExpression?, CGPoint, Double)] = [
            ("idle", .idle, nil, CGPoint(x: 0.4, y: 0.2), 0), ("look left", .idle, nil, CGPoint(x: -0.9, y: 0), 0),
            ("listening", .listening, nil, .zero, 0), ("thinking", .thinking, nil, .zero, 0),
            ("working", .working, nil, .zero, 0), ("talking", .talking, nil, .zero, 0),
            ("happy", .happy, nil, .zero, 0), ("alert", .alert, nil, .zero, 0),
            ("sad", .sad, nil, .zero, 0), ("sleeping", .sleeping, nil, .zero, 0),
            ("poked: annoyed", .idle, .annoyed, .zero, 0.12), ("3 pokes: dizzy", .idle, .dizzy, .zero, 0.08),
            ("petted: love", .idle, .love, .zero, 0), ("file drag: surprised", .idle, .surprised, .zero, 0),
            ("task done: hop", .idle, .celebrate, .zero, 0),
        ]
        let cell = { (label: String, mood: AvatarMood, expr: PuffExpression?, gaze: CGPoint, sway: Double, size: CGFloat) -> AnyView in
            AnyView(VStack(spacing: 6) {
                PuffCanvas(size: size, mood: mood, palette: palette, t: t, gaze: gaze,
                           phys: PuffPhysics(squash: expr == .annoyed ? 0.12 : 0, hop: expr == .celebrate ? 0.25 : 0,
                                             sway: sway, eyeBoost: 1, expression: expr,
                                             hearts: expr == .love ? [(0.4, -0.2), (0.9, 0.25)] : []))
                    .frame(width: size, height: size)
                if size > 40 { Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)) }
            })
        }
        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text("Puff — OpenNotch's notch character").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(0..<5, id: \.self) { col in
                        let m = moods[row * 5 + col]
                        cell(m.0, m.1, m.2, m.3, m.4, 100)
                    }
                }
            }
            Text("With a body — the perch beside the closed notch:").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 22) {
                ForEach(Self.perchPoses, id: \.0) { p in
                    VStack(spacing: 6) {
                        PuffCanvas(size: 100, mood: p.1.mood ?? .idle, palette: palette, t: t, gaze: p.1.gaze ?? CGPoint(x: 0.3, y: 0.1),
                                   phys: PuffPhysics(squash: p.0 == "hero landing" ? 0.12 : 0, sway: p.0 == "hero landing" ? 0.16 : 0,
                                                     expression: p.0 == "hero landing" ? .heroic : nil),
                                   limbs: p.1.limbs)
                            .frame(width: 100, height: 100).offset(y: -p.1.bob * 100)
                        Text(p.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            Text("At real size (38 pt notch):").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 0) {
                PuffCanvas(size: 35, mood: .idle, palette: palette, t: t, gaze: CGPoint(x: 0.5, y: 0.2),
                           limbs: PerchPose.action(.wave, p: 0.5, t: t).limbs)
                    .frame(width: 46, height: 38)
                Color.black.frame(width: 209, height: 38)
                Text("14m").font(Typo.numeric(11.5)).foregroundStyle(.white.opacity(0.85)).frame(width: 46, height: 38)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.06)))
            Text("In the closed notch (22 pt):").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 14) {
                ForEach(0..<moods.count, id: \.self) { i in cell("", moods[i].1, moods[i].2, moods[i].3, moods[i].4, 22) }
            }
        }
        .padding(24)
        .background(Color.black)
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return 1 }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print(error); return 1 }
        print("wrote \(path)")
        return 0
    }
}

/// `OpenNotch --render-ears out.png` — the closed-notch live activities at real size.
@MainActor
enum EarsSheet {
    static func render(to path: String) -> Int32 {
        let timers = TimerStore()
        timers.startCountdown(seconds: 25 * 60)
        let notchW: CGFloat = 209, notchH: CGFloat = 38
        func notch<L: View, R: View>(_ ear: CGFloat, _ l: L, _ r: R) -> some View {
            HStack(spacing: 0) {
                l.frame(width: ear)
                Color.black.frame(width: notchW)
                r.frame(width: ear)
            }
            .frame(height: notchH)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        }
        let sheet = VStack(alignment: .leading, spacing: 14) {
            Text("Closed notch at real size (38 pt tall)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            notch(82, TimerRingEar(timers: timers), TimerClockEar(timers: timers))
            notch(100, HStack { Spacer(); HUDLeftEar(hud: .volume(level: 0.62, muted: false)) }.padding(.trailing, 14),
                  HUDRightEar(hud: .volume(level: 0.62, muted: false)))
            notch(100, HStack { Spacer(); HUDLeftEar(hud: .power(charging: true, plugged: true, percent: 76)) }.padding(.trailing, 14),
                  HUDRightEar(hud: .power(charging: true, plugged: true, percent: 76)))
            notch(132, HStack { Spacer(); HUDLeftEar(hud: .health(icon: "cpu", title: "CPU busy · 93%", detail: "node is using 187%", tone: 1)) }.padding(.trailing, 14),
                  HUDRightEar(hud: .health(icon: "cpu", title: "CPU busy · 93%", detail: "node is using 187%", tone: 1)))
        }
        .padding(20)
        .background(Color(white: 0.25))
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        return 0
    }
}
