import Foundation

// Sing mode's phoneme timeline: the short-window model's per-frame log-probabilities stitched
// along song time. Every model run covers the newest 4 s of mic audio, but only its middle is
// trusted: frames near the front lack the audio before them and the model misses sounds there,
// and the last frames lack what comes after. Each run keeps the frames from 1.5 s in to 0.4 s
// before its end; runs every half second overlap, so the whole song is covered and a word of
// any length can be graded from frames that all had context.
final class SingEmissionTimeline {
    static let leftContextSec = 1.5
    static let rightContextSec = 0.4
    // How much song time is kept behind the newest frame: longer than any word plus its slack.
    private static let historySec = 12.0

    private(set) var frameSec: Double = 0
    // Song time up to which every frame is stitched in; nothing is gradeable past it.
    private(set) var coveredUntilSec = -Double.infinity
    // Rows keyed by frame index on the song-time grid (song sec / frameSec), with how much audio
    // stood before each frame in the run it came from; a better-placed run's row replaces it.
    private var rows: [Int: [Float]] = [:]
    private var context: [Int: Double] = [:]
    private var classes = 0

    // Song time of the earliest stitched frame, or nil while empty.
    var earliestSec: Double? { rows.keys.min().map { Double($0) * frameSec } }

    // Forgets everything, after a pause or a jump, so old frames can't be graded at new song times.
    func reset() {
        rows.removeAll(keepingCapacity: true)
        context.removeAll(keepingCapacity: true)
        coveredUntilSec = -.infinity
    }

    // Stitches one model run in. `windowStartSec` is the song time of the run's first frame and
    // `audioStartSec` where its real audio begins (later than the window start right after a
    // reset, when the front is zero padding; those runs keep frames from the audio's start,
    // since there is no earlier audio any run could add).
    func merge(logProbs: [Float], frames: Int, frameSec: Double, classes: Int,
               windowStartSec: Double, windowSec: Double, audioStartSec: Double) {
        if self.frameSec != frameSec || self.classes != classes {
            reset()
            self.frameSec = frameSec
            self.classes = classes
        }
        let isFull = audioStartSec <= windowStartSec + frameSec
        let keepFrom = isFull ? windowStartSec + Self.leftContextSec : audioStartSec
        let keepTo = windowStartSec + windowSec - Self.rightContextSec
        for f in 0..<frames {
            let t = windowStartSec + Double(f) * frameSec
            guard t >= keepFrom, t <= keepTo else { continue }
            let key = Int((t / frameSec).rounded())
            let before = min(t - audioStartSec, Self.leftContextSec)
            if let existing = context[key], existing > before { continue }
            rows[key] = Array(logProbs[(f * classes)..<((f + 1) * classes)])
            context[key] = before
        }
        coveredUntilSec = max(coveredUntilSec, keepTo)
        let oldest = Int(((coveredUntilSec - Self.historySec) / frameSec).rounded(.down))
        for key in rows.keys where key < oldest {
            rows[key] = nil
            context[key] = nil
        }
    }

    // Row-major [frames × classes] log-probabilities for song time [fromSec, toSec], clipped to
    // what is stitched, with the song time of its first frame; nil when nothing falls inside.
    func slice(fromSec: Double, toSec: Double) -> (values: [Float], frames: Int, startSec: Double)? {
        guard frameSec > 0, let minKey = rows.keys.min(), let maxKey = rows.keys.max() else { return nil }
        let lo = max(minKey, Int((fromSec / frameSec).rounded(.up)))
        let hi = min(maxKey, Int((toSec / frameSec).rounded(.down)))
        guard hi >= lo else { return nil }
        var values: [Float] = []
        values.reserveCapacity((hi - lo + 1) * classes)
        var frames = 0
        // A missing row (a run that never landed) is skipped; the gap is a frame or two at most.
        for key in lo...hi {
            guard let row = rows[key] else { continue }
            values += row
            frames += 1
        }
        return frames > 0 ? (values, frames, Double(lo) * frameSec) : nil
    }
}
