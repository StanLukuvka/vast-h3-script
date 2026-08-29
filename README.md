# vast-h3-script

Vast.Ai / RunPod provisioning for **MiniMax H3** on rented GPUs, using the official
**`vastai/comfy:v0.32.0-cuda-12.9-py312`** base image. The instance installs weights
(Xet parallel chunk download or HF Hub, per config) + custom nodes, then the base
image's supervisor launches ComfyUI.

## What it does

`default.sh` (PROVISIONING_SCRIPT) runs at boot and:

1. Loads `config.json` (URL, file path, or inline JSON via `PROVISIONING_CONFIG`)
2. Installs custom nodes from `config.json:modules[]` (default:
   `ComfyUI-MiniMax-H3-SPEED@dev`)
3. Downloads every model in `config.json:models[]` via the matching **provider**:
   - `source: "huggingface"` + `engine: "xet"` → Xet parallel chunk download
   - `source: "huggingface"` + `engine: "hf_hub"` → sequential `hf download` (resumable,
     works on private/gated)
   - `source: "civitai"` → aria2c with `Authorization: Bearer ${CIVITAI_TOKEN}`
   - `source: "url"` → aria2c plain
4. Verifies each downloaded file (size check against expected if available,
   otherwise `>100M` for HF, `>1M` for non-HF)
5. Exits. The base image's supervisor launches ComfyUI with `COMFYUI_ARGS`.

## Files

- `default.sh` — provisioning script (PROVISIONING_SCRIPT target). Sources the
  provider scripts; orchestrates everything else.
- `config.json` — declarative spec: HF engine settings, modules, models, sources.
- `providers/huggingface.sh` — `huggingface_download` (xet engine wrapper) +
  `huggingface_load_xet_engine` (fetches `hf_xet_download.sh`).
- `providers/civitai.sh` — `civitai_download` (aria2c with Bearer token).
- `providers/url.sh` — `url_download` (aria2c, no auth).
- `hf_xet_download.sh` — the standalone Xet downloader. Local copy kept for
  reference; the real one is fetched at runtime from `${HF_XET_SCRIPT_URL}`.
- `start.sh` — legacy standalone bootstrap, kept for reference only.

## ComfyUI launch args

Set via `COMFYUI_ARGS` (Vast) — **must include `--lowvram`** for VRAM < 32GB or
provisioning hangs trying to load the weights. The preflight GPU check forces
`--lowvram` automatically when VRAM < 32GB.

```
--disable-auto-launch --port 18188 --enable-cors-header --lowvram
```

## Env overrides

### Config

- `PROVISIONING_CONFIG` (or `CONFIG_URL`) — **required**. One of:
  - `https://...` URL to a raw JSON file (e.g. `raw.githubusercontent.com/...`)
  - `/path/to/local.json`
  - inline JSON starting with `{`
  No fallback — set it or fail loud.
- `CONFIG_LOCAL` — where the fetched config is cached (default
  `/tmp/provisioning_config.json`).

### HuggingFace

- `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN`) — auth for private/gated repos. The
  preflight check validates it via `whoami-v2` if set.
- `HF_XET_SCRIPT_URL` — override source of `hf_xet_download.sh` (default: this
  repo's `main` branch).
- `HF_XET_HIGH_PERFORMANCE=1` — set automatically; skips Xet's adaptive ramp.
- `HF_XET_NUM_CONCURRENT_RANGE_GETS=64` — Xet concurrency (overridable in
  `config.json:huggingface.downloads[].settings.concurrent_range_gets`).
- `HF_HUB_ENABLE_HF_TRANSFER=0` — set automatically; disables the deprecated
  `hf_transfer` engine in favor of `xet`.

### CivitAI

- `CIVITAI_TOKEN` — required for any `source: "civitai"` model.

### Providers layout

- `VAST_H3_PROVIDERS_DIR` — override where the provider scripts live (default:
  `${VAST_H3_SCRIPT_DIR}/providers`). The `vast-h3` loader installs them to
  `/tmp/vast-h3-providers/` automatically.

## Usage (Vast.Ai)

```bash
vastai create instance <OFFER_ID> \
  --image vastai/comfy:v0.32.0-cuda-12.9-py312 \
  --env '-p 1111:1111 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8188:8188 \
    -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=*** -e JUPYTER_DIR=/ \
    -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="..." \
    -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/default.sh \
    -e PROVISIONING_CONFIG=https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/config.json \
    -e COMFYUI_ARGS="--disable-auto-launch --port 18188 --enable-cors-header --lowvram"' \
  --onstart-cmd 'entrypoint.sh' \
  --disk 70 --jupyter --ssh --direct
```

After boot, use the installed `vast-h3` CLI to inspect or re-run parts:

```bash
vast-h3 status              # show config + per-file on-disk state
vast-h3 reload config       # re-fetch PROVISIONING_CONFIG
vast-h3 reload modules      # re-clone custom nodes
vast-h3 reload models       # re-download any missing/short files
vast-h3 reload all          # modules + models
vast-h3 verify              # re-run size verification
vast-h3 preflight           # re-run disk/GPU/token checks
vast-h3 help
```

## Notes

- Xet parallel download runs at ~600 MB/s after warmup (was 52 MB/s single-stream).
- No SageAttention, no KJNodes — the SPEED node uses the raw diffusion model.
- Disk: t2v+i2v stack ≈ 50 GB used (base image 7 + weights 42.5). `--disk 70` fits.
- Adding a new provider: drop a `*.sh` into `providers/` defining
  `<source>_download <url> <dest_dir> <dest_filename> [token]`. The dispatcher
  picks it up automatically.

## Resolved: audio garble

**Issue:** MiniMax-H3 audio decoded as garbled / silent output when running on the
`vastai/comfy:v0.30.0-cuda-12.9-py312` base image.

**Root cause:** ComfyUI v0.30.0 has the NestedTensor latent *crash* fix for H3, but
the **tiled audio decode fix** for H3's audio VAE (`minimax_h3_audio_vae_fp32`)
landed later in **v0.32.0**. v0.30.0's `VAEDecode` silently drops the audio stream
from the H3 NestedTensor output, while v0.32.0 decodes both video and audio correctly.

**Fix:** upgrade the base image to `vastai/comfy:v0.32.0-cuda-12.9-py312` (or newer).
The SPEED node audio math (`clock_reindex_audio_state`, `audio_scale = 12.0/3.0`)
was correct all along — the bug was downstream in ComfyUI's VAE decode.
