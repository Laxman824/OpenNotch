import AppKit
import SwiftUI

// The closed notch's "live activities" for music and timers, in the spirit of
// the Dynamic Island: album art + a spectrum tinted from it, a scrolling title
// with track progress, and a glowing progress ring + rolling digits for timers.
//
// Music shares one 24 fps clock (CollapsedView's TimelineView) passed in as
// `date`; timers have their own. Nothing here uses per-frame blurs/shadows —
// glows are drawn as faint fat strokes and radial gradients (CPU).

// MARK: - Music

/// Left ear: the album art, breathing on the beat with a glow in its own colour.
struct MusicArtEar: View {
    @ObservedObject var backend: Backend
    var date: Date
    var size: CGFloat = 22

    var body: some View {
        let tint = backend.artworkTint ?? Theme.glow[1]
        let beat = MusicPulse.beat(date.timeIntervalSinceReferenceDate)
        art
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .background(
                    RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                        .fill(RadialGradient(colors: [tint.opacity(0.55), .clear], center: .center,
                                             startRadius: size * 0.3, endRadius: size * 0.85))
                        .frame(width: size * 1.7, height: size * 1.7)
                        .opacity(0.4 + 0.6 * beat))
                .scaleEffect(1 + 0.045 * beat)
    }

    @ViewBuilder private var art: some View {
        if let img = backend.artwork {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Theme.glow[1], Theme.glow[2]], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let app = backend.nowPlaying.app {
                    appIcon(forPath: app == "Spotify" ? "/Applications/Spotify.app" : "/System/Applications/Music.app",
                            size: size).resizable().padding(3)
                } else {
                    Image(systemName: "music.note").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
    }
}

/// Right ear: the title scrolling past, over the track's progress.
struct MusicInfoEar: View {
    @ObservedObject var backend: Backend
    var date: Date

    var body: some View {
        let np = backend.nowPlaying
        let tint = backend.artworkTint ?? Theme.glow[1]
        let t = date.timeIntervalSinceReferenceDate
        VStack(alignment: .leading, spacing: 3.5) {
            Marquee(text: [np.track, np.artist].filter { !$0.isEmpty }.joined(separator: " · "), t: t, size: 11.5)
                .frame(height: 14)
            if np.duration > 0 {
                ProgressLine(value: np.livePosition(date) / np.duration, tint: tint)
                    .frame(height: 2.2)
            }
        }
    }
}

/// Siri-style ribbons of light running from the album art, behind the
/// camera, to the title — they swell on the beat, drift with the melody,
/// and take their colours from the album art.
struct MusicWave: View {
    @ObservedObject var backend: Backend
    var date: Date

