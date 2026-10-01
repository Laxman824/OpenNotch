import SwiftUI

// Liquid Glass (macOS 26) for the open notch's surface, with a dark tint so text
// stays readable on busy wallpapers — "too transparent to read" is the most
// common complaint about Tahoe's own glass. Older macOS (and the Settings
// switch "Liquid Glass" off) keep the classic dark look. Only the surface is
// glass: cards inside it keep plain fills (glass shouldn't sample glass).

enum GlassStyle {
    /// User preference (default on); only takes effect on macOS 26+.
    static var enabled: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return UserDefaults.standard.object(forKey: "appearance.glass") as? Bool ?? true
    }
}

/// The open notch's body: tinted glass, kept black along the top so it still
/// melts into the hardware notch.
struct NotchSurface: View {
    let radius: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        if #available(macOS 26.0, *), GlassStyle.enabled {
            ZStack(alignment: .top) {
                NotchShape(radius: radius)
                    .fill(Color.clear)
                    .glassEffect(Glass.regular.tint(.black.opacity(0.55)), in: NotchShape(radius: radius))
                // Solid black for the notch's own height, then a short fade into the glass.
                let fade: CGFloat = 34
                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: notchHeight / (notchHeight + fade)),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: notchHeight + fade)
            }
            .clipShape(NotchShape(radius: radius))
        } else {
            NotchShape(radius: radius).fill(Theme.panel)
        }
    }
}
