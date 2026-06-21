# HTDemucs raw-audio -> (vocals spectrogram, vocals time-branch). STFT + core run in CoreML
# (both proven to convert); Swift does the cheap iSTFT overlap-add. Validated end-to-end.
import math, numpy as np, torch, torch.nn as nn, torch.nn.functional as F, coremltools as ct
from einops import rearrange
from demucs.pretrained import get_model
torch.backends.mha.set_fastpath_enabled(False)
m = get_model("htdemucs").models[0].eval()
SEG=int(m.segment*m.samplerate); N,H,K=m.nfft,m.hop_length,m.nfft//2+1
S=len(m.sources); VOC=m.sources.index("vocals"); WIN=torch.hann_window(N)
print(f"SEG={SEG} T_frames={math.ceil(SEG/H)} vocals={VOC}")

def stft_w():
    n=torch.arange(N,dtype=torch.float64);k=torch.arange(K,dtype=torch.float64)
    ang=2*math.pi*torch.outer(k,n)/N
    cos=(torch.cos(ang)*WIN.double()/math.sqrt(N)).float();sin=(-torch.sin(ang)*WIN.double()/math.sqrt(N)).float()
    return torch.cat([cos,sin],0).unsqueeze(1)

class HTDemucsSpec(nn.Module):
    def __init__(self, mm): super().__init__(); self.m=mm; self.register_buffer("sw", stft_w())
    def forward(self, mix):
        B,C,L=mix.shape; le=math.ceil(L/H); pad=H//2*3
        x=F.pad(mix,(pad,pad+le*H-L),mode="reflect"); x=F.pad(x,(N//2,N//2),mode="reflect")
        z=F.conv1d(x.reshape(B*C,1,-1), self.sw, stride=H)
        re=z[:,:K].reshape(B,C,K,-1)[:,:,:-1,2:2+le]; im=z[:,K:].reshape(B,C,K,-1)[:,:,:-1,2:2+le]
        Fq,T=re.shape[-2],re.shape[-1]
        mag=torch.stack([re,im],2).reshape(B,C*2,Fq,T)
        x=mag; mean=x.mean((1,2,3),keepdim=True); std=x.std((1,2,3),keepdim=True); x=(x-mean)/(1e-5+std)
        xt=mix; meant=xt.mean((1,2),keepdim=True); stdt=xt.std((1,2),keepdim=True); xt=(xt-meant)/(1e-5+stdt)
        mm=self.m; saved=[];saved_t=[];lengths=[];lengths_t=[]
        for idx,enc in enumerate(mm.encoder):
            lengths.append(x.shape[-1]); inject=None
            if idx<len(mm.tencoder):
                lengths_t.append(xt.shape[-1]); tenc=mm.tencoder[idx]; xt=tenc(xt)
                if not tenc.empty: saved_t.append(xt)
                else: inject=xt
            x=enc(x,inject)
            if idx==0 and mm.freq_emb is not None:
                frs=torch.arange(x.shape[-2],device=x.device)
                x=x+mm.freq_emb_scale*mm.freq_emb(frs).t()[None,:,:,None].expand_as(x)
            saved.append(x)
        if mm.crosstransformer:
            if mm.bottom_channels:
                b,c,f,t=x.shape; x=rearrange(x,"b c f t-> b c (f t)"); x=mm.channel_upsampler(x)
                x=rearrange(x,"b c (f t)-> b c f t",f=f); xt=mm.channel_upsampler_t(xt)
            x,xt=mm.crosstransformer(x,xt)
            if mm.bottom_channels:
                x=rearrange(x,"b c f t-> b c (f t)"); x=mm.channel_downsampler(x)
                x=rearrange(x,"b c (f t)-> b c f t",f=f); xt=mm.channel_downsampler_t(xt)
        for idx,dec in enumerate(mm.decoder):
            skip=saved.pop(-1); x,pre=dec(x,skip,lengths.pop(-1)); off=mm.depth-len(mm.tdecoder)
            if idx>=off:
                tdec=mm.tdecoder[idx-off]; lt=lengths_t.pop(-1)
                if tdec.empty: pre=pre[:,:,0]; xt,_=tdec(pre,None,lt)
                else: skip=saved_t.pop(-1); xt,_=tdec(xt,skip,lt)
        x=x.view(B,S,-1,Fq,T); x=x*std[:,None]+mean[:,None]
        xt=xt.view(B,S,-1,L); xt=xt*stdt[:,None]+meant[:,None]
        return x[:,VOC], xt[:,VOC]              # vocals_spec [1,4,2048,T], vocals_time [1,2,L]

w=HTDemucsSpec(m).eval(); mix=torch.randn(1,2,SEG)
with torch.no_grad():
    rs,rt=w(mix)
    # torch reference for the same two tensors
    ref_full=m(mix);
    tr=torch.jit.trace(w,mix)
ml=ct.convert(tr, inputs=[ct.TensorType(name="mix",shape=(1,2,SEG))],
              outputs=[ct.TensorType(name="vocals_spec"),ct.TensorType(name="vocals_time")],
              minimum_deployment_target=ct.target.iOS16, convert_to="mlprogram",
              compute_precision=ct.precision.FLOAT32)
ml.author="Meta Research (Demucs)"; ml.license="MIT License"
ml.save("HTDemucsSpec_F32.mlpackage")
out=ct.models.MLModel("HTDemucsSpec_F32.mlpackage", compute_units=ct.ComputeUnit.ALL).predict({"mix":mix.numpy().astype(np.float32)})
es=float(np.abs(np.asarray(out["vocals_spec"])-rs.numpy()).max())
et=float(np.abs(np.asarray(out["vocals_time"])-rt.numpy()).max())
print(f"CoreML vocals_spec max|Δ|={es:.3e} | vocals_time max|Δ|={et:.3e}  {'OK' if max(es,et)<1e-2 else 'BROKEN'}")
