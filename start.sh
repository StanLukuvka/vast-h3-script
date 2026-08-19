#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Vast.Ai startup — MiniMax H3 (T4) · ComfyUI + KJNodes + SPEED (dev)
# ============================================================================
# Fast downloads via HF Xet sharded transfer.
# Safe to rerun: weights once-downloaded and venv once-built are skipped.
# ============================================================================

export HF_HOME="${HF_HOME:-/root/.cache/huggingface}"
export HF_XET_CACHE="${HF_XET_CACHE:-/root/.cache/huggingface/xet}"
export HF_HUB_DISABLE_UPDATE_CHECK=1
export PYTHONUNBUFFERED=1

# Xet parallel transfer tuning
# HIGH_PERFORMANCE floods the link — only turn on if Vast gives you > 500 Mbps.
# Adaptive concurrency (default) is safer on congested lines.
if [ "${HF_XET_HIGH_PERFORMANCE:-0}" = "1" ]; then
  export HF_XET_HIGH_PERFORMANCE=1
else
  unset HF_XET_HIGH_PERFORMANCE
fi

APP_ROOT="${APP_ROOT:-/opt/h3-t4}"
COMFY_DIR="${APP_ROOT}/ComfyUI"
MODELS_DIR="${COMFY_DIR}/models"
WEIGHTS_DIR="${APP_ROOT}/weights"

COMFY_REPO="${COMFY_REPO_URL:-https://github.com/Comfy-Org/ComfyUI.git}"
COMFY_REF="${COMFY_COMMIT:-9a9fdb10ed144ce760d9682cb247526ea23cc525}"

KJNODES_REPO="https://github.com/kijai/ComfyUI-KJNodes.git"
SPEED_REPO="https://github.com/StanLukuvka/ComfyUI-MiniMax-H3-SPEED.git"
SPEED_BRANCH="dev"

HF_REPO="Comfy-Org/MiniMax-H3"

# The 4 files that match the Kaggle notebook's REQUIRED_MODELS
WEIGHT_FILES=(
  "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
  "vae/minimax_h3_video_vae_fp16.safetensors"
  "vae/minimax_h3_audio_vae_fp32.safetensors"
)

