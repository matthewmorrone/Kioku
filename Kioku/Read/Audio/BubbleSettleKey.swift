// What the lyrics card's bubbles wait on before showing (LyricsView.settleWordBubbles): the line
// on the card and whether the lines are being dragged or scrubbed through.
struct BubbleSettleKey: Hashable {
    let line: Int
    let isMoving: Bool
}
