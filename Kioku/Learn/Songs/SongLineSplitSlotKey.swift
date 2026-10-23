import SwiftUI

// Tags each child of SongLineSplitLayout with its row and role. Children without a tag (none, in
// practice) go in row 0 as segments.
nonisolated struct SongLineSplitSlotKey: LayoutValueKey {
    static let defaultValue = SongLineSplitSlot(row: 0, role: .segment)
}
