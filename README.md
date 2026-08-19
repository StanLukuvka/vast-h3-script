# vast-h3-script

My Vast.Ai scripts for running MiniMax H3 on rented GPUs. Provisioning script designed
to run on the official **`vastai/comfy:v0.30.0-cuda-12.9-py312`** base image.

## provision.sh — primary script

Runs after the base image comes up. The base provides ComfyUI + CUDA 12.9 + PyTorch;
the script only adds the missing pieces:

1. `hf` CLI + **Xet sharded parallel download** of the 4 needed safetensors
   from `Comfy-Org/MiniMax-H3` (~42.5 GB)
2. Custom nodes: **KJNodes** + **ComfyUI-MiniMax-H3-SPEED** (`dev` branch)
3. Symlinks the weights into ComfyUI's `models/` tree
4. Writes a SPEED workflow (half-then-full sampler preset)
5. Launches ComfyUI with `--lowvram --cache-none --preview-method none`

### Env overrides

- `USE_XET=1` — Xet sharded transfer (default ON)
- `HF_TOKEN` — auth for gated repos
- `APP_ROOT` — weight install root (default `/opt/h3-t4`)
- `PORT` — ComfyUI port (default `8188`)

### Weights

| File | Size |
|---|---|
| `diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 20.97 GB |
| `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | 15.69 GB |
| `vae/minimax_h3_video_vae_fp16.safetensors` | 5.21 GB |
| `vae/minimax_h3_audio_vae_fp32.safetensors` | 0.60 GB |

### Usage

```
# On the Vast instance (e.g. via instance shell or on-start script):
bash provision.sh
```

### Notes

- `USE_XET=1` also exports `HF_XET_HIGH_PERFORMANCE=1` — needs a fat pipe; drop it
  on congested links via `USE_XET=0`.
- Custom nodes are force-updated to remote HEAD on every rerun (idempotent).
- No SageAttention patch node — the workflow uses the raw diffusion model.
- `start.sh` is the older standalone bootstrap (clones ComfyUI + venv from scratch);
  kept for reference when renting images without ComfyUI preinstalled.
