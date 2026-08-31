import SwiftUI
import SwiftWhisperAlign
import UIKit

// Pill-button helper for the alignment-fix row's commit actions (Start here / + shift rest /
// End here). Split into its own file purely to keep LyricsView.swift under the 1000-line cap;
// it carries no view state, so it lives as a plain extension method.
extension LyricsView {
    // Pill button for a start/end-commit action in the alignment-fix row.
    func fixActionButton(title: String, system: String, tint: UIColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: system)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color(tint))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(tint).opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // Timing readout under the Re-align/Adjust/Mix row: just the shown card's cue start → end,
    // centered and subdued. The transport already shows the live playhead, so it isn't repeated here.
    // Long-press dumps the vocal-stem ASR transcript (debug) to compare against the aligned timing.
    // Not private: called from panel(geo:) in LyricsView.swift.
    @ViewBuilder
    func cueTimingBar(index: Int) -> some View {
        Group {
            if isDumpingTranscript {
                Text(transcriptStatus.isEmpty ? "Transcribing vocals…" : transcriptStatus)
                    .font(.system(size: 12, weight: .medium))
            } else if index >= 0, index < cues.count {
                let cue = cues[index]
                Text("\(compactMs(cue.startMs))  →  \(compactMs(cue.endMs))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onLongPressGesture { dumpStemTranscript() }
        .sheet(isPresented: $showTranscriptSheet) { transcriptSheet }
    }

    // Top action bar for the karaoke view: a single full Re-align action that re-runs the whole
    // CTC alignment pipeline (vocal separation + windowing) over the note's lyrics against the
    // attached audio — no wipe / re-import. Replaces the old per-cue timing-editor row. While
    // running it shows a spinner + live progress and disables so a second run can't stack.
    // Not private: called from panel(geo:) in LyricsView.swift.
    func reAlignBar() -> some View {
        HStack(spacing: 8) {
            if isReAligning {
                // Live progress is its OWN non-interactive chip, not the disabled Button's
                // label — a disabled Button dims its whole label, which made the status text
                // read as greyed-out/inactive. `.primary` keeps it high-contrast over the bar.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(reAlignMessage.isEmpty ? "Re-aligning…" : reAlignMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(Capsule())
                .accessibilityLabel(reAlignMessage.isEmpty ? "Re-aligning" : reAlignMessage)
            } else {
                Button {
                    onCueEdit(.realignAll)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Re-align")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Re-align all lyrics to the audio")
            }

            // Adjust toggle: reveal the per-line alignment-fix row. Off keeps the card clean while
            // listening; on, the card pins to the target line and the transport moves the playhead
            // independently so you can set a line's true start. Entering Adjust seeds the target
            // with the line currently playing.
            Button {
                isAdjustingAlignment.toggle()
                adjustTargetIndex = isAdjustingAlignment ? activeIndex : nil
            } label: {
                let on = isAdjustingAlignment
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Adjust")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background((on ? Color.accentColor : Color.secondary).opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(cues.isEmpty)
            .accessibilityLabel(isAdjustingAlignment ? "Hide alignment adjust controls" : "Show alignment adjust controls")

            // Stem-listen toggle: swap playback between the original mix and the isolated vocal
            // stem (what the aligner hears). Shown only when a stem is cached for this audio — i.e.
            // after a Re-align — and hidden while a re-align is in flight (the stem may be mid-
            // regeneration). ReadView's onChange does the position-preserving source swap.
            if stemAvailable && isReAligning == false {
                Button {
                    isListeningToStem.wrappedValue.toggle()
                } label: {
                    let on = isListeningToStem.wrappedValue
                    HStack(spacing: 6) {
                        Image(systemName: on ? "waveform.circle.fill" : "waveform.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text(on ? "Vocals" : "Mix")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((on ? Color.accentColor : Color.secondary).opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListeningToStem.wrappedValue
                    ? "Playing isolated vocals. Tap to hear the original mix."
                    : "Playing original mix. Tap to hear the isolated vocals.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
    }

    // Per-line alignment editor (Adjust mode only): a draggable waveform for the targeted line plus
    // ▲▼ retarget, "+ shift rest" section ripple, and "Fix sweep" word timing. See WaveformLineEditor.
    // Not private: called from panel(geo:) in LyricsView.swift.
    func alignmentFixRow(index: Int) -> some View {
        let isRealigning = realigningCueIndex == index
        let anyRealigning = realigningCueIndex != nil
        let cue: SubtitleCue? = index < cues.count ? cues[index] : nil
        let isMusic = cue.map { SubtitleParser.isNonSpeechCue($0.text) } ?? true
        return VStack(spacing: 6) {
            // Target line + exactly what a commit does: its CURRENT start → the playhead it'll get.
            // The ▲▼ chevrons retarget without seeking (no hidden drag to discover).
            HStack(spacing: 8) {
                Button { adjustTargetIndex = max(0, (adjustTargetIndex ?? index) - 1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(index <= 0)
                .accessibilityLabel("Target the previous line")

                HStack(spacing: 5) {
                    Text("Line \(cue?.index ?? index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(displayText(for: index))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { adjustTargetIndex = min(cues.count - 1, (adjustTargetIndex ?? index) + 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(index >= cues.count - 1)
                .accessibilityLabel("Target the next line")
            }

            // Waveform editor: drag green START / red END onto the audio; touch elsewhere to scrub.
            Group {
                if let waveform, let cue, isMusic == false {
                    let lineDur = max(0, cue.endMs - cue.startMs)
                    let pad = max(1500, lineDur)
                    WaveformLineEditor(
                        envelope: waveform,
                        windowStartMs: max(0, cue.startMs - pad),
                        windowEndMs: min(durationMs, cue.endMs + pad),
                        lineID: index,
                        lineStartMs: cue.startMs,
                        lineEndMs: cue.endMs,
                        playheadMs: controller.currentTimeMs,
                        onSetStart: { ms in onCueEdit(.setStartToMs(cueIndex: index, ms: ms)) },
                        onSetEnd: { ms in onCueEdit(.setEndToMs(cueIndex: index, ms: ms)) },
                        onSeek: { ms in controller.seek(toMs: ms) }
                    )
                    .frame(height: 66)
                } else if isMusic {
                    Text("♪ instrumental — no boundaries to drag")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading waveform…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                }
            }

            // Below: audition, ripple a drifted section, or re-run word timing.
            HStack(spacing: 8) {
                Button {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                fixActionButton(title: "+ shift rest", system: "arrow.turn.down.right", tint: .systemBlue) {
                    onCueEdit(.setStartRipple(cueIndex: index))
                }
                .disabled(anyRealigning || isMusic)

                Spacer(minLength: 2)

                Button {
                    onCueEdit(.realignWord(cueIndex: index))
                } label: {
                    HStack(spacing: 3) {
                        if isRealigning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isRealigning ? "Fixing…" : "Fix sweep")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color(.systemOrange))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(.systemOrange).opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(anyRealigning || isMusic)
                .accessibilityLabel("Re-run word timing for this line")
            }
        }
        .opacity(anyRealigning ? 0.7 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.22))
        .task(id: "\(isAdjustingAlignment)|\(attachmentID?.uuidString ?? "")|\(isListeningToStem.wrappedValue)") {
            // Decode the waveform when Adjust opens or the Vocals/Mix toggle flips — isolated vocal
            // stem when "Vocals" is on and a stem is cached, otherwise the mix. Cached per (note,
            // source) so re-entering Adjust or toggling back doesn't redundantly re-decode.
            guard isAdjustingAlignment, let attachmentID,
                  let mixURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
            let useStem = isListeningToStem.wrappedValue && stemAvailable
            if waveform != nil, waveformNoteID == attachmentID, waveformIsStem == useStem { return }
            let src = useStem ? (VocalStemCache.stemWAVURL(for: mixURL) ?? mixURL) : mixURL
            let env = await WaveformEnvelope.load(url: src)
            if isAdjustingAlignment {
                waveform = env
                waveformNoteID = attachmentID
                waveformIsStem = useStem
            }
        }
    }
}
