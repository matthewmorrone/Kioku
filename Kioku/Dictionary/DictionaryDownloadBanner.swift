// DictionaryDownloadBanner.swift
//
// Floating bottom status banner shown while dictionary.sqlite is downloading (see
// DictionaryDownloadManager). Non-blocking by design: AGENTS.md's Architecture Non-Goals
// forbids a "mandatory network dependency", and its Failure Boundaries require dictionary
// lookup failure to not block editing and missing optional datasets to degrade gracefully.
// A full-screen gate (this file's earlier design) violated both — the app was completely
// unusable offline on a fresh install. dictionaryStore staying nil already degrades every
// dictionary-dependent view gracefully (empty states, nil-tolerant lookups), exactly as it
// did before this file existed; this banner only adds visibility into why, without blocking
// anything underneath it.

import SwiftUI

// Owned by ContentView, which instantiates and shows this via .overlay(alignment: .bottom),
// mirroring ClipboardLookupBanner's placement — visible above the tab bar, everything else
// on screen stays fully interactive.
struct DictionaryDownloadBanner: View {
    var downloadManager: DictionaryDownloadManager
    let onRetry: () -> Void

    // Renders either an error + retry state or a progress state, depending on whether the
    // last download attempt failed.
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.book.closed")
                .font(.title3)
                .foregroundStyle(.tint)

            if let errorMessage = downloadManager.errorMessage {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't Download Dictionary")
                        .font(.callout.weight(.medium))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading Dictionary")
                        .font(.callout.weight(.medium))
                    if let progress = downloadManager.progress {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                ProgressView(value: downloadManager.progress ?? 0)
                    .frame(maxWidth: 60)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 4)
    }
}
