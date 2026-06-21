# Real-valued iSTFT (no complex) matching torch.istft, for the audio->audio CoreML export.
import math
import torch
import torch.nn.functional as F

N = 4096; H = 1024; K = N // 2 + 1
WIN = torch.hann_window(N)

# ---- forward (from stft_parity, to make a valid spectrum to invert) ----
def real_stft(x):
    n = torch.arange(N, dtype=torch.float64); k = torch.arange(K, dtype=torch.float64)
    ang = (2*math.pi*torch.outer(k, n)/N)
    COS = torch.cos(ang).float(); SIN = torch.sin(ang).float()
    xp = F.pad(x, (N//2, N//2), mode="reflect")
    wf = xp.unfold(-1, N, H) * WIN
    return ((wf @ COS.t())/math.sqrt(N)).transpose(1,2), (-(wf @ SIN.t())/math.sqrt(N)).transpose(1,2)

# ---- inverse DFT basis: y[n] = (1/N)[X0 + 2*sum_{1..N/2-1}(Re cos - Im sin) + X_{N/2} cos(pi n)] ----
def inv_basis():
    n = torch.arange(N, dtype=torch.float64); k = torch.arange(K, dtype=torch.float64)
    ang = 2*math.pi*torch.outer(k, n)/N
    c = torch.full((K,), 2.0, dtype=torch.float64); c[0] = 1.0; c[N//2] = 1.0
    icos = ((c[:, None]/N) * torch.cos(ang)).float()    # [K, N]
    isin = (-(c[:, None]/N) * torch.sin(ang)).float()
    return icos, isin
ICOS, ISIN = inv_basis()

def real_istft(real, imag, length):                     # real,imag: [B,K,F]
    r = real.transpose(1, 2); i = imag.transpose(1, 2)  # [B,F,K]
    yf = (r @ ICOS + i @ ISIN) * math.sqrt(N)           # [B,F,N]  (sqrt(N): undo normalized fwd)
    yfw = (yf * WIN).transpose(1, 2)                    # [B,N,F]
    Fr = yfw.shape[-1]; out_len = (Fr - 1) * H + N
    out = F.fold(yfw, (1, out_len), (1, N), stride=(1, H))[:, 0, 0, :]            # overlap-add
    w2 = (WIN * WIN).view(1, N, 1).expand(1, N, Fr)
    wsum = F.fold(w2, (1, out_len), (1, N), stride=(1, H))[:, 0, 0, :]
    out = out / (wsum + 1e-8)
    return out[:, N//2 : N//2 + length]                 # remove center pad, crop

torch.manual_seed(0)
x = torch.randn(1, 343980)
zr, zi = real_stft(x)
z = torch.complex(zr, zi)
xt = torch.istft(z, N, H, window=WIN, win_length=N, normalized=True, length=x.shape[-1], center=True)
xm = real_istft(zr, zi, x.shape[-1])
print(f"iSTFT vs torch.istft max|Δ| = {(xm - xt).abs().max().item():.3e}")
print(f"round-trip (istft(stft(x)) vs x) max|Δ| = {(xm - x).abs().max().item():.3e}")
