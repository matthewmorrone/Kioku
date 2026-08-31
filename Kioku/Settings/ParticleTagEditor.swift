import SwiftUI

// Chip grid for adding and removing individual kana from the particle allowlist. Used by
// SettingsView+AdvancedSection's "Allowed Particles" / "Segmentation Demotions" sections. Split
// into its own file (it was already a standalone struct, not an extension of SettingsView) to
// help SettingsView.swift stay under the line-count guardrail.
struct ParticleTagEditor: View {
    @Binding var tags: [String]
    @State private var draft: String = ""
    // Plain @State (not @FocusState): JapaneseKeyboardField drives focus through a Bool binding.
    @State private var draftFocused: Bool = false

    var body: some View {
        // FlowLayout (not LazyVGrid) so each chip takes its natural width and wraps — no fixed
        // columns. Multi-character demotions (その物, か弱い) size to their content.
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                tagChip(for: tag)
            }
            addChip
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
    }

    // Inline text-field chip for entering a new particle without a separate row.
    // A hidden reference HStack drives the size; the real TextField sits on top.
    private var addChip: some View {
        HStack(spacing: 0) {
            // Hidden reference matches a real chip's content structure for identical sizing.
            Text(draft.isEmpty ? "か" : draft)
                .font(.subheadline)
                .hidden()
            Image(systemName: "xmark")
                .font(.caption2)
                .hidden()
        }
        .padding(8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(draftFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3), lineWidth: 1))
        .overlay {
            // Particles are Japanese kana, so default to the Japanese keyboard.
            JapaneseKeyboardField(text: $draft, isEditing: $draftFocused,
                                  placeholder: "＋", onSubmit: { commitDraft() })
                .padding(.horizontal, 8)
        }
        .contentShape(Capsule())
        .onTapGesture { draftFocused = true }
    }

    // Renders a single tag pill with a destructive remove button.
    private func tagChip(for tag: String) -> some View {
        HStack(spacing: 0) {
            Text(tag)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button(role: .destructive) {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    // Trims and appends the draft tag to the list, then clears the draft field.
    private func commitDraft() {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        if tags.contains(normalized) == false {
            tags.append(normalized)
            tags.sort()
        }
        draft = ""
    }
}

// FlowLayout lives in Kioku/FlowLayout.swift (shared with SubtitleImportView's vocab tag picker).
