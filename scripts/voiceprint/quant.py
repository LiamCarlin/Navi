import numpy as np, soundfile as sf, coremltools as ct, torch
import coremltools.optimize.coreml as cto
from convert import fbank, model, wavs, ref, cos
m = ct.models.MLModel("SpeakerEmbedding.mlpackage")
cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))
q = cto.linear_quantize_weights(m, config=cfg)
q.save("SpeakerEmbedding8.mlpackage")
for n, w in wavs.items():
    e = q.predict({"fbank": fbank(w).unsqueeze(0).numpy()})["embedding"][0]
    print("int8 vs torch", n, round(cos(e, ref[n]), 5))