    var body: some View {
        let tint = backend.artworkTint ?? Theme.glow[1]
        let colors = [tint, Theme.glow[0], .white, tint]
        let t = date.timeIntervalSinceReferenceDate * (MusicPulse.calm ? 0.35 : 1)     // Reduce Motion: drift slowly
        Canvas { c, size in
                var g = c
                g.blendMode = .plusLighter
                let mid = size.height / 2, w = size.width
                let beat = MusicPulse.beat(t)
                for i in 0..<colors.count {
                    let fi = Double(i)
                    let amp = size.height * 0.36 * CGFloat(0.3 + 0.4 * MusicPulse.bar(i + 1, t) + 0.3 * beat)
                    let freq = 2.2 + fi * 0.7, speed = 1.6 + fi * 0.55, phase = fi * 1.9
                    let steps = 56
                    var upper: [CGPoint] = [], lower: [CGPoint] = []
                    for s in 0...steps {
                        let x = Double(s) / Double(steps)
                        // Full height along the run (the middle is behind the camera,
                        // so a centre-heavy swell would be wasted); melt in/out at the ends.
                        let edge = min(x, 1 - x) * Double(w) / 22
                        let taper = edge >= 1 ? 1 : edge * edge * (3 - 2 * edge)
                        let y = sin(x * freq * 2 * .pi - t * speed + phase) * 0.7
                              + sin(x * freq * 2.3 * 2 * .pi + t * speed * 0.6 + phase) * 0.3
                        let cy = mid + CGFloat(y * taper) * amp
                        let thick = CGFloat(taper) * (i == 2 ? 0.8 : 1.6) * CGFloat(0.6 + 0.6 * beat)
                        upper.append(CGPoint(x: CGFloat(x) * w, y: cy - thick))
                        lower.append(CGPoint(x: CGFloat(x) * w, y: cy + thick))
                    }
                    var ribbon = Path()
                    ribbon.addLines(upper + lower.reversed())
                    ribbon.closeSubpath()
                    // Glow without a blur: the same ribbon, fatter and faint.
                    g.opacity = 0.18
                    g.stroke(ribbon, with: .color(colors[i]), lineWidth: 3)
                    g.opacity = i == 2 ? 0.55 : 0.8
                    g.fill(ribbon, with: .color(colors[i]))
                }
            }
        .drawingGroup()          // rasterise on the GPU
        .allowsHitTesting(false)
    }
}

/// A made-up but musical beat: we can't hear other apps' audio without a
/// Screen Recording grant, so this sums a ~118 bpm kick with slower swells.
enum MusicPulse {
    /// Reduce Motion: no beat pulses (set by AnimationPolicy).
    nonisolated(unsafe) static var calm = false

    static func beat(_ t: Double) -> Double {
        if calm { return 0.3 }
        let phase = (t * 118 / 60).truncatingRemainder(dividingBy: 1)
        return pow(1 - phase, 3.2) * (0.75 + 0.25 * sin(t * 0.7))
    }

    /// Height 0…1 of spectrum bar `i` at time `t`.
    static func bar(_ i: Int, _ t: Double) -> Double {
        let fi = Double(i)
        let wobble = 0.5 + 0.5 * sin(t * (5.3 + fi * 1.7) + fi * 2.1) * sin(t * (2.1 + fi * 0.9) + fi)
        let kick = beat(t - fi * 0.035) * (i == 0 || i == 4 ? 0.55 : 0.85)
        return min(1, 0.18 + 0.45 * wobble + 0.5 * kick)
    }
}

struct ProgressLine: View {
    var value: Double
    var tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(LinearGradient(colors: [tint, .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2.2, g.size.width * min(1, max(0, value))))
            }
        }
    }
}

/// Text that glides past when it doesn't fit, with soft faded edges.
struct Marquee: View {
    var text: String
    var t: Double
    var size: CGFloat = 10
    var weight: NSFont.Weight = .semibold
    var opacity: Double = 0.92
    private var font: NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

