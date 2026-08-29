# providers/url.sh — Plain HTTP/HTTPS URL downloader.
#
# Defines: url_download <url> <dest_dir> <dest_filename>
#
# Routing:
#   config.models[].source == "url"
#
# Same aria2c flags as civitai. No auth header (set source="civitai" if you
# need a token). No fallback to wget/curl: aria2c must be installed.
# Returns 0 on success, 1 on any failure.

url_download() {
    local url="$1" dest_dir="$2" dest_filename="$3"
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
    if ! aria2c "${aria_args[@]}" "${url}"; then
        printf "!! [url] %s failed\n" "${url}" >&2
        return 1
    fi
    # Rename server-suggested name if aria2c ignored --out
    if [[ ! -f "${dest_file}" ]]; then
        local newest
        newest=$(ls -t "${dest_dir}" 2>/dev/null | head -1)
        if [[ -n "${newest}" && -f "${dest_dir}/${newest}" && "${newest}" != "${dest_filename}" ]]; then
            mv "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || \
                cp "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || true
        fi
        if [[ ! -f "${dest_file}" ]]; then
            printf "!! [url] file did not end up at %s\n" "${dest_file}" >&2
            return 1
        fi
    fi
    return 0
}
