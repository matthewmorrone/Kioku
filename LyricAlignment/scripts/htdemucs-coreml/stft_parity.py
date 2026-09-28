# Real-valued STFT/iSTFT (no complex tensors) that must match torch.stft/istft exactly,
# so the whole HTDemucs can be exported audio->audio to CoreML. Verifies parity vs torch.
import math
import torch
import torch.nn.functional as F

N = 4096       # n_fft
H = 1024       # hop
K = N // 2 + 1 # 2049 freq bins

def dft_basis():
    n = torch.arange(N, dtype=torch.float64)
    k = torch.arange(K, dtype=torch.float64)
    ang = 2 * math.pi * torch.outer(k, n) / N      # [K, N]
    return torch.cos(ang).float(), torch.sin(ang).float()

COS, SIN = dft_basis()
WIN = torch.hann_window(N)                          # periodic=True (stft default)

def real_stft(x):                                   # x: [B, L] -> (real, imag) [B, K, F]
    pad = N // 2
    xp = F.pad(x, (pad, pad), mode="reflect")       # center=True padding
    frames = xp.unfold(-1, N, H)                    # [B, F, N]
    wf = frames * WIN                               # window each frame
    real = (wf @ COS.t()) / math.sqrt(N)            # normalized=True -> /sqrt(N)
    imag = -(wf @ SIN.t()) / math.sqrt(N)
    return real.transpose(1, 2), imag.transpose(1, 2)

# ---- parity vs torch.stft ----
torch.manual_seed(0)
x = torch.randn(1, 343980)
zr, zi = real_stft(x)
z = torch.stft(x, N, H, window=WIN, win_length=N, normalized=True,
               center=True, return_complex=True, pad_mode="reflect")
print(f"torch z shape {tuple(z.shape)}  mine {tuple(zr.shape)}")
F_ = min(z.shape[-1], zr.shape[-1])
print(f"STFT real max|Δ| = {(zr[...,:F_] - z.real[...,:F_]).abs().max().item():.3e}")
print(f"STFT imag max|Δ| = {(zi[...,:F_] - z.imag[...,:F_]).abs().max().item():.3e}")
