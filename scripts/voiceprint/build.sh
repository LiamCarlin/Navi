#!/bin/zsh
# Rebuilds Navi/Resources/SpeakerEmbedding.mlpackage — the speaker model behind
# "Only my voice" (Voice/VoicePrint.swift) — and the test fixture
# NaviTests/Fixtures/voice_fixture.json.
#
#   scripts/voiceprint/build.sh
#
# Source: pyannote/wespeaker-voxceleb-resnet34-LM (WeSpeaker ResNet34, VoxCeleb; weights
# CC-BY-4.0, architecture Apache-2.0 — credited in About → Acknowledgements). convert.py
# re-implements the ResNet34 (no pyannote runtime needed), checks the Core ML model
# against PyTorch on two `say` voices, quant.py stores the weights as int8 (cosine 0.999
# with the float model, 6.4 MB), fixture.py writes torchaudio's fbank + PyTorch's embedding
# for VoiceFbankTests/VoicePrintTests. Needs uv and network access (Hugging Face).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/navi-voiceprint"
mkdir -p "$WORK" && cd "$WORK"
cp "$ROOT"/scripts/voiceprint/*.py .
[[ -d .venv ]] || uv venv -q -p 3.12 .venv
VIRTUAL_ENV="$WORK/.venv" uv pip install -q torch torchaudio coremltools numpy soundfile
base=https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM/resolve/main
[[ -f pytorch_model.bin ]] || curl -sSL -o pytorch_model.bin "$base/pytorch_model.bin"
for v in Samantha Daniel; do
  say -v $v -o ${v}_1.aiff "Open Chrome and search for the weather in Boston tomorrow morning"
  say -v $v -o ${v}_2.aiff "Text my mom that I am running about ten minutes late tonight"
  for i in 1 2; do afconvert -f WAVE -d LEI16@16000 -c 1 ${v}_$i.aiff ${v}_$i.wav; done
done
.venv/bin/python convert.py
.venv/bin/python quant.py
.venv/bin/python fixture.py
rm -rf "$ROOT/Navi/Resources/SpeakerEmbedding.mlpackage"
cp -R SpeakerEmbedding8.mlpackage "$ROOT/Navi/Resources/SpeakerEmbedding.mlpackage"
cp voice_fixture.json "$ROOT/NaviTests/Fixtures/voice_fixture.json"
echo "Navi/Resources/SpeakerEmbedding.mlpackage and NaviTests/Fixtures/voice_fixture.json updated"
