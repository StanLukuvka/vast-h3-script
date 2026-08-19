#!/usr/bin/env bash
# hf_xet_download.sh — parallel Xet-backed Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Examples:
#   hf_xet_download Comfy-Org/MiniMax-H3 /ComfyUI/models \
#       diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
#       text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
#       vae/minimax_h3_video_vae_fp16.safetensors
#
# Notes:
#   - Modern huggingface_hub (>=0.32.0) auto-uses hf_xet; hf_transfer is deprecated.
#   - Xet chunks each file and pulls over concurrent HTTP range requests. Its
#     adaptive controller starts conservative and ramps slowly, so we force
#     high-performance mode and a high concurrent-range cap to use a fast link.
#   - HF_TOKEN / HUGGING_FACE_HUB_TOKEN are read automatically by `hf download`.
#   - Override concurrency: HF_XET_NUM_CONCURRENT_RANGE_GETS=N (default 64).

hf_xet_download() {
    echo "[DEBUG] hf_xet_download CALLED with $# args: $*" >&2
    if [[ $# -lt 3 ]]; then
        printf "hf_xet_download: usage: hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]\n" >&2
        return 1
    fi

    local hf_repo="$1"
    local local_dir="$2"
    shift 2

    # Force Xet to actually use available bandwidth instead of ramping slowly.
    export HF_XET_HIGH_PERFORMANCE=1
    export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-64}"

    echo "[DEBUG] hf=$(command -v hf || echo MISSING)  HF_TOKEN set? ${HF_TOKEN:+yes}${HF_TOKEN:-no}" >&2
    echo "[DEBUG] repo=${hf_repo} local_dir=${local_dir} NF_CONCURRENT=${HF_XET_NUM_CONCURRENT_RANGE_GETS}" >&2

    local hf_args=()
    [[ -n "${HF_TOKEN}" ]] && hf_args+=(--token "${HF_TOKEN}")

    local f
    for f in "$@"; do
        hf_args+=(--include "${f}")
    done

    echo "[DEBUG] running: hf download ${hf_repo} --local-dir ${local_dir} ${hf_args[*]}" >&2
    printf "Downloading %d file(s) from %s (hf_xet parallel) to %s...\n" \
        "$#" "${hf_repo}" "${local_dir}"
    hf download "${hf_repo}" --local-dir "${local_dir}" "${hf_args[@]}"
}
