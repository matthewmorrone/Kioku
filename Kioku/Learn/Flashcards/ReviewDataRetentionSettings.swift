import Foundation

// Whether unsaving a word also wipes its ReviewStore data (Learned/Not-Learned mark, mastery,
// SRS stats). Default is to forget — WordsStore and ReviewStore are independent stores keyed by
// canonicalEntryID, so nothing else forces that coupling; this setting is the user's explicit
// say over it, off by default so an unsave reads as "I don't want this tracked" rather than
// silently retaining study history behind a deleted card.
enum ReviewDataRetentionSettings {
    static let retainOnDeletionKey = "kioku.settings.retainLearnDataOnWordDeletion"
    static let defaultRetainOnDeletion = false
}
