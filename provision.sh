#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# MiniMax H3 provisioning for vastai/comfy:v0.30.0-cuda-12.9-py312
#
# Assumes the base image already provides:
#   - Python 3.12 (with pip)
#   - CUDA 12.9 runtime + drivers
#   - ComfyUI (typically at /ComfyUI)
#   - a system-wide huggingface_hub (>= 0.34)
#
# This script only:
#   1. Installs hf downloader (huggingface_hub[cli] 0.34)
#   2. Downloads 4 safetensors from Comfy-Org/MiniMax-H3
#   3. Clones KJNodes + ComfyUI-MiniMax-H3-SPEED (dev)
#   4. Symlinks weights into ComfyUI's models/
#   5. Writes SPEED workflow
#   6. Launches ComfyUI ——lowvram
#
# Env overrides:
#   USE_XET=1         sharded parallel Xet transfer (default ON)
#   HF_TOKEN          optional auth for gated models
#   APP_ROOT          weight install root
#   PORT              ComfyUI listen port
# ===========================================================================

export PYTHONUNBUFFERED=${PYTHONUNBUFFERED:-1}
export HF_HUB_DISABLE_UPDATE_CHECK=${HF_HUB_DISABLE_UPDATE_CHECK:-1}

USE_XET="${USE_XET:-1}"

export HF_XET_CACHE="${HF_XET_CACHE:-/root/.cache/huggingface/xet}"
# Activate high-performance Xet when requested
if [ "${USE_XET}" = "1" ]; then
  export HF_XET_HIGH_PERFORMANCE=1
fi

log()  { printf '\e[1;34m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\e[1;32m[OK]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*" >&2; exit 1; }

# --- ComfyUI location (predetermined layout of the base image) ---
: "${COMFY_DIR:=/ComfyUI}"
[ -d "${COMFY_DIR}" ] || fail "ComfyUI not found at ${COMFY_DIR}"

log "=== gpu check ==="
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found — requires GPU instance"
log "PyTorch: $(python3 -c 'import torch,sys; print(torch.__version__, "CUDA", torch.version.cuda)' 2>&1 || warn 'PyTorch import skipped')"

: "${APP_ROOT:=/opt/h3-t4}"
: "${PORT:=8188}"
WEIGHTS_DIR="${APP_ROOT}/weights"
MODELS_DIR="${COMFY_DIR}/models"
mkdir -p "${WEIGHTS_DIR}" "${MODELS_DIR}/diffusion_models" \
         "${MODELS_DIR}/text_encoders" "${MODELS_DIR}/vae"

HF_REPO="Comfy-Org/MiniMax-H3"
KJNODES_REPO="https://github.com/kijai/ComfyUI-KJNodes.git"
SPEED_REPO="https://github.com/StanLukuvka/ComfyUI-MiniMax-H3-SPEED.git"
WEIGHT_FILES=(
  "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
  "vae/minimax_h3_video_vae_fp16.safetensors"
  "vae/minimax_h3_audio_vae_fp32.safetensors"
)

# --- Ensure hf CLI ---
log "=== hf download ==="
if ! python3 -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('huggingface_hub') else 1)" 2>/dev/null; then
  pip install --quiet --no-cache-dir "huggingface_hub[cli]>=0.32.0"
fi
hf --version >/dev/null 2>&1 || fail "hf CLI unavailable"

# --- Fast parallel download: Xet-sharded when enabled ---
log "Downloading weights via hf download (USE_XET=${USE_XET})..."

# Dry-run first so user can see what's cached vs. needed
log "Dry-run:"
INCLUDE_FLAGS=()
for f in "${WEIGHT_FILES[@]}"; do
  INCLUDE_FLAGS+=("--include" "${f}")
done
TOKEN_FLAGS=()
[ -n "${HF_TOKEN:-}" ] && TOKEN_FLAGS=("--token" "${HF_TOKEN}")

hf download "${HF_REPO}" \
  "${INCLUDE_FLAGS[@]}" \
  "${TOKEN_FLAGS[@]}" \
  --local-dir "${WEIGHTS_DIR}" \
  --local-dir-use-symlinks false \
  --dry-run 2>&1 | sed 's/^/  /'

hf download "${HF_REPO}" \
  "${INCLUDE_FLAGS[@]}" \
  "${TOKEN_FLAGS[@]}" \
  --local-dir "${WEIGHTS_DIR}" \
  --local-dir-use-symlinks false \
  || fail "weight download failed"

