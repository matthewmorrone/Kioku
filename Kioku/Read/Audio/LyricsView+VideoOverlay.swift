import SwiftUI

// The video-only layout of the lyrics view: the YouTube video shows through unveiled, the top bar
// stays for switching back, and the active line sits at the bottom in the same card the lyrics
// panel uses (progression highlight, word bubbles, translation) above the transport bar.
extension LyricsView {
    // Builds the overlay. Sections: top bar, free video area (bubbles draw up into it), bottom
    // card + transport bar on a material backing.
    func videoOverlay(geo: GeometryProxy) -> some View {
        let displayIndex = dragDisplayIndex ?? (singSession.isActive ? singSession.guidedCueIndex : nil) ?? activeIndex
        return VStack(spacing: 0) {
            videoTopBar
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                cardHandle(maxUp: geo.size.height * 0.6)
                activeCard(displayIndex: displayIndex, panelWidth: geo.size.width - 24, bubblesAboveOnly: true)
                controls
            }
            .frame(maxWidth: .infinity)
            // A backing, not a clip: word bubbles run past the card up over the video.
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            .gesture(lyricDragGesture(rendererHeight: activeCueRendererHeight))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .offset(y: videoCardOffset + videoCardDragOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The space the bubbles measure their room above and below the line against: the whole screen.
        .coordinateSpace(name: "lyricClip")
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { lyricClipHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in lyricClipHeight = height }
            }
        }
    }

    // The video layout's top bar: an escape button back to the lyrics, and the fill/fit toggle that
    // switches between cropping the video to the screen and showing all of it.
    private var videoTopBar: some View {
        HStack {
            Button {
                onToggleVideoMode()
            } label: {
                barIcon("xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Lyrics")

            Spacer(minLength: 0)

            Button {
                videoFitsScreen.toggle()
            } label: {
                barIcon(videoFitsScreen ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(videoFitsScreen ? "Fill Screen" : "Fit to Screen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // The grip at the top of the line card: drag it to move the card up the video (or back down),
    // clear of whatever the picture shows there.
    private func cardHandle(maxUp: CGFloat) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
            .gesture(
                // Measured in the stable parent space: the card moves as it is dragged, which would otherwise
                // feed back into the translation and make it shake.
                DragGesture(minimumDistance: 0, coordinateSpace: .named("lyricClip"))
                    .onChanged { value in
                        videoCardDragOffset = clampedCardOffset(videoCardOffset + value.translation.height, maxUp: maxUp) - videoCardOffset
                    }
                    .onEnded { value in
                        videoCardOffset = clampedCardOffset(videoCardOffset + value.translation.height, maxUp: maxUp)
                        videoCardDragOffset = 0
                    }
            )
            .accessibilityLabel("Move lyric card")
    }

    // Keeps the card between its resting place at the bottom and `maxUp` points above it.
    private func clampedCardOffset(_ offset: CGFloat, maxUp: CGFloat) -> CGFloat {
        min(0, max(-maxUp, offset))
    }
}
