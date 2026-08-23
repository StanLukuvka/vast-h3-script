#!/usr/bin/env bash
# hf_xet_download.sh — parallel Hugging Face model downloader with rich logging.
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
# Logging (v2):
#   - Every console line carries an [HH:MM:SS] timestamp so wall-clock gaps
#     between stages are visible at a glance.
#   - Per-file: START line, live progress every 15s (bytes, %, current and
#     average MB/s), then DONE/FAILED with duration, size and the engine
#     that actually downloaded it.
#   - On FAILED the last lines of the per-file log are echoed straight to
#     the console (sed-indented) — no hunting through /tmp.
#   - Summary: per-file table + aggregate GB and average MB/s.

_hf_human() { awk -v b="$1" 'BEGIN{
    if (b >= 1073741824)      printf "%.1fG", b/1073741824;
    else if (b >= 1048576)    printf "%.1fM", b/1048576;
    else if (b >= 1024)       printf "%.1fK", b/1024;
    else                      printf "%dB", b;
}'; }

_hf_ts() { date '+%H:%M:%S'; }

# $1 path, $2 name — bytes currently on disk (Xet writes NAME.incomplete).
_hf_cur_size() {
    local total=0 s=0
    if [[ -f "$1" ]]; then s=$(stat -c %s "$1" 2>/dev/null || echo 0); total=$((total + s)); fi
    if [[ -f "$1.incomplete" ]]; then s=$(stat -c %s "$1.incomplete" 2>/dev/null || echo 0); total=$((total + s)); fi
    echo "${total}"
}

