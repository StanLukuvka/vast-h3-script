#!/usr/bin/env bash
# hf_xet_download.sh — parallel Xet-backed Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Each file downloads in its own background `hf download` process so all files
# run in parallel (each still uses Xet chunk concurrency internally).
# Override per-file concurrency via HF_XET_NUM_CONCURRENT_RANGE_GETS.
# A failure on one file does NOT abort the others.

hf_xet_download() {
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

    local hf_bin
    hf_bin="$(command -v hf || echo MISSING)"
    printf "==> Downloading %d file(s) from %s to %s\n" "$#" "${hf_repo}" "${local_dir}"
    printf "    engine: hf_xet (high_performance=1, concurrent_ranges=%s)\n" "${HF_XET_NUM_CONCURRENT_RANGE_GETS}"
    printf "    hf: %s | token: %s\n" "${hf_bin}" "$([[ -n ${HF_TOKEN} ]] && echo set || echo none)"

    local pids=()
    local f
    for f in "$@"; do
        local log="/tmp/hf_xet_download.$(basename "${f}").log"
        printf "    -> %s  (log: %s)\n" "${f}" "${log}"
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
        pids+=("$!")
    done

    # Wait for all, capture per-file success/failure.
    local failures=0
    local succeeded=0
    local pid
    for pid in "${pids[@]}"; do
        local rc=0
        wait "${pid}" || rc=$?
        if [[ ${rc} -ne 0 ]]; then
            failures=$((failures + 1))
            printf "    FAILED pid=%s rc=%s (see /tmp/hf_xet_download.*.log)\n" "${pid}" "${rc}"
        else
            succeeded=$((succeeded + 1))
        fi
    done

    printf "==> Downloads done: %d/%d succeeded, %d failed\n" "${succeeded}" "$#" "${failures}"

    # Fail only if ALL downloads failed (partial success leaves the node usable).
    if [[ ${succeeded} -eq 0 && $# -gt 0 ]]; then
        printf "==> ALL downloads failed — check /tmp/hf_xet_download.*.log\n" >&2
        return 1
    fi
    return 0
}
