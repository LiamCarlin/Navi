import base64, json, numpy as np, torch
from convert import fbank, model, wavs
w = wavs["Samantha_1"][:24000]
pcm = np.round(w * 32768).astype("<i2")
w = pcm.astype(np.float32) / 32768
fb = fbank(w)
with torch.no_grad(): e = model(fb.unsqueeze(0))[0].numpy()
raw = torch.tensor(w).unsqueeze(0) * 32768
import torchaudio.compliance.kaldi as kaldi
rawfb = kaldi.fbank(raw, num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0, sample_frequency=16000, window_type="hamming", use_energy=False)
json.dump({"pcm16": base64.b64encode(pcm.tobytes()).decode(), "frames": int(fb.shape[0]),
           "raw_rows": rawfb[[0, 1, 70, 147]].numpy().round(4).tolist(),
           "cmn_frame_sums": fb.sum(dim=1).numpy().round(4).tolist(),
           "embedding": [round(float(x), 5) for x in e],
           "clips": {n: base64.b64encode(np.round(wavs[n][8000:40000] * 32768).astype("<i2").tobytes()).decode()
                     for n in ["Samantha_1", "Samantha_2", "Daniel_1", "Daniel_2"]}}, open("voice_fixture.json", "w"))
print(fb.shape, len(open("voice_fixture.json").read()))