# ============================================================================
# Logging
# ============================================================================
log()  { printf '\e[1;34m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\e[1;32m[OK]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*" >&2; exit 1; }

# ============================================================================
# Sanity: GPUs
# ============================================================================
log "=== Checking GPUs ==="
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found — is this a GPU instance?"
TF32_SET=0
if nvidia-smi --query-gpu=name,total_memory,compute_cap --format=csv,noheader,nounits 2>/dev/null | head -1; then
  ok "nvidia-smi responded"
else
  fail "nvidia-smi produced no output"
fi

# ============================================================================
# Tooling: curl, git, python3, uv/pip
# ============================================================================
log "=== Checking tooling ==="
for cmd in curl git python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing: $cmd"
done

if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env" 2>/dev/null || true
fi

# ============================================================================
# Fast parallel weight download via HF Xet
# ============================================================================
log "=== Weights: downloading via HF Xet sharded transfer ==="
mkdir -p "${WEIGHTS_DIR}"

# Install the hf CLI (ships huggingface_hub + hf_xet auto)
uv pip install --system --quiet "huggingface_hub[cli]>=0.32.0" hf-xet
hf --version >/dev/null 2>&1 || fail "hf CLI failed after install"

# Dry-run so the user can see what's already cached vs. what needs fetching
log "Dry-run:"
hf download "${HF_REPO}" \
  --include "$(printf '%s\n' "${WEIGHT_FILES[@]}" | paste -sd, -)" \
  --local-dir "${WEIGHTS_DIR}" \
  --local-dir-use-symlinks false \
  --dry-run 2>&1 | sed 's/^/  /'

log "Downloading (this is the slow step — Xet shards across many parallel TCP streams)..."
hf download "${HF_REPO}" \
  --include "$(printf '%s\n' "${WEIGHT_FILES[@]}" | paste -sd, -)" \
  --local-dir "${WEIGHTS_DIR}" \
  --local-dir-use-symlinks false \
  2>&1 | tail -20 || fail "weight download failed"

for f in "${WEIGHT_FILES[@]}"; do
  dest="${WEIGHTS_DIR}/${f}"
  [ -f "${dest}" ] || fail "missing after download: ${dest}"
  size=$(du -h "${dest}" | cut -f1)
  ok "weight ready: $(basename "${f}") (${size})"
done

# ============================================================================
# ComfyUI checkout (pinned SHA)
# ============================================================================
log "=== ComfyUI checkout ==="
mkdir -p "${APP_ROOT}"
if [ ! -d "${COMFY_DIR}/.git" ]; then
  git clone --filter=blob:none "${COMFY_REPO}" "${COMFY_DIR}"
fi
git -C "${COMFY_DIR}" fetch --depth=1 origin "${COMFY_REF}" 2>&1 | tail -1
git -C "${COMFY_DIR}" reset --hard FETCH_HEAD
git -C "${COMFY_DIR}" clean -fdx
git -C "${COMFY_DIR}" checkout --detach FETCH_HEAD
ok "ComfyUI @ ${COMFY_REF:0:12}"

# ============================================================================
# Custom nodes
# ============================================================================
log "=== Custom nodes ==="

KJNODES_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-KJNodes"
if [ ! -d "${KJNODES_DIR}/.git" ]; then
  git clone "${KJNODES_REPO}" "${KJNODES_DIR}"
else
  git -C "${KJNODES_DIR}" fetch --depth=1 origin
  git -C "${KJNODES_DIR}" reset --hard origin/HEAD
fi
ok "KJNodes $(git -C "${KJNODES_DIR}" rev-parse --short HEAD)"

SPEED_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-MiniMax-H3-SPEED"
if [ ! -d "${SPEED_DIR}/.git" ]; then
  git clone --branch "${SPEED_BRANCH}" --single-branch "${SPEED_REPO}" "${SPEED_DIR}"
else
  git -C "${SPEED_DIR}" fetch --depth=1 origin "${SPEED_BRANCH}"
  git -C "${SPEED_DIR}" reset --hard FETCH_HEAD
  git -C "${SPEED_DIR}" checkout "${SPEED_BRANCH}"
fi
ok "SPEED @ ${SPEED_DIR}:$(git -C "${SPEED_DIR}" rev-parse --short HEAD) (${SPEED_BRANCH})"

# ============================================================================
# Python venv + deps
# ============================================================================
log "=== Python environment ==="
VENV="${APP_ROOT}/venv"
mkdir -p "${VENV}"
if [ ! -x "${VENV}/bin/python" ]; then
  uv venv "${VENV}" --system-site-packages
fi
VE="${VENV}/bin/python"

log "Installing PyTorch 2.11.0 + CUDA 13.0 + xformers..."
uv pip install --python "${VE}" --quiet \
  --index-url https://download.pytorch.org/whl/cu130 \
  torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 xformers==0.0.35

log "Installing ComfyUI core..."
uv pip install --python "${VE}" --quiet -r "${COMFY_DIR}/requirements.txt"

log "Installing KJNodes deps..."
[ -f "${KJNODES_DIR}/requirements.txt" ] && \
  uv pip install --python "${VE}" --quiet -r "${KJNODES_DIR}/requirements.txt"

# ============================================================================
# Symlink weights into ComfyUI
# ============================================================================
log "=== Linking weights into ComfyUI ==="
for sub in diffusion_models text_encoders vae; do
  mkdir -p "${MODELS_DIR}/${sub}"
done

for f in "${WEIGHT_FILES[@]}"; do
  dest="${MODELS_DIR}/${f}"
  ln -sfn "${WEIGHTS_DIR}/${f}" "${dest}"
  [ -e "${dest}" ] || fail "link failed: ${dest}"
done
ok "all 4 weights linked"

# ============================================================================
# Write SPEED workflow (mirrors the Kaggle notebook exactly)
# ============================================================================
log "=== Writing workflow ==="
WF_DIR="${COMFY_DIR}/user/default/workflows"
mkdir -p "${WF_DIR}"

cat > "${WF_DIR}/minimax_h3_vast_speed.json" <<'JSON'
{
  "1":  { "class_type": "DiffusionModelLoaderKJ",  "inputs": { "model_name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors" }},
  "3":  { "class_type": "CLIPLoader",              "inputs": { "clip_name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", "type": "minimax" }},
  "4":  { "class_type": "VAELoader",               "inputs": { "vae_name": "minimax_h3_video_vae_fp16.safetensors" }},
  "4a": { "class_type": "VAELoader",               "inputs": { "vae_name": "minimax_h3_audio_vae_fp32.safetensors" }},
  "5":  { "class_type": "MiniMaxH3ImageToVideo",   "inputs": { "clip": ["3", 0], "vae": ["4", 0], "prompt": "a cinematic video of a cat walking on a beach at sunset, slow dolly shot", "width": 1344, "height": 768, "length": 124 }},
  "6":  { "class_type": "BasicScheduler",          "inputs": { "model": ["1", 0], "steps": 20, "denoise": 1.0 }},
  "7":  { "class_type": "RandomNoise",             "inputs": { "noise_seed": 42 }},
  "8":  { "class_type": "BasicGuider",             "inputs": { "model": ["1", 0], "conditioning": ["5", 0] }},
  "9":  { "class_type": "MiniMaxH3SPEEDSampler",   "inputs": { "noise": ["7", 0], "guider": ["8", 0], "sigmas": ["6", 0], "latent_image": ["5", 1], "preset": "half_then_full", "transition_mode": "explicit" }},
  "10": { "class_type": "VAEDecode",               "inputs": { "samples": ["9", 0], "vae": ["4", 0] }},
  "11": { "class_type": "VAEDecodeAudio",          "inputs": { "samples": ["9", 0], "vae": ["4a", 0] }},
  "12": { "class_type": "CreateVideo",             "inputs": { "images": ["10", 0], "fps": 24 }},
  "13": { "class_type": "SaveVideo",               "inputs": { "video": ["12", 0], "audio": ["11", 0], "filename_prefix": "minimax_h3_speed" }}
}
JSON
ok "workflow ${WF_DIR}/minimax_h3_vast_speed.json"

# ============================================================================
# Launch
# ============================================================================
PORT="${PORT:-8188}"
log "=== Starting ComfyUI ==="
echo ""
echo "=========================================="
echo " MiniMax H3 T4 — Vast.Ai"
echo " http://$(curl -fs --max-time 2 ifconfig.me 2>/dev/null || echo '<vast-ip>'):${PORT}"
echo " Workflow : minimax_h3_vast_speed.json"
echo " Weights  : ${WEIGHTS_DIR}"
echo " HF_XET_HIGH_PERFORMANCE=${HF_XET_HIGH_PERFORMANCE:-0} (1 = max parallel, needs >500 Mbps + 64 GB RAM)"
echo "=========================================="
echo ""

exec "${VE}" "${COMFY_DIR}/main.py" \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --cache-none \
  --preview-method none \
  --lowvram