    var body: some View {
        GeometryReader { g in
            let textW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let fits = textW <= g.size.width
            let gap: CGFloat = 26, speed = 22.0, rest = 1.6
            let loop = Double(textW + gap) / speed
            let phase = t.truncatingRemainder(dividingBy: loop + rest)
            let x = fits ? 0 : -CGFloat(max(0, phase - rest) * speed)
            HStack(spacing: gap) {
                label
                if !fits { label }
            }
            .fixedSize()
            .offset(x: x)
            .frame(width: g.size.width, alignment: .leading)
            .mask(LinearGradient(stops: [.init(color: fits ? .black : .clear, location: 0),
                                         .init(color: .black, location: 0.1),
                                         .init(color: .black, location: 0.86),
                                         .init(color: fits ? .black : .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .clipped()
    }

    private var label: some View {
        Text(text).font(Font(font)).foregroundStyle(.white.opacity(opacity)).lineLimit(1)
    }
}

/// A vivid accent from the album art: the most colourful pixels of a
/// thumbnail, lifted so it glows against black.
enum ArtworkColor {
    static func vivid(_ image: NSImage) -> Color? {
        let n = 16
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var best: [(score: Double, h: Double, s: Double)] = []
        for i in 0..<(n * n) {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                            blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            best.append((Double(s) * Double(b) * Double(b), Double(h), Double(s)))
        }
        best.sort { $0.score > $1.score }
        let top = best.prefix(24)
        guard let first = top.first, first.score > 0.04 else {
            return Color(hue: 0.72, saturation: 0.35, brightness: 1)    // grey art → soft lavender
        }
        // Average hue on the circle so reds either side of 0 don't cancel out.
        let x = top.reduce(0) { $0 + cos($1.h * 2 * .pi) }, y = top.reduce(0) { $0 + sin($1.h * 2 * .pi) }
        var hue = atan2(y, x) / (2 * .pi); if hue < 0 { hue += 1 }
        let sat = top.reduce(0) { $0 + $1.s } / Double(top.count)
        return Color(hue: hue, saturation: min(0.85, max(0.55, sat)), brightness: 1)
    }
}

// MARK: - Timers

private extension TimerStore {
    var palette: [Color] {
        switch kind {
        case .pomodoro where onBreak:
            return [Color(red: 0.30, green: 0.95, blue: 0.65), Color(red: 0.35, green: 0.85, blue: 1.0)]
        case .pomodoro: return [Theme.glow[0], Theme.glow[1], Theme.glow[2]]
        case .countdown: return [Color(red: 1.0, green: 0.72, blue: 0.25), Color(red: 1.0, green: 0.42, blue: 0.55)]
        case .stopwatch: return [Color(red: 0.30, green: 0.85, blue: 1.0), Color(red: 0.45, green: 0.55, blue: 1.0)]
        case nil: return [.white, .white]
        }
    }

    /// Final ten seconds of a countdown or focus/break block.
    func urgent(_ now: Date) -> Bool {
        running && kind != .stopwatch && total - liveElapsed(now) <= 10
    }

    var label: String {
        switch kind {
        case .pomodoro: return onBreak ? "BREAK" : "FOCUS"
        case .countdown: return "TIMER"
        case .stopwatch: return "STOPWATCH"
        case nil: return ""
        }
    }

    var icon: String {
        if paused { return "pause.fill" }
        switch kind {
        case .pomodoro: return onBreak ? "cup.and.saucer.fill" : "brain.head.profile"
        case .stopwatch: return "stopwatch.fill"
        default: return "timer"
        }
    }
}

private let urgentColors = [Color(red: 1.0, green: 0.45, blue: 0.30), Color(red: 1.0, green: 0.25, blue: 0.40)]

/// Left ear: a progress ring that fills smoothly, with a glowing head.
struct TimerRingEar: View {
    @ObservedObject private var policy = AnimationPolicy.shared
    @ObservedObject var timers: TimerStore
    var size: CGFloat = 23

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / policy.fps, paused: !timers.running && !timers.paused)) { ctx in
            let now = ctx.date
            let t = now.timeIntervalSinceReferenceDate
            let urgent = timers.urgent(now)
            let colors = urgent ? urgentColors : timers.palette
            let p = timers.kind == .stopwatch
                ? timers.liveElapsed(now).truncatingRemainder(dividingBy: 60) / 60
                : timers.liveProgress(now)
            // Pause: a slow breath. Final ten seconds: a heartbeat every second.
            let beat = urgent && !policy.reduceMotion ? pow(1 - t.truncatingRemainder(dividingBy: 1), 4) : 0
            let breath = timers.paused ? 0.55 + 0.35 * (0.5 + 0.5 * sin(t * 2.4)) : 1
            let lw: CGFloat = 2.6
            ZStack {
                Circle().stroke(.white.opacity(0.13), lineWidth: lw)
                Circle()
                    .trim(from: 0, to: max(0.001, p))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, p))),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Glowing head of the arc.
                Circle().fill(RadialGradient(colors: [.white, .white, colors.last!.opacity(0.6), .clear],
                                             center: .center, startRadius: 0, endRadius: lw + 2.5))
                    .frame(width: 2 * (lw + 2.5), height: 2 * (lw + 2.5))
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(360 * p))
                    .opacity(p > 0.004 ? 1 : 0)
                Image(systemName: timers.icon)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            }
            .frame(width: size, height: size)
            .background(Circle().fill(RadialGradient(colors: [colors[0].opacity(0.45), .clear], center: .center,
                                                     startRadius: size * 0.35, endRadius: size * 0.8))
                .frame(width: size * 1.6, height: size * 1.6)
                .opacity(0.35 + 0.65 * beat))
            .scaleEffect(1 + 0.1 * beat)
            .opacity(breath)
        }
    }
}

