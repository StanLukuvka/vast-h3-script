# providers/civitai.sh — CivitAI downloader.
#
# Defines: civitai_download <url> <dest_dir> <dest_filename> [civitai_token]
#
# Routing:
#   config.models[].source == "civitai"
#
# Uses aria2c (16 connections, 16 splits, 8M min block) — same flags as the
# url provider. CIVITAI_TOKEN (if set) is passed as `Authorization: Bearer <tok>`.
# No fallback to wget/curl: aria2c must be installed (added to APT_PACKAGES).
# Returns 0 on success, 1 on any failure.

civitai_download() {
    local url="$1" dest_dir="$2" dest_filename="$3" civitai_token="${4:-${CIVITAI_TOKEN:-}}"
    if ! command -v aria2c >/dev/null 2>&1; then
        printf "!! aria2c not installed — refusing to download %s\n" "${url}" >&2
        return 1
    fi
    local dest_file="${dest_dir}/${dest_filename}"
    if [[ -f "${dest_file}" && -s "${dest_file}" ]]; then
        printf "==> SKIP (already exists): %s\n" "${dest_filename}"
        return 0
    fi
    mkdir -p "${dest_dir}"
    local aria_args=(
        -x16 -s16 -k8M --continue=true --file-allocation=none
        --auto-file-renaming=false --allow-overwrite=false
        --retry-wait=3 --console-log-level=warn
        --dir="${dest_dir}" --out="${dest_filename}"
    )
    [[ -n "${civitai_token}" ]] && aria_args+=(--header="Authorization: Bearer ${civitai_token}")
    if ! aria2c "${aria_args[@]}" "${url}"; then
        printf "!! [civitai] %s failed\n" "${url}" >&2
        return 1
    fi
    # aria2c --out=foo should land at exactly ${dest_file}; if the server
    # suggested a different name, rename the most recent file in dest_dir.
    if [[ ! -f "${dest_file}" ]]; then
        local newest
        newest=$(ls -t "${dest_dir}" 2>/dev/null | head -1)
        if [[ -n "${newest}" && -f "${dest_dir}/${newest}" && "${newest}" != "${dest_filename}" ]]; then
            mv "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || \
                cp "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || true
        fi
        if [[ ! -f "${dest_file}" ]]; then
            printf "!! [civitai] file did not end up at %s\n" "${dest_file}" >&2
            return 1
        fi
    fi
    return 0
}
