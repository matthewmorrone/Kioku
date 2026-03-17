import SwiftUI

// Renders a toggle list for managing which single-kana morphemes may appear as standalone segments in lattice paths.
struct ParticleSettingsView: View {
    @State private var allowed: Set<String> = ParticleSettings.allowed()

    private var allParticles: [String] { ParticleSettings.defaults }

    var body: some View {
        Form {
            // Toggles each particle in the default list between allowed and excluded.
            Section {
                ForEach(allParticles, id: \.self) { particle in
                    Toggle(particle, isOn: Binding(
                        get: { allowed.contains(particle) },
                        set: { isOn in
                            if isOn {
                                allowed.insert(particle)
                            } else {
                                allowed.remove(particle)
                            }
                            ParticleSettings.save(allowed)
                        }
                    ))
                }
            } header: {
                Text("Allowed Standalone Kana")
            } footer: {
                Text("Single-kana segments not in this list are treated as bound morphemes and filtered out of segmentation path display.")
            }

            // Restores the full default set from common_particles.json.
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    ParticleSettings.reset()
                    allowed = ParticleSettings.allowed()
                }
            }
        }
        .navigationTitle("Particles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
