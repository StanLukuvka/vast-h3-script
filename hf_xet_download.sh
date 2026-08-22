#!/usr/bin/env bash
# hf_xet_download.sh — parallel Hugging Face model downloader.
#
# Usage:
#   source hf_xet_download.sh
#   hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]
#
# Uses `hf download` + Xet (HF_XET_HIGH_PERFORMANCE=1, 64 concurrent range
# gets) as the fast primary path (~600 MB/s on fast links). Falls back to
# aria2c (parallel chunked + resumable) if the hf CLI is missing or fails.
#
# !!! DO NOT REGRESS THIS !!!
# Prior regression (d851d01, f9bbb8d): aria2c/plain-HTTP was made primary and
# `HF_HUB_DISABLE_XET=1` was set on the hf fallback — that KILLED the Xet
# fast path and everything dropped to ~16 MB/s per file (from 600 MB/s).
# Rules that MUST hold:
#   1. `hf download` (with xet) is ALWAYS the primary engine when present.
#   2. HF_HUB_DISABLE_XET must NOT be set in the primary path.
#   3. HF_XET_HIGH_PERFORMANCE=1 and HF_XET_NUM_CONCURRENT_RANGE_GETS (=64)
#      must be exported before the hf download runs (the 600 MB/s source).
#   4. aria2c is a FALLBACK only (hf missing, or hf download rc!=0).
#
# Each file gets its own background process; a failure on one file does NOT
# abort the others. Override per-file chunk count via
# HF_XET_NUM_CONCURRENT_RANGE_GETS.

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
    local hf_available=no
    if command -v hf >/dev/null 2>&1; then
        hf_available=yes
    fi
    if command -v aria2c >/dev/null 2>&1; then
        has_aria2=yes
    fi

    if [[ "${hf_available}" == "yes" ]]; then
        printf "==> Downloading %d file(s) from %s to %s (engine: hf CLI + Xet, %d streams)\n" \
            "$#" "${hf_repo}" "${local_dir}" "${n_threads}"
    elif [[ "${has_aria2}" == "yes" ]]; then
        printf "==> Downloading %d file(s) from %s to %s (engine: aria2c -x%d — hf CLI not found)\n" \
            "$#" "${hf_repo}" "${local_dir}" "${n_threads}"
    else
        printf "==> Downloading %d file(s) from %s to %s (engine: NONE — no hf CLI, no aria2c)\n" \
            "$#" "${hf_repo}" "${local_dir}"
    fi
    printf "    token: %s\n" "$([[ -n ${HF_TOKEN:-} ]] && echo set || echo none)"
    printf "    hf: %s | aria2c: %s\n" "${hf_bin}" "${has_aria2}"

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
            if [[ "${hf_available}" == "yes" ]]; then
                local args=(--include "${f}" --local-dir "${local_dir}")
                if [[ -n "${HF_TOKEN:-}" ]]; then
                    args+=(--token "${HF_TOKEN}")
                fi
                # Xet is the fast path (600+ MB/s with concurrent range gets).
                # Do NOT set HF_HUB_DISABLE_XET here — that's the slow path.
                export HF_XET_HIGH_PERFORMANCE=1
                export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-64}"
                hf download "${hf_repo}" "${args[@]}" \
                    > "${log}" 2>&1 || rc=$?
            else
                # no hf CLI at all — mark failed so the fallback engages
                rc=1
            fi
            # Fallback: aria2c when hf is missing OR the hf/Xet path fails.
            if [[ "${hf_available}" != "yes" || ${rc} -ne 0 ]]; then
                if [[ "${has_aria2}" == "yes" ]]; then
                    rc=0
                    local aria_args=()
                    if [[ -n "${HF_TOKEN:-}" ]]; then
                        aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
                    fi
                    aria2c -x"${n_threads}" -s"${n_threads}" -k8M --continue=true \
                        --file-allocation=none \
                        --auto-file-renaming=false --allow-overwrite=false \
                        --retry-wait=3 \
                        --dir="$(dirname "${out_path}")" --out="$(basename "${out_path}")" \
                        "${aria_args[@]}" \
                        "${url}" > "${log}" 2>&1 || rc=$?
                else
                    # Nothing to fall back to — leave rc from hf.
                    true
                fi
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
