# vast-h3-script

Vast.Ai / RunPod provisioning for **MiniMax H3** on rented GPUs, using the official
**`vastai/comfy:v0.30.0-cuda-12.9-py312`** base image. The instance installs weights
(parallel Xet download) + custom nodes, then the base image's supervisor launches
ComfyUI.

## What it does

`default.sh` (PROVISIONING_SCRIPT) runs at boot and:

1. Installs the **ComfyUI-MiniMax-H3-SPEED** custom node (`dev` branch) into
   `/ComfyUI/custom_nodes/`
2. Downloads the 4 needed safetensors from `Comfy-Org/MiniMax-H3` (~42.5 GB) via
   **Xet parallel chunk download** (hf_xet) into `/ComfyUI/models/`
3. Exits. The base image's supervisor launches ComfyUI with `COMFYUI_ARGS`.

Zero CivitAI checkpoint, zero other model downloads — only what's listed in `config.yaml`.

## Files

- `default.sh` — provisioning script (PROVISIONING_SCRIPT target)
- `hf_xet_download.sh` — standalone Xet downloader (`hf_xet_download <repo> <dir> <files...>`)
- `config.yaml` — declarative spec: models, modules, download engine, ComfyUI launch args
- `start.sh` — legacy standalone bootstrap, kept for reference only

## ComfyUI launch args

Set via `COMFYUI_ARGS` (Vast) — **must include `--lowvram`** or provisioning hangs
trying to load 42 GB of weights onto VRAM.

```
--disable-auto-launch --port 18188 --enable-cors-header --lowvram
```

## Env overrides

- `HF_TOKEN` — auth for gated repos (optional; public repos work without it)
- `HF_XET_SCRIPT_URL` — override source of `hf_xet_download.sh` (default: this repo)
- `HF_XET_NUM_CONCURRENT_RANGE_GETS` — Xet concurrency (default 64; higher on fat pipes)
- `CONFIG_URL` — fetch `config.yaml` from a URL instead of the baked-in copy

## Weights (from Comfy-Org/MiniMax-H3)

| File | Size | Destination |
|---|---|---|
| `diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 20.97 GB | models/diffusion_models |
| `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | 15.69 GB | models/text_encoders |
| `vae/minimax_h3_video_vae_fp16.safetensors` | 5.21 GB | models/vae |
| `vae/minimax_h3_audio_vae_fp32.safetensors` | 0.60 GB | models/vae |

## Usage (Vast.Ai)

```bash
vastai create instance <OFFER_ID> \
  --image vastai/comfy:v0.30.0-cuda-12.9-py312 \
  --env '-p 1111:1111 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8188:8188 \
    -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=*** -e JUPYTER_DIR=/ \
    -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="..." \
    -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/default.sh \
    -e COMFYUI_ARGS="--disable-auto-launch --port 18188 --enable-cors-header --lowvram"' \
  --onstart-cmd 'entrypoint.sh' \
  --disk 70 --jupyter --ssh --direct
```

## Notes

- Xet parallel download runs at ~600 MB/s after warmup (was 52 MB/s single-stream).
- `HF_XET_HIGH_PERFORMANCE=1` is set automatically — skips Xet's adaptive ramp.
- No SageAttention, no KJNodes — the SPEED node uses the raw diffusion model.
- Disk: t2v+i2v stack ≈ 50 GB used (base image 7 + weights 42.5). `--disk 70` fits.
