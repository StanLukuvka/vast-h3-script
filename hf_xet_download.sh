#!/usr/bin/env bash
# hf_xet_download.sh — parallel Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Uses wget -c (resumable single-stream) against HF's resolve URLs.
# Each file gets its own background process; a failure on one file does NOT
# abort the others.
#
# For authenticated repos, set HF_TOKEN (Bearer auth header).

hf_xet_download() {
    if [[ $# -lt 3 ]]; then
        printf "hf_xet_download: usage: hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]\\n" >&2
        return 1
    fi

    local hf_repo="$1"
    local local_dir="$2"
    shift 2

    printf "==> Downloading %d file(s) from %s to %s\\n" \
        "$#" "${hf_repo}" "${local_dir}"
    printf "    token: %s\\n" "$([[ -n ${HF_TOKEN:-} ]] && echo set || echo none)"

    local pids=()
    local f
    for f in "$@"; do
        local log="/tmp/hf_xet_download.$(basename "${f}").log"
        printf "    -> %s  (log: %s)\\n" "${f}" "${log}"
        (
            mkdir -p "${local_dir}/$(dirname "${f}")"
            local out_path="${local_dir}/${f}"
            local url="https://huggingface.co/${hf_repo}/resolve/main/${f}"
            local rc=0
            {
                local wget_args=("-c" "-O" "${out_path}")
                if [[ -n "${HF_TOKEN:-}" ]]; then
                    wget_args+=("-e" "http_proxy=" "-e" "https_proxy="
                                "--header=Authorization: Bearer ${HF_TOKEN}")
                else
                    wget_args+=("-e" "http_proxy=" "-e" "https_proxy=")
                fi
                wget "${wget_args[@]}" "${url}"
            } > "${log}" 2>&1 || rc=$?
            if [[ ${rc} -ne 0 ]]; then
                printf "FAILED rc=%s (see %s)\\n" "${rc}" "${log}" >&2
            fi
            exit "${rc}"
        ) &
        pids+=("$!")
    done

    # Wait for all, capture per-file success/failure.
    # `|| rc=$?` is REQUIRED: under `set -e` (inherited from default.sh), a
    # non-zero `wait` on a failed background job would abort the whole script.
    local failures=0
    local succeeded=0
    local pid
    for pid in "${pids[@]}"; do
        local rc=0
        wait "${pid}" || rc=$?
        if [[ ${rc} -ne 0 ]]; then
            failures=$((failures + 1))
            printf "    FAILED pid=%s rc=%s (see /tmp/hf_xet_download.*.log)\\n" "${pid}" "${rc}"
        else
            succeeded=$((succeeded + 1))
        fi
    done

    printf "==> Downloads done: %d/%d succeeded, %d failed\\n" "${succeeded}" "$#" "${failures}"

    # Fail only if ALL downloads failed (partial success leaves the node usable).
    if [[ ${succeeded} -eq 0 && $# -gt 0 ]]; then
        printf "!! ALL downloads failed — check /tmp/hf_xet_download.*.log\\n" >&2
        return 1
    fi
    return 0
}
