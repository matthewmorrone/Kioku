import SwiftUI

// Advanced settings — segmentation engine/tuning, debug overlays, and the dev bridge — pushed
// off the main Settings screen via the "Advanced" link. Split out of SettingsView.swift to keep
// that file under the line-count guardrail; shares the same @State/@AppStorage as the main file
// (see SettingsView.swift for the properties this reads/writes — several are also read by
// SettingsPreviewRenderer in `body`, which is why they're internal rather than private).
extension SettingsView {
    @ViewBuilder
    var advancedSettings: some View {
        // MARK: Segmentation — engine, then the two tuning chip-editors.
        Section {
            Picker("Engine", selection: $segmenterBackend) {
                ForEach(SegmenterBackend.allCases, id: \.rawValue) { backend in
                    Text(backend.displayName).tag(backend.rawValue)
                }
            }

            if segmenterBackend == SegmenterBackend.mecab.rawValue {
                Picker("Dictionary", selection: $mecabDictionary) {
                    ForEach(MeCabDictionary.allCases, id: \.rawValue) { dict in
                        Text(dict.displayName).tag(dict.rawValue)
                    }
                }
            }

            if segmenterBackend == SegmenterBackend.trie.rawValue {
                Toggle("Global longest-match (experimental)", isOn: Binding(
                    get: { segmentationStrategy == .globalLongestMatch },
                    set: { segmentationStrategy = $0 ? .globalLongestMatch : .localLongestMatch }
                ))
            }
        } header: {
            Text("Segmentation")
        }

        Section {
            ParticleTagEditor(tags: particlesBinding)
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    ParticleSettings.reset()
                    particlesRaw = ParticleSettings.defaultRawValue
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        } header: {
            Text("Allowed Particles")
        }

        Section {
            ParticleTagEditor(tags: demotionsBinding)
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    SegmentationDemotions.reset()
                    demotionsRaw = SegmentationDemotions.defaultRawValue
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        } header: {
            Text("Segmentation Demotions")
        }

        #if DEBUG
        // MARK: Debug overlays — hidden in release builds.
        Section {
            Toggle("Pixel Ruler", isOn: $debugPixelRuler)
            Toggle("Furigana Rects", isOn: $debugFuriganaRects)
            Toggle("Headword Rects", isOn: $debugHeadwordRects)
            Toggle("Envelope Rects", isOn: $debugEnvelopeRects)
            Toggle("Headword Line Bands", isOn: $debugHeadwordLineBands)
            Toggle("Furigana Line Bands", isOn: $debugFuriganaLineBands)
            Toggle("Headword Line Numbers (L#)", isOn: $debugHeadwordLineNumbers)
            Toggle("Ruby Line Numbers (R#)", isOn: $debugRubyLineNumbers)
            Toggle("Headword Bisectors", isOn: $debugBisectorHeadword)
            Toggle("Furigana Bisectors", isOn: $debugBisectorFurigana)
            Toggle("Left Inset Guide", isOn: $debugLeftInsetGuide)
            Toggle("Karaoke HUD", isOn: $debugKaraokeHUD)
        } header: {
            Text("Debug Overlays")
        }
        #endif

        // Foreground-only bridge isn't useful enough yet to surface in Settings.
        // BridgeSettingsSection(bridgeServer: bridgeServer)
    }

    // Bridges AppStorage raw string to the sorted particle list expected by ParticleTagEditor.
    var particlesBinding: Binding<[String]> {
        Binding(
            get: { ParticleSettings.decodeList(from: particlesRaw) },
            set: { particlesRaw = ParticleSettings.encodeList($0) }
        )
    }

    // Bridges AppStorage raw string to the demotion list expected by ParticleTagEditor.
    var demotionsBinding: Binding<[String]> {
        Binding(
            get: { SegmentationDemotions.decodeList(from: demotionsRaw) },
            set: { demotionsRaw = SegmentationDemotions.encodeList($0) }
        )
    }
}
