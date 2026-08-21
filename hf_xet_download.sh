#!/usr/bin/env bash
# hf_xet_download.sh — parallel Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Uses aria2c (parallel chunked + resumable) against HF's resolve URLs.
# Falls back to `hf download` (with HF_HUB_DISABLE_XET=1) if aria2c is missing.
#
# Each file gets its own background process; a failure on one file does NOT
# abort the others. Override per-file chunk count via HF_XET_NUM_CONCURRENT_RANGE_GETS.

hf_xet_download() {
    if [[ $# -lt 3 ]]; then
        printf "hf_xet_download: usage: hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]\n" >&2
        return 1
    fi

    local hf_repo="$1"
    local local_dir="$2"
    shift 2

    local n_threads="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-16}"

    local has_aria2=no
    local hf_bin="$(command -v hf || echo MISSING)"
    if command -v aria2c >/dev/null 2>&1; then
        has_aria2=yes
    fi

    if [[ "${has_aria2}" == "yes" ]]; then
        printf "==> Downloading %d file(s) from %s to %s (engine: aria2c -x%d)\n" \
            "$#" "${hf_repo}" "${local_dir}" "${n_threads}"
    else
        printf "==> Downloading %d file(s) from %s to %s (engine: hf CLI — aria2c not found)\n" \
            "$#" "${hf_repo}" "${local_dir}"
    fi
    printf "    token: %s\n" "$([[ -n ${HF_TOKEN:-} ]] && echo set || echo none)"
    printf "    aria2c: %s | hf: %s\n" "${has_aria2}" "${hf_bin}"

    local pids=()
    local f
    for f in "$@"; do
        local log="/tmp/hf_xet_download.$(basename "${f}").log"
        printf "    -> %s  (log: %s)\n" "${f}" "${log}"
        (
            mkdir -p "${local_dir}/$(dirname "${f}")"
            local out_path="${local_dir}/${f}"
            local url="https://huggingface.co/${hf_repo}/resolve/main/${f}"
            local rc=0
            if [[ "${has_aria2}" == "yes" ]]; then
                local aria_args=()
                if [[ -n "${HF_TOKEN:-}" ]]; then
                    aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
                fi
                aria2c -x"${n_threads}" -s"${n_threads}" -k1M --continue=true \$
                    --auto-file-renaming=false --allow-overwrite=false \$
                    --retry-wait=30 \$
                    --dir="$(dirname "${out_path}")" --out="$(basename "${out_path}")" \$
                    "${aria_args[@]}" \$
                    "${url}" > "${log}" 2>&1 || rc=$?
            else
                local args=()
                if [[ -n "${HF_TOKEN:-}" ]]; then
                    args+=(--token "${HF_TOKEN}")
                fi
                args+=(--include "${f}")
                # HF_HUB_DISABLE_XET=1 forces the plain LFS path — avoids the
                # known Xet CAS connection hang that blocks hf download forever.
                HF_HUB_DISABLE_XET=1 hf download "${hf_repo}" --local-dir "${local_dir}" "${args[@]}" \$
                    > "${log}" 2>&1 || rc=$?
            fi
            if [[ ${rc} -ne 0 ]]; then
                printf "FAILED rc=%s (see %s)\n" "${rc}" "${log}" >&2
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
            printf "    FAILED pid=%s rc=%s (see /tmp/hf_xet_download.*.log)\n" "${pid}" "${rc}"
        else
            succeeded=$((succeeded + 1))
        fi
    done

    printf "==> Downloads done: %d/%d succeeded, %d failed\n" "${succeeded}" "$#" "${failures}"

    # Fail only if ALL downloads failed (partial success leaves the node usable).
    if [[ ${succeeded} -eq 0 && $# -gt 0 ]]; then
        printf "!! ALL downloads failed — check /tmp/hf_xet_download.*.log\n" >&2
        return 1
    fi
    return 0
}