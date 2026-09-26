#!/usr/bin/env python3
"""Runs the phone's CoreML MMS aligner model on the Mac over a 16 kHz mono f32 file, with the app's
window stitching (MMSEmissions: 32 s windows, 2 s lead, 1 s tail trim), and writes the emission
matrix the replay reads. Lets an audio change (a different stem encoding, a different isolator) be
tested without the phone: decode it, run this, replay.

Usage: stem_emissions.py <in 16k mono f32> <out emissions f32> [--model work/MMSForcedAligner.mlmodelc]
Needs coremltools. The model is copied off the phone (Documents/MMSForcedAligner.mlmodelc, ~600 MB);
see the README.
"""
import os, sys
import numpy as np
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))
SR, WIN, WINDOW_SEC, LEAD_SEC, TAIL_SEC = 16000, 512000, 32.0, 2.0, 1.0


def emissions(model, w):
    """Stitched log-probabilities [frames × 29] for the whole signal."""
    total = len(w) / SR
    rows, t = [], 0.0
    while t < total - 1e-6:
        a = max(0.0, t - LEAD_SEC)
        x = np.zeros(WIN, np.float32); seg = w[int(a * SR):int(a * SR) + WIN]; x[:len(seg)] = seg
        lp = np.asarray(model.predict({'audio': x[None]})['logprobs'])[0].astype(np.float32)
        fs = WINDOW_SEC / lp.shape[0]
        lead = int(round((t - a) / fs)); last = a + WINDOW_SEC >= total
        keep = min(int(round(min(WINDOW_SEC - (t - a) - (0 if last else TAIL_SEC), total - t) / fs)), lp.shape[0] - lead)
        if keep <= 0:
            break
        rows.append(lp[lead:lead + keep]); t += keep * fs
    return np.concatenate(rows)


def main():
    args = sys.argv[1:]
    path = os.path.join(HERE, 'work', 'MMSForcedAligner.mlmodelc')
    if '--model' in args:
        i = args.index('--model'); path = args[i + 1]; del args[i:i + 2]
    model = ct.models.CompiledMLModel(path, compute_units=ct.ComputeUnit.CPU_ONLY)
    emissions(model, np.fromfile(args[0], dtype=np.float32)).astype(np.float32).tofile(args[1])


if __name__ == '__main__':
    main()
