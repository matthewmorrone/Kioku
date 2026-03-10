import SwiftUI
import UIKit

// Hosts note loading and persistence helpers for the read screen.
extension ReadView {
    // Loads the selected note into editor state when navigation targets change.
    func loadSelectedNoteIfNeeded() {
        guard let selectedNote else { return }
        isLoadingSelectedNote = true
        activeNoteID = selectedNote.id
        onActiveNoteChanged?(selectedNote.id)
        customTitle = selectedNote.title
        fallbackTitle = selectedNote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: selectedNote.content)
            : selectedNote.title
        text = selectedNote.content
        tokenRanges = normalizedTokenRanges(
            selectedNote.tokenRanges,
            for: selectedNote.content
        )
        refreshSegmentationRanges()
        self.selectedNote = nil
        isLoadingSelectedNote = false
    }

    // Saves the in-memory editor state to storage and maintains active note identity.
    func persistCurrentNoteIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid creating an empty note when the editor has no active note yet.
        if trimmedText.isEmpty && activeNoteID == nil {
            return
        }

        var notes = loadNotesFromStorage()
        // Prefer explicit titles; otherwise derive one from first content line.
        let titleToSave = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: text)
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackTitle = titleToSave

        if let activeNoteID, let index = notes.firstIndex(where: { $0.id == activeNoteID }) {
            // Update the existing note in place when editing an active item.
            notes[index].title = titleToSave
            notes[index].content = text
            notes[index].tokenRanges = tokenRanges
        } else {
            // Insert a new note only when no active note identity exists.
            let newNote = Note(
                title: titleToSave,
                content: text,
                tokenRanges: tokenRanges
            )
            notes.insert(newNote, at: 0)
            activeNoteID = newNote.id
            onActiveNoteChanged?(newNote.id)
        }

        if let activeNoteID {
            onActiveNoteChanged?(activeNoteID)
        }

        saveNotesToStorage(notes)
    }

    // Reads note payloads from user defaults storage.
    func loadNotesFromStorage() -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }

    // Writes note payloads to user defaults storage.
    func saveNotesToStorage(_ notes: [Note]) {
        guard let encoded = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    var resolvedTitle: String {
        let trimmedCustom = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }

        return fallbackTitle
    }

    var displayTitle: String {
        resolvedTitle.isEmpty ? " " : resolvedTitle
    }

    // Derives a fallback title from the first line of note content.
    func firstLineTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
    }

}
