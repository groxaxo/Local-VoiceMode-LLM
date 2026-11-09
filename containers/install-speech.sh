#!/usr/bin/env bash
# Shared image build step. Never downloads model weights or starts inference.
set -Eeuo pipefail
service="${1:?Expected parakeet or supertonic}"
backend="${2:?Expected cpu or cuda}"
case "$backend" in cpu|cuda) ;; *) echo "Unsupported backend: $backend" >&2; exit 2 ;; esac

case "$service" in
  supertonic)
    git clone https://github.com/supertone-oss-archive/supertonic-py.git /opt/supertonic
    git -C /opt/supertonic checkout --detach "$SUPERTONIC_REVISION"
    python -m pip install '/opt/supertonic[serve]' 'numpy<2'
    ;;
  parakeet)
    git clone https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai.git /opt/parakeet
    git -C /opt/parakeet checkout --detach "$PARAKEET_REVISION"
    # VAD uses CPU Torch even in the CUDA ONNX inference image.
    python -m pip install --index-url https://download.pytorch.org/whl/cpu torch torchaudio
    sed -E '/^(onnxruntime(-gpu)?|tensorrt)/d' /opt/parakeet/requirements.txt > /tmp/speech-requirements.txt
    python -m pip install -r /tmp/speech-requirements.txt
    ;;
  *) echo "Unsupported service: $service" >&2; exit 2 ;;
esac

# CPU and GPU distributions share the onnxruntime import path; never retain both.
python -m pip uninstall -y onnxruntime onnxruntime-gpu
if [[ "$backend" == cpu ]]; then
  python -m pip install 'onnxruntime==1.23.2'
else
  python -m pip install 'onnxruntime-gpu[cuda,cudnn]==1.23.2'
fi
python -c 'import onnxruntime; assert onnxruntime.__version__ == "1.23.2"'
