// AudioFilters.swift
// Ports stable-ts's voice_freq_filter (stable_whisper/audio/utils.py) to
// Swift. stable-ts cascades two biquads — a lowpass at 5 kHz and a highpass
// at 200 Hz — so that only frequencies where human voice lives remain
// prominent. We apply this only to the audio stream passed to the silence
// detector (matching the stable_whisper pipeline when only_voice_freq is
// enabled), not to the audio fed into whisper.cpp inference.
//
// The biquad coefficient formulas match torchaudio.functional.lowpass_biquad
// and highpass_biquad, which stable-ts calls directly. Q defaults to 0.707
// (Butterworth) in torchaudio.

import Foundation

// Direct-form biquad coefficients with a0 already normalized to 1.
fileprivate struct BiquadCoeffs {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    // Lowpass biquad matching torchaudio.functional.lowpass_biquad.
    static func lowpass(cutoff f0: Float, sampleRate sr: Float, q: Float = 0.707) -> BiquadCoeffs {
        let w0 = 2 * Float.pi * f0 / sr
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0 = (1 - cosw0) / 2
        let b1 = 1 - cosw0
        let b2 = (1 - cosw0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw0
        let a2 = 1 - alpha
        return BiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    // Highpass biquad matching torchaudio.functional.highpass_biquad.
    static func highpass(cutoff f0: Float, sampleRate sr: Float, q: Float = 0.707) -> BiquadCoeffs {
        let w0 = 2 * Float.pi * f0 / sr
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0 = (1 + cosw0) / 2
        let b1 = -(1 + cosw0)
        let b2 = (1 + cosw0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw0
        let a2 = 1 - alpha
        return BiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

// Applies a biquad filter in place using direct-form I.
// The recursive state (x1/x2/y1/y2) is kept local so each call is
// independent — suitable for one-shot processing of a full frame buffer.
fileprivate func applyBiquadInPlace(_ frames: inout [Float], _ c: BiquadCoeffs) {
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0
    for i in 0..<frames.count {
        let x0 = frames[i]
        let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        frames[i] = y0
        x2 = x1; x1 = x0
        y2 = y1; y1 = y0
    }
}

// Band-passes audio to the vocal range (default 200–5000 Hz) using cascaded
// single-biquad lowpass + highpass filters, identical in structure to
// stable_whisper/audio/utils.py :: voice_freq_filter. Returns a new buffer;
// the input is unchanged.
//
// Intended for pre-processing audio that feeds the NonSpeechDetector — it
// knocks out bass, kick drum, and cymbal energy so that vocal silence
// (instrumental-only passages) registers as quiet rather than loud.
func voiceFreqFilter(
    frames: [Float],
    sampleRate: Int = 16_000,
    lowerHz: Float = 200,
    upperHz: Float = 5_000
) -> [Float] {
    guard frames.isEmpty == false else { return frames }
    let sr = Float(sampleRate)
    var out = frames
    applyBiquadInPlace(&out, .lowpass(cutoff: upperHz, sampleRate: sr))
    applyBiquadInPlace(&out, .highpass(cutoff: lowerHz, sampleRate: sr))
    return out
}