/// Right ear: what kind of timer, over rolling digits.
struct TimerClockEar: View {
    @ObservedObject var timers: TimerStore

    var body: some View {
        let colors = timers.urgent(Date()) ? urgentColors : timers.palette
        let text = TimerStore.clock(timers.remaining)
        VStack(alignment: .leading, spacing: -1) {
            Text(timers.paused ? "PAUSED" : timers.label)
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(colors[0].opacity(0.85))
            Text(text)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [.white, colors.last!], startPoint: .top, endPoint: .bottom))
                .contentTransition(.numericText(countsDown: timers.kind != .stopwatch))
                .animation(.snappy(duration: 0.35), value: text)
                .opacity(timers.paused ? 0.6 : 1)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
        .animation(.easeInOut(duration: 0.3), value: timers.paused)
    }
}


// MARK: - Hover player

/// Resting on the music ears drops out a compact player (Dynamic Island's
/// long-press view): big art, title, artist, a scrub bar and controls —
/// without opening the full panel. Click the background for the full notch.
struct PlayerView: View {
    @ObservedObject private var policy = AnimationPolicy.shared
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @State private var scrub: Double? = nil        // 0…1 while dragging the bar
    @State private var pendingPlay: Bool? = nil    // optimistic play/pause icon

    var body: some View {
        let np = backend.nowPlaying
        let tint = backend.artworkTint ?? Theme.glow[1]
        TimelineView(.animation(minimumInterval: 1.0 / policy.fps)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            VStack(spacing: 0) {
                // The strip beside the camera keeps the collapsed wave going.
                MusicWave(backend: backend, date: ctx.date)
                    .padding(.horizontal, 24)
                    .frame(height: notch.notchSize.height)
                    .opacity(np.playing ? 1 : 0.35)
                HStack(spacing: 14) {
                    MusicArtEar(backend: backend, date: np.playing ? ctx.date : .distantPast, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Marquee(text: np.track.isEmpty ? "Nothing playing" : np.track, t: t, size: 14, weight: .bold, opacity: 1)
                            .frame(height: 18)
                        Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        scrubber(np, now: ctx.date, tint: tint).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                controls(np, tint: tint).padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { notch.expand(pinned: true) }
        .onChange(of: np.playing) { _, _ in pendingPlay = nil }
    }

    private func scrubber(_ np: NowPlaying, now: Date, tint: Color) -> some View {
        let live = np.duration > 0 ? np.livePosition(now) / np.duration : 0
        let value = scrub ?? live
        return VStack(spacing: 3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(LinearGradient(colors: [tint, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * value))
                    Circle().fill(.white)
                        .frame(width: scrub == nil ? 7 : 11, height: scrub == nil ? 7 : 11)
                        .offset(x: g.size.width * value - (scrub == nil ? 3.5 : 5.5))
                }
                .frame(height: scrub == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(1, max(0, v.location.x / g.size.width)) }
                    .onEnded { _ in
                        if let s = scrub, np.duration > 0 { backend.seek(s * np.duration) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scrub = nil }
                    })
                .animation(.spring(duration: 0.2), value: scrub == nil)
            }
            .frame(height: 12)
            .opacity(np.duration > 0 ? 1 : 0.3)
            HStack {
                Text(TimerStore.clock(value * np.duration))
                Spacer()
                Text("-" + TimerStore.clock(max(0, np.duration * (1 - value))))
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(Theme.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TimerStore.clock(value * np.duration)) of \(TimerStore.clock(np.duration))")
        .accessibilityAdjustableAction { dir in
            guard np.duration > 0 else { return }
            let step: Double = dir == .increment ? 10 : -10
            backend.seek(min(np.duration, max(0, np.livePosition() + step)))
        }
    }

    private func controls(_ np: NowPlaying, tint: Color) -> some View {
        let playing = pendingPlay ?? np.playing
        return HStack(spacing: 34) {
            if let app = np.app {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: app == "Spotify" ? "/Applications/Spotify.app" : "/System/Applications/Music.app")) } label: {
                    appIcon(forPath: app == "Spotify" ? "/Applications/Spotify.app" : "/System/Applications/Music.app", size: 18)
                        .resizable().frame(width: 18, height: 18)
                }
                .buttonStyle(HoverLift()).help("Open \(app)").accessibilityLabel("Open \(app)")
            }
            control("backward.fill", 15, "Previous track") { backend.media("previous") }
            control(playing ? "pause.fill" : "play.fill", 22, playing ? "Pause" : "Play") {
                pendingPlay = !playing
                backend.media(playing ? "pause" : "play")
            }
            .contentTransition(.symbolEffect(.replace))
            control("forward.fill", 15, "Next track") { backend.media("next") }
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, isActive: playing)
                .frame(width: 18)
                .accessibilityHidden(true)
        }
    }

