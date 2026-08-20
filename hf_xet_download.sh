#!/usr/bin/env bash
# hf_xet_download.sh — parallel Xet-backed Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Each file is downloaded in its own background `hf download` process so the 4
# files run in parallel (each one still uses Xet chunk concurrency internally).
# Override per-file concurrency via HF_XET_NUM_CONCURRENT_RANGE_GETS.

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

    printf "Downloading %d file(s) from %s (hf_xet parallel, file-level) to %s...\n" \
        "$#" "${hf_repo}" "${local_dir}"

    # Per-file downloads, each in its own background process.
    # Each gets its own Xet chunk concurrency AND runs concurrently with the
    # others — total throughput scales with both per-file chunks and file count.
    local pids=()
    local f rc=0
    for f in "$@"; do
        local log="/tmp/hf_xet_download.$(basename "${f}").log"
        echo "[DEBUG] launching: hf download ${hf_repo} --local-dir ${local_dir} --include ${f} (log: ${log})" >&2
        (
            local args=()
            if [[ -n "${HF_TOKEN}" ]]; then
                args+=(--token "${HF_TOKEN}")
            else
                args+=(--no-token)
            fi
            args+=(--include "${f}")
            hf download "${hf_repo}" --local-dir "${local_dir}" "${args[@]}" \
                > "${log}" 2>&1
        ) &
        pids+=($!)
    done

    # Wait for all background downloads, capture failures.
    for pid in "${pids[@]}"; do
        wait "${pid}" || rc=$?
    done

    if [[ ${rc} -ne 0 ]]; then
        echo "[DEBUG] one or more downloads failed (rc=${rc}); logs in /tmp/hf_xet_download.*.log" >&2
        return ${rc}
    fi
    return 0
}
