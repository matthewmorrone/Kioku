import Foundation

// The last few seconds of the singer's microphone audio at 16 kHz mono, written by the audio
// tap thread and read by Sing mode's scoring loop. Remembers the host time its newest sample was
// captured at, which is how the scorer pins the audio to song time.
nonisolated final class SingAudioRing: @unchecked Sendable {
    static let sampleRate = 16_000
    private let capacity = 16_000 * 6
    private var samples: [Float] = []
    private var newestHostSec: Double = 0
    private let lock = NSLock()

    // Appends freshly captured samples; `newestHostSec` is the capture time of the last one.
    func append(_ chunk: [Float], newestHostSec: Double) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        self.newestHostSec = newestHostSec
    }

    // The newest `count` samples (fewer right after a reset) and the capture time of the last one.
    func snapshot(count: Int) -> (samples: [Float], newestHostSec: Double) {
        lock.lock(); defer { lock.unlock() }
        return (Array(samples.suffix(count)), newestHostSec)
    }

    // Drops everything, after a pause or a seek, so old audio can't be pinned to the new song time.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        newestHostSec = 0
    }
}
