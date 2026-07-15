// DictionaryDownloadGateView.swift
//
// Full-screen gate shown until dictionary.sqlite has finished downloading (see
// DictionaryDownloadManager). Every tab assumes dictionaryStore becomes non-nil shortly after
// launch — an assumption that held for free when the file shipped inside the bundle, and now
// depends on a ~350MB network download completing.

import SwiftUI

// Owned by ContentView, which instantiates and shows this as a full-screen overlay while
// dictionaryDownloadManager.isInstalled is false.
struct DictionaryDownloadGateView: View {
    var downloadManager: DictionaryDownloadManager
    let onRetry: () -> Void

    // Renders either an error + retry state or a progress state, depending on whether the
    // last download attempt failed.
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if let errorMessage = downloadManager.errorMessage {
                Text("Couldn't Download Dictionary")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Downloading Dictionary")
                    .font(.headline)
                ProgressView(value: downloadManager.progress ?? 0)
                    .frame(maxWidth: 240)
                if let progress = downloadManager.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
