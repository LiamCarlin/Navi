import json, sys, numpy as np, torch, torch.nn as nn, torch.nn.functional as F, torchaudio.compliance.kaldi as kaldi, soundfile as sf
import coremltools as ct
from load import load_state

class BasicBlock(nn.Module):
    expansion = 1
    def __init__(self, i, p, stride=1):
        super().__init__()
        self.conv1 = nn.Conv2d(i, p, 3, stride, 1, bias=False); self.bn1 = nn.BatchNorm2d(p)
        self.conv2 = nn.Conv2d(p, p, 3, 1, 1, bias=False); self.bn2 = nn.BatchNorm2d(p)
        self.shortcut = nn.Sequential()
        if stride != 1 or i != p:
            self.shortcut = nn.Sequential(nn.Conv2d(i, p, 1, stride, bias=False), nn.BatchNorm2d(p))
    def forward(self, x):
        out = F.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        return F.relu(out + self.shortcut(x))

class ResNet34(nn.Module):
    """WeSpeaker ResNet34 (Apache-2.0), two_emb_layer=False: (1, T, 80) CMN'd fbank → (1, 256)."""
    def __init__(self, m=32, feat=80, embed=256):
        super().__init__()
        self.in_planes = m
        self.conv1 = nn.Conv2d(1, m, 3, 1, 1, bias=False); self.bn1 = nn.BatchNorm2d(m)
        self.layer1 = self._make(m, 3, 1); self.layer2 = self._make(m * 2, 4, 2)
        self.layer3 = self._make(m * 4, 6, 2); self.layer4 = self._make(m * 8, 3, 2)
        self.seg_1 = nn.Linear(int(feat / 8) * m * 8 * 2, embed)
    def _make(self, p, n, stride):
        layers = []
        for s in [stride] + [1] * (n - 1):
            layers.append(BasicBlock(self.in_planes, p, s)); self.in_planes = p
        return nn.Sequential(*layers)
    def forward(self, fbank):
        x = fbank.permute(0, 2, 1).unsqueeze(1)
        x = F.relu(self.bn1(self.conv1(x)))
        x = self.layer4(self.layer3(self.layer2(self.layer1(x))))
        x = x.reshape(1, 2560, -1)          # (batch, channels × freq, frames): 256 × 10
        mean = x.mean(dim=-1)
        std = torch.std(x, dim=-1, unbiased=True)   # as pyannote's StatsPool
        return self.seg_1(torch.cat([mean, std], dim=-1))

def fbank(wav):
    w = torch.tensor(wav, dtype=torch.float32).unsqueeze(0) * (1 << 15)
    f = kaldi.fbank(w, num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0, sample_frequency=16000,
                    window_type="hamming", use_energy=False, round_to_power_of_two=True, snip_edges=True)
    return f - f.mean(dim=0, keepdim=True)

sd, _ = load_state()
model = ResNet34()
missing = model.load_state_dict({k[len("resnet."):]: v for k, v in sd.items() if k.startswith("resnet.")}, strict=False)
print("missing/unexpected:", missing.missing_keys, [k for k in missing.unexpected_keys if "num_batches" not in k])
model.eval()

wavs = {n: sf.read(f"{n}.wav")[0].astype(np.float32) for n in ["Samantha_1", "Samantha_2", "Daniel_1", "Daniel_2"]}
with torch.no_grad():
    ref = {n: model(fbank(w).unsqueeze(0))[0].numpy() for n, w in wavs.items()}
cos = lambda a, b: float(np.dot(a, b) / np.linalg.norm(a) / np.linalg.norm(b))
print("torch  same S:", round(cos(ref["Samantha_1"], ref["Samantha_2"]), 3), " same D:", round(cos(ref["Daniel_1"], ref["Daniel_2"]), 3),
      " S vs D:", round(cos(ref["Samantha_1"], ref["Daniel_1"]), 3), round(cos(ref["Samantha_2"], ref["Daniel_2"]), 3))

example = fbank(wavs["Samantha_1"]).unsqueeze(0)
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="fbank", shape=(1, ct.RangeDim(lower_bound=40, upper_bound=3000, default=200), 80))],
                     outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.macOS15,
                     compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
mlmodel.short_description = "Speaker embedding (WeSpeaker ResNet34-LM, VoxCeleb). Input: 80-bin Kaldi fbank, mean-normalized. Output: 256-d voiceprint."
mlmodel.author = "WeSpeaker (Apache-2.0); pretrained weights via pyannote/wespeaker-voxceleb-resnet34-LM (CC-BY-4.0)"
mlmodel.license = "Code Apache-2.0; weights CC-BY-4.0"
mlmodel.save("SpeakerEmbedding.mlpackage")
out = {n: mlmodel.predict({"fbank": fbank(w).unsqueeze(0).numpy()})["embedding"][0] for n, w in wavs.items()}
for n in out: print("coreml vs torch", n, round(cos(out[n], ref[n]), 5))
print("coreml same S:", round(cos(out["Samantha_1"], out["Samantha_2"]), 3), " S vs D:", round(cos(out["Samantha_1"], out["Daniel_1"]), 3))
# Fixtures for the Swift parity test: the first 1.5 s of one clip, its fbank and embedding.
w = wavs["Samantha_1"][: 24000]
fb = fbank(w)
with torch.no_grad(): e = model(fb.unsqueeze(0))[0].numpy()
json.dump({"samples": [round(float(x), 6) for x in w], "fbank_first_rows": fb[:3].numpy().round(4).tolist(),
           "frames": int(fb.shape[0]), "embedding": [round(float(x), 5) for x in e]}, open("fixture.json", "w"))
print("fixture frames", fb.shape)