hf_xet_download() {
    if [[ $# -lt 3 ]]; then
        printf "hf_xet_download: usage: hf_xet_download <repo_id> <local_dir> <file1> [file2 ...]\n" >&2
        return 1
    fi

    local hf_repo="$1"
    local local_dir="$2"
    shift 2
    local files=("$@")

    local n_threads="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-16}"

    local has_aria2=no
    command -v aria2c >/dev/null 2>&1 && has_aria2=yes
    local hf_bin
    hf_bin="$(command -v hf || echo MISSING)"
    local hf_available=no
    command -v hf >/dev/null 2>&1 && hf_available=yes

    local engine_label
    if [[ "${hf_available}" == "yes" ]]; then engine_label="hf CLI + Xet"
    elif [[ "${has_aria2}" == "yes" ]]; then engine_label="aria2c (no hf CLI)"
    else engine_label="NONE — no hf CLI, no aria2c"; fi

    printf "[%s] ==> Downloading %d file(s) from %s to %s\n" \
        "$(_hf_ts)" "$#" "${hf_repo}" "${local_dir}"
    printf "[%s]     engine: %s | token: %s | hf: %s | aria2c: %s\n" \
        "$(_hf_ts)" "${engine_label}" \
        "$([[ -n ${HF_TOKEN:-} ]] && echo set || echo none)" "${hf_bin}" "${has_aria2}"

    local tag="$$"
    local pids_file="/tmp/hf_xet_pids.${tag}"
    local files_file="/tmp/hf_xet_files.${tag}"
    : > "${pids_file}"
    printf '%s\n' "${files[@]}" > "${files_file}"
    rm -f /tmp/hf_xet_expect.${tag}.* /tmp/hf_xet_done.${tag}.* 2>/dev/null || true

    local overall_start
    overall_start=$(date +%s)

    local pids=()
    local f
    for f in "${files[@]}"; do
        local name="$(basename "${f}")"
        local log="/tmp/hf_xet_download.${name}.log"
        local out_dir="${local_dir}/$(dirname "${f}")"
        local out_path="${local_dir}/${f}"
        local url="https://huggingface.co/${hf_repo}/resolve/main/${f}"
        local expect_file="/tmp/hf_xet_expect.${tag}.${name}"
        local done_file="/tmp/hf_xet_done.${tag}.${name}"

        printf "[%s]   START %-52s\n" "$(_hf_ts)" "${f}"

        (
            mkdir -p "${out_dir}"

            # Expected size for the progress monitor (last Content-Length).
            if [[ -n "${HF_TOKEN:-}" ]]; then
                curl -sIL --max-time 20 -H "Authorization: Bearer ${HF_TOKEN}" "${url}" \
                    | grep -i '^content-length' | tail -1 | tr -dc '0-9' > "${expect_file}" 2>/dev/null || true
            else
                curl -sIL --max-time 20 "${url}" \
                    | grep -i '^content-length' | tail -1 | tr -dc '0-9' > "${expect_file}" 2>/dev/null || true
            fi
            [[ -s "${expect_file}" ]] || echo 0 > "${expect_file}"

            local t0_ms
            t0_ms=$(date +%s%3N)
            local rc=0
            local used_engine="none"

            if [[ "${hf_available}" == "yes" ]]; then
                local args=(--include "${f}" --local-dir "${local_dir}")
                if [[ -n "${HF_TOKEN:-}" ]]; then
                    args+=(--token "${HF_TOKEN}")
                fi
                # huggingface_hub reads both env names — mirror whichever is set.
                [[ -n "${HF_TOKEN:-}" ]] && export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
                [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]] && export HF_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
                # Xet is the fast path (600+ MB/s with concurrent range gets).
                # Do NOT set HF_HUB_DISABLE_XET here — that's the slow path.
                export HF_XET_HIGH_PERFORMANCE=1
                export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-64}"
                hf download "${hf_repo}" "${args[@]}" > "${log}" 2>&1 || rc=$?
                [[ ${rc} -eq 0 ]] && used_engine="hf-xet"
            else
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
                    printf -- "----- fallback: hf path failed (rc pre-fallback), trying aria2c -----\n" >> "${log}"
                    aria2c -x"${n_threads}" -s"${n_threads}" -k8M --continue=true \
                        --file-allocation=none \
                        --auto-file-renaming=false --allow-overwrite=false \
                        --retry-wait=3 --console-log-level=warn \
                        --dir="${out_dir}" --out="${name}" \
                        "${aria_args[@]}" \
                        "${url}" >> "${log}" 2>&1 || rc=$?
                    [[ ${rc} -eq 0 ]] && used_engine="aria2c"
                fi
            fi

            local t1_ms
            t1_ms=$(date +%s%3N)
            local dur_ms=$((t1_ms - t0_ms))
            local size_b
            size_b=$(_hf_cur_size "${out_path}" "${name}")
            printf 'DURATION_MS=%s\nSIZE=%s\nENGINE=%s\nRC=%s\n' \
                "${dur_ms}" "${size_b}" "${used_engine}" "${rc}" > "${done_file}"

            exit "${rc}"
        ) &
        local pid=$!
        pids+=("${pid}")
        echo "${pid}" >> "${pids_file}"
        printf "[%s]     spawned pid=%s (log: %s)\n" "$(_hf_ts)" "${pid}" "${log}"
    done

    # ---- live progress monitor (background, ticks every 15s) ----
    local pids_joined
    pids_joined="$(printf '%s ' "${pids[@]}")"
    (
        sleep 15
        declare -A prev 2>/dev/null || true
        while read -r f; do
            [[ -z "${f}" ]] && continue
            prev["${f}"]=0
        done < "${files_file}"
        local prev_time=0 now=0 any_alive=yes p f name expect_path done_path
        prev_time=$(date +%s)

        while [[ "${any_alive}" == "yes" ]]; do
            any_alive=no
            while read -r p; do
                [[ -z "${p}" ]] && continue
                if kill -0 "${p}" 2>/dev/null; then any_alive=yes; break; fi
            done < "${pids_file}"
            [[ "${any_alive}" == "no" ]] && break

            now=$(date +%s)
            while read -r f; do
                [[ -z "${f}" ]] && continue
                name="$(basename "${f}")"
                done_path="/tmp/hf_xet_done.${tag}.${name}"
                [[ -f "${done_path}" ]] && continue
                expect_path="/tmp/hf_xet_expect.${tag}.${name}"
                local expect=$([[ -s "${expect_path}" ]] && cat "${expect_path}" || echo 0)
                local cur
                cur=$(_hf_cur_size "${local_dir}/${f}" "${name}")
                local delta=$((cur - ${prev["${f}"]}))
                local dt=$((now - prev_time))
                local rate_win=0 rate_avg=0 pct=0
                if [[ ${dt} -gt 0 ]]; then rate_win=$((delta / dt)); fi
                if [[ ${now} -gt ${overall_start} ]]; then rate_avg=$((cur / (now - overall_start))); fi
                if [[ ${expect} -gt 0 ]]; then pct=$(awk -v c="${cur}" -v e="${expect}" 'BEGIN{printf "%.1f", 100*c/e}'); fi
                prev["${f}"]=${cur}
                printf "[%s]   PROG %-46s %8s/%8s  %5s%%  +%6s/s (avg %6s/s)\n" \
                    "$(_hf_ts)" "${f}" \
                    "$(_hf_human "${cur}")" "$(_hf_human "${expect}")" "${pct}" \
                    "$(_hf_human "${rate_win}")" "$(_hf_human "${rate_avg}")"
            done < "${files_file}"
            prev_time=${now}
            sleep 15
        done
    ) &
    local mon_pid=$!

    # ---- wait for downloads ----
    local failures=0 succeeded=0
    local pid
    local fw
    for fw in "${files[@]}"; do
        printf "[%s]   WAIT  %s\n" "$(_hf_ts)" "${fw}"
    done
    for pid in "${pids[@]}"; do
        local rc=0
        wait "${pid}" || rc=$?
        if [[ ${rc} -ne 0 ]]; then failures=$((failures + 1)); else succeeded=$((succeeded + 1)); fi
    done

    # Let the monitor's final sweep run; it exits once all pids are dead.
    wait "${mon_pid}" 2>/dev/null || true

    # ---- final per-file report ----
    local overall_end
    overall_end=$(date +%s)
    local overall_sec=$((overall_end - overall_start))
    [[ ${overall_sec} -lt 1 ]] && overall_sec=1
    local total_b=0
    local dur_ms size_b engine rc fname done_path log_path avg speed

    printf "[%s] ==> Summary (total %.0fs):\n" "$(_hf_ts)" "${overall_sec}"
    for f in "${files[@]}"; do
        fname="$(basename "${f}")"
        done_path="/tmp/hf_xet_done.${tag}.${fname}"
        log_path="/tmp/hf_xet_download.${fname}.log"
        if [[ -f "${done_path}" ]]; then
            dur_ms=$(awk -F= '/^DURATION_MS=/{print $2}' "${done_path}")
            size_b=$(awk -F= '/^SIZE=/{print $2}' "${done_path}")
            engine=$(awk -F= '/^ENGINE=/{print $2}' "${done_path}")
            rc=$(awk -F= '/^RC=/{print $2}' "${done_path}")
            [[ -z "${size_b}" ]] && size_b=0
            total_b=$((total_b + size_b))
            if [[ "${rc}" != "0" ]]; then
                printf "[%s]   FAIL  %-46s engine=%-8s rc=%s (after %sms)\n" \
                    "$(_hf_ts)" "${f}" "${engine}" "${rc}" "${dur_ms}"
                printf "[%s]         last log lines:\n" "$(_hf_ts)"
                tail -8 "${log_path}" 2>/dev/null | sed 's/^/           | /' || true
            elif [[ -n "${size_b}" && ${dur_ms:-0} -gt 0 ]]; then
                speed=$(awk -v b="${size_b}" -v m="${dur_ms}" 'BEGIN{printf "%.0f", b/1048576/(m/1000)}')
                printf "[%s]   DONE  %-46s %8s  engine=%-8s  %s sec  %s MB/s\n" \
                    "$(_hf_ts)" "${f}" "$(_hf_human "${size_b}")" "${engine}" \
                    "$(awk -v m="${dur_ms}" 'BEGIN{printf "%.1f", m/1000}')" "${speed}"
            else
                printf "[%s]   DONE  %-46s %8s  engine=%s (download completed)\n" \
                    "$(_hf_ts)" "${f}" "$(_hf_human "${size_b}")" "${engine}"
            fi
        else
            printf "[%s]   ???   %-46s no status file — check %s\n" \
                "$(_hf_ts)" "${f}" "${log_path}"
            failures=$((failures + 1))
        fi
    done

    local agg_speed=0
    agg_speed=$(awk -v b="${total_b}" -v s="${overall_sec}" 'BEGIN{printf "%.0f", b/1048576/s}')
    printf "[%s] ==> TOTAL: %d/%d succeeded, %d failed (%s downloaded, avg %s MB/s over %ds)\n" \
        "$(_hf_ts)" "${succeeded}" "$#" "${failures}" \
        "$(_hf_human "${total_b}")" "${agg_speed}" "${overall_sec}"

    if [[ ${succeeded} -eq 0 && $# -gt 0 ]]; then
        printf "[%s] !! ALL downloads failed\n" "$(_hf_ts)" >&2
        return 1
    fi
    return 0
}
