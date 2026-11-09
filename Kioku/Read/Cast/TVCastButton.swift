import SwiftUI

// The round TV button in the lyrics and word views' top bars. A menu of the two views to cast;
// choosing one runs `onCast`, and while the video is rendering the icon becomes a progress ring.
// In the player that opens, the system AirPlay button sends the video to the TV.
struct TVCastButton: View {
    var diameter: CGFloat = 28
    var tint: Color = .secondary
    let onCast: (TVCastMode) -> Void
    @ObservedObject private var caster = LyricVideoCaster.shared

    var body: some View {
        Menu {
            Button("Cast Word by Word", systemImage: "textformat.size") { onCast(.words) }
            Button("Cast Lyrics", systemImage: "music.note.list") { onCast(.lyrics) }
        } label: {
            ZStack {
                if let progress = caster.renderProgress {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "tv")
                    .scaledFont(size: diameter * 0.46, weight: .semibold)
                    .foregroundStyle(tint)
            }
            .frame(width: diameter, height: diameter)
            .background(tint.opacity(0.16))
            .clipShape(Circle())
        }
        .disabled(caster.renderProgress != nil)
        .accessibilityLabel("Cast to TV")
    }
}
