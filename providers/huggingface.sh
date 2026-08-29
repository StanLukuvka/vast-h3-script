# providers/huggingface.sh — Hugging Face downloader.
#
# Defines: huggingface_download <repo> <dest_dir> <file...>
#
# Routing:
#   config.models[].source == "huggingface"
#   config.models[].engine  == "xet"     → this provider (uses hf_xet_download)
#   config.models[].engine  == "hf_hub"  → handled separately in default.sh
#                                          (sequential `hf download` per file,
#                                          not a parallel grouped download)
#
# The xet engine is sharded (600 MB/s on a T4) and pulls all files of a repo
# in one process. Tokens: HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) is forwarded to
# the xet engine, which must be sourced from
# ${HF_XET_SCRIPT_URL} (default: vast-h3-script repo) into ${HF_XET_SCRIPT_LOCAL}
# before this provider runs.

# -- low-level xet engine loader ---------------------------------------------
# Called by default.sh once at startup. Sources hf_xet_download.sh from
# HF_XET_SCRIPT_URL (downloaded into HF_XET_SCRIPT_LOCAL). No-op if already
# loaded.
huggingface_load_xet_engine() {
    if [[ "$(type -t hf_xet_download)" == "function" ]]; then
        return 0
    fi
    if [[ -z "${HF_XET_SCRIPT_URL:-}" ]]; then
        printf "!! ERROR: HF_XET_SCRIPT_URL not set; cannot load xet engine\n" >&2
        return 1
    fi
    if [[ "${HF_XET_SCRIPT_URL}" =~ ^https?:// ]]; then
        printf "==> Loading hf_xet_download.sh from %s\n" "${HF_XET_SCRIPT_URL}"
        if ! curl -fsSL "${HF_XET_SCRIPT_URL}" -o "${HF_XET_SCRIPT_LOCAL}" 2>/tmp/hf_xet_curl_err.log; then
            printf "!! Failed to fetch %s\n" "${HF_XET_SCRIPT_URL}" >&2
            cat /tmp/hf_xet_curl_err.log 2>/dev/null | head -5 >&2 || true
            return 1
        fi
    else
        # local file — accept either a bare path or a file:// URL
        local local_path="${HF_XET_SCRIPT_URL#file://}"
        if [[ "${local_path}" != "${HF_XET_SCRIPT_LOCAL}" ]]; then
            cp "${local_path}" "${HF_XET_SCRIPT_LOCAL}"
        fi
    fi
    if [[ ! -s "${HF_XET_SCRIPT_LOCAL}" ]]; then
        printf "!! hf_xet_download.sh is empty at %s\n" "${HF_XET_SCRIPT_LOCAL}" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "${HF_XET_SCRIPT_LOCAL}"
    if [[ "$(type -t hf_xet_download)" != "function" ]]; then
        printf "!! ERROR: hf_xet_download.sh sourced but hf_xet_download() not defined\n" >&2
        printf "   First 5 lines of fetched file:\n" >&2
        head -5 "${HF_XET_SCRIPT_LOCAL}" >&2
        return 1
    fi
    printf "==> hf_xet_download() loaded OK (%s bytes)\n" "$(wc -c < "${HF_XET_SCRIPT_LOCAL}")"
}

# -- provider entry point ---------------------------------------------------
# Usage: huggingface_download <repo> <dest_dir> <file1> [file2 ...]
# Returns 0 on success, non-zero on any failure (no per-file recovery).
huggingface_download() {
    local repo="$1" dest_dir="$2"; shift 2
    hf_xet_download "${repo}" "${dest_dir}" "$@"
}