for f in "${WEIGHT_FILES[@]}"; do
  [ -f "${WEIGHTS_DIR}/${f}" ] || fail "missing after download: ${WEIGHTS_DIR}/${f}"
  size=$(du -h "${WEIGHTS_DIR}/${f}" | cut -f1)
  ok "${f} (${size})"
done

# --- Symlink weights into ComfyUI's models tree ---
log "=== Symlinking weights into ComfyUI ==="
for sub in diffusion_models text_encoders vae; do mkdir -p "${MODELS_DIR}/${sub}"; done
for rel in "${WEIGHT_FILES[@]}"; do
  ln -sfn "${WEIGHTS_DIR}/${rel}" "${MODELS_DIR}/${rel}"
done
ok "all 4 weights linked"

# --- Custom nodes ---
log "=== Custom nodes ==="
KJNODES_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-KJNodes"
SPEED_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-MiniMax-H3-SPEED"

[ -d "${KJNODES_DIR}/.git" ] || git clone "$KJNODES_REPO" "${KJNODES_DIR}"
[ -d "${SPEED_DIR}/.git"   ] || git clone --branch dev --single-branch "$SPEED_REPO" "${SPEED_DIR}"

# Update existing clones
git -C "${KJNODES_DIR}" fetch --depth=1 origin >/dev/null 2>&1 || true
git -C "${KJNODES_DIR}" reset --hard origin/HEAD >/dev/null 2>&1 || true
git -C "${SPEED_DIR}" fetch --depth=1 origin dev >/dev/null 2>&1 || true
git -C "${SPEED_DIR}" reset --hard FETCH_HEAD >/dev/null 2>&1 || true

# Light deps from KJNodes if any are listed
if [ -f "${KJNODES_DIR}/requirements.txt" ]; then
  pip install --quiet --no-cache-dir -r "${KJNODES_DIR}/requirements.txt" || true
fi
ok "nodes ready"

# --- Write SPEED workflow ---
log "=== Writing SPEED workflow ==="
mkdir -p "${COMFY_DIR}/user/default/workflows"
cat > "${COMFY_DIR}/user/default/workflows/minimax_h3_vast_speed.json" <<'JSON'
{
  "1":  { "class_type": "DiffusionModelLoaderKJ", "inputs": { "model_name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors" }},
  "3":  { "class_type": "CLIPLoader",            "inputs": { "clip_name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", "type": "minimax" }},
  "4":  { "class_type": "VAELoader",             "inputs": { "vae_name": "minimax_h3_video_vae_fp16.safetensors" }},
  "4a": { "class_type": "VAELoader",             "inputs": { "vae_name": "minimax_h3_audio_vae_fp32.safetensors" }},
  "5":  { "class_type": "MiniMaxH3ImageToVideo", "inputs": { "clip": ["3", 0], "vae": ["4", 0], "prompt": "a cinematic video of a cat walking on a beach at sunset, slow dolly shot", "width": 1344, "height": 768, "length": 124 }},
  "6":  { "class_type": "BasicScheduler",        "inputs": { "model": ["1", 0], "steps": 20, "denoise": 1.0 }},
  "7":  { "class_type": "RandomNoise",           "inputs": { "noise_seed": 42 }},
  "8":  { "class_type": "BasicGuider",           "inputs": { "model": ["1", 0], "conditioning": ["5", 0] }},
  "9":  { "class_type": "MiniMaxH3SPEEDSampler", "inputs": { "noise": ["7", 0], "guider": ["8", 0], "sigmas": ["6", 0], "latent_image": ["5", 1], "preset": "half_then_full", "transition_mode": "explicit" }},
  "10": { "class_type": "VAEDecode",             "inputs": { "samples": ["9", 0], "vae": ["4", 0] }},
  "11": { "class_type": "VAEDecodeAudio",        "inputs": { "samples": ["9", 0], "vae": ["4a", 0] }},
  "12": { "class_type": "CreateVideo",           "inputs": { "images": ["10", 0], "fps": 24 }},
  "13": { "class_type": "SaveVideo",             "inputs": { "video": ["12", 0], "audio": ["11", 0], "filename_prefix": "minimax_h3_speed" }}
}
JSON
ok "workflow ready"

# --- Launch ComfyUI ---
log "=== Launching ComfyUI :${PORT} ==="
exec python3 "${COMFY_DIR}/main.py" \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --lowvram \
  --cache-none \
  --preview-method none