    private func control(_ icon: String, _ size: CGFloat, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverLift())
        .accessibilityLabel(label)
    }
}

// MARK: - Split island

/// The split-island pill: compact signs for live things that don't own the ears.
/// Updates at most once a second (rule 7: nothing per-frame while the notch is closed).
struct SidePill: View {
    let items: [NotchController.EarActivity]
    @ObservedObject var notch: NotchController
    @ObservedObject var backend: Backend
    @ObservedObject var timers: TimerStore
    @ObservedObject var handsFree: HandsFree

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { a in
                item(a).frame(width: NotchController.pillItemWidth(a))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(NotchShape(radius: 11).fill(Color.black))          // hangs from the top edge like the notch
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func item(_ a: NotchController.EarActivity) -> some View {
        switch a {
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let colors = timers.urgent(ctx.date) ? urgentColors : timers.palette
                let p = timers.kind == .stopwatch ? timers.liveElapsed(ctx.date).truncatingRemainder(dividingBy: 60) / 60
                    : timers.liveProgress(ctx.date)
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.001, p))
                            .stroke(colors[0], style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text(TimerStore.clock(timers.remaining))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(timers.paused ? 0.55 : 0.92))
                        .lineLimit(1).fixedSize()
                }
            }
            .accessibilityLabel("Timer \(TimerStore.clock(timers.remaining))")
        case .music:
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.7), Color(red: 0.75, green: 0.5, blue: 1)],
                                                startPoint: .top, endPoint: .bottom))
                .accessibilityLabel("Playing \(backend.nowPlaying.track)")
        case .agent:
            let (icon, color): (String, Color) =
                !backend.approvals.isEmpty ? ("exclamationmark.circle.fill", .yellow)
                : backend.busy ? ("sparkles", Theme.glow[0])
                : handsFree.isOn ? ("waveform", Color(red: 0.25, green: 0.8, blue: 1))
                : ("checkmark.circle.fill", .green)
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                .accessibilityLabel(!backend.approvals.isEmpty ? "Needs your OK" : backend.busy ? "Working" : "Answer ready")
        case .awake:
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.45))
                .accessibilityLabel("Keeping awake")
        default:
            EmptyView()
        }
    }
}
