#!/bin/bash
set -euo pipefail

# Capture the on-disk path of this script at the very top, BEFORE any
# source or process-substitution can clobber BASH_SOURCE[0]. The loader
# installer uses this to extract function definitions to /tmp/vast-h3-functions.sh.
VAST_H3_SCRIPT="${BASH_SOURCE[0]}"

# Vast.ai writes instance env vars (e.g. -e HF_TOKEN=...) to /etc/environment
# inside the container, but the provisioning process sometimes runs without
# them exported. Load them explicitly so tokens reach the downloaders.
if [[ -f /etc/environment ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/environment
    set +a
fi

# Activate the venv if present. `set +e` around the source so a missing venv
# (e.g. on lean base images that don't ship /venv) doesn't kill the script —
# provisioning still works, just without the `hf` CLI on $PATH.
if [[ -f /venv/main/bin/activate ]]; then
    set +e
    source /venv/main/bin/activate
    set -e
fi
# Only set COMFYUI_DIR at top-level execution, not when sourced.
# When the loader sources this file, the user may have set COMFYUI_DIR
# via env (e.g. `COMFYUI_DIR=/foo vast-h3 status`).
if [[ "${VAST_H3_SOURCED:-0}" != "1" ]]; then
    COMFYUI_DIR="${WORKSPACE:-/workspace}/ComfyUI"
fi

# Vast base image may leave these unset; declare them so `set -u` doesn't abort.
declare -a APT_PACKAGES=()
declare -a PIP_PACKAGES=()
declare -a NODES=()
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
    "aria2"
    "jq"
)

PIP_PACKAGES=(
    #"package-1"
    #"package-2"
)

NODES=(
    "https://github.com/StanLukuvka/ComfyUI-MiniMax-H3-SPEED@${SPEED_BRANCH:-main}"
)








### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

# ---------------------------------------------------------------------------
# PROVISIONING_CONFIG — public config (in repo). Loaded at runtime; no
# hardcoded model lists below this point.
# Two-stage flow:
#   PROVISIONING_SCRIPT = default.sh (this file)
#   PROVISIONING_CONFIG = config.json (URL, file path, or inline JSON starting with '{')
# Either PROVISIONING_CONFIG or CONFIG_URL must be set. There is no fallback —
# if you don't set it, provisioning fails fast.
# ---------------------------------------------------------------------------
PROVISIONING_CONFIG_URL="${PROVISIONING_CONFIG:-${CONFIG_URL:-}}"
CONFIG_LOCAL="${CONFIG_LOCAL:-/tmp/provisioning_config.json}"

# --- Providers (per-source downloaders) -----------------------------------
# Each provider file in providers/ defines its own download function:
#   providers/huggingface.sh  → huggingface_download  (uses hf_xet_download)
#   providers/civitai.sh      → civitai_download
#   providers/url.sh          → url_download
#
# Vast only fetches this single file (default.sh), not the whole repo, so
# the providers/ dir does NOT exist next to the script on the instance.
# We fetch a tarball (VAST_H3_PROVIDERS_TARBALL_URL) and extract to
# /tmp/vast-h3-providers/. If providers are already on disk at
# VAST_H3_PROVIDERS_DIR (e.g. a local dev tree), the fetch is skipped.
# No fallback: if the fetch fails or the tarball has no .sh files, abort.
VAST_H3_PROVIDERS_DIR="${VAST_H3_PROVIDERS_DIR:-/tmp/vast-h3-providers}"
VAST_H3_PROVIDERS_TARBALL_URL="${VAST_H3_PROVIDERS_TARBALL_URL:-https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/providers.tar.gz}"
provisioning_load_providers() {
    # If VAST_H3_PROVIDERS_DIR already has *.sh files, use them as-is
    # (local dev / test harness path).
    local existing_sh
    shopt -s nullglob
    existing_sh=( "${VAST_H3_PROVIDERS_DIR}"/*.sh )
    shopt -u nullglob
    if [[ "${#existing_sh[@]}" -gt 0 ]]; then
        printf "==> Providers: using local %s (%d .sh files)\n" \
            "${VAST_H3_PROVIDERS_DIR}" "${#existing_sh[@]}"
        return 0
    fi
    # Else fetch the tarball. Local file:// URLs are also supported.
    local local_tarball_path="${VAST_H3_PROVIDERS_TARBALL_URL#file://}"
    local tarball_tmp="/tmp/vast-h3-providers.tar.gz.$$"
    printf "==> Providers: fetching %s\n" "${VAST_H3_PROVIDERS_TARBALL_URL}"
    if [[ "${VAST_H3_PROVIDERS_TARBALL_URL}" =~ ^https?:// ]]; then
        if ! curl -fsSL "${VAST_H3_PROVIDERS_TARBALL_URL}" -o "${tarball_tmp}" 2>/tmp/providers_curl_err.log; then
            printf "!! Failed to fetch providers tarball\n" >&2
            cat /tmp/providers_curl_err.log 2>/dev/null | head -5 >&2 || true
            return 1
        fi
    else
        if [[ ! -f "${local_tarball_path}" ]]; then
            printf "!! Local tarball not found: %s\n" "${local_tarball_path}" >&2
            return 1
        fi
        if [[ "${local_tarball_path}" != "${tarball_tmp}" ]]; then
            cp "${local_tarball_path}" "${tarball_tmp}"
        fi
    fi
    if [[ ! -s "${tarball_tmp}" ]]; then
        printf "!! Providers tarball is empty\n" >&2
        return 1
    fi
    mkdir -p "${VAST_H3_PROVIDERS_DIR}"
    # tar -xzf ... -C providers_dir  →  the tarball's top-level dir is "."
    # (we built it that way), so files land directly in providers_dir.
    if ! tar -xzf "${tarball_tmp}" -C "${VAST_H3_PROVIDERS_DIR}"; then
        printf "!! Failed to extract providers tarball to %s\n" "${VAST_H3_PROVIDERS_DIR}" >&2
        return 1
    fi
    rm -f "${tarball_tmp}"
    # Verify extraction produced at least one .sh
    shopt -s nullglob
    local extracted_sh
    extracted_sh=( "${VAST_H3_PROVIDERS_DIR}"/*.sh )
    shopt -u nullglob
    if [[ "${#extracted_sh[@]}" -eq 0 ]]; then
        printf "!! No .sh files found in %s after extraction\n" "${VAST_H3_PROVIDERS_DIR}" >&2
        return 1
    fi
    printf "==> Providers: extracted %d .sh file(s) to %s\n" \
        "${#extracted_sh[@]}" "${VAST_H3_PROVIDERS_DIR}"
}
provisioning_load_providers || exit 1

if [[ ! -d "${VAST_H3_PROVIDERS_DIR}" ]]; then
    printf "!! ERROR: providers dir not found: %s\n" "${VAST_H3_PROVIDERS_DIR}" >&2
    exit 1
fi
provider_files_sourced=0
for provider_file in "${VAST_H3_PROVIDERS_DIR}"/*.sh; do
    [[ -f "${provider_file}" ]] || continue
    # shellcheck source=/dev/null
    source "${provider_file}"
    provider_files_sourced=$((provider_files_sourced+1))
done
if [[ "${provider_files_sourced}" -eq 0 ]]; then
    printf "!! ERROR: no provider files found in %s\n" "${VAST_H3_PROVIDERS_DIR}" >&2
    exit 1
fi
unset provider_file provider_files_sourced

# Xet engine URL — same place as before, just declared up here so the
# huggingface provider can use it.
HF_XET_SCRIPT_URL="${HF_XET_SCRIPT_URL:-https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/hf_xet_download.sh}"
HF_XET_SCRIPT_LOCAL="/tmp/hf_xet_download.sh"
# Trigger the xet fetch + load (provider function, no-op if already loaded).
huggingface_load_xet_engine || exit 1

# ---------------------------------------------------------------------------
# Config loader — fetches PROVISIONING_CONFIG_URL into $CONFIG_LOCAL.
# PROVISIONING_CONFIG must be set. Accepts:
#   - URL            (https?://...)      — fetched via curl
#   - Local file     (/path/to/file)     — copied
#   - Inline JSON    (starts with '{')   — written directly
# No sibling-config fallback, no default URL — fail fast if unset or fetch fails.
# ---------------------------------------------------------------------------
provisioning_load_config() {
    local url="${PROVISIONING_CONFIG_URL:-}"
    if [[ -z "${url}" ]]; then
        printf "!! PROVISIONING_CONFIG is not set. Set it to a URL, file path, or inline JSON before running.\n" >&2
        return 1
    fi
    # Inline JSON
    if [[ "${url}" == "{"* ]]; then
        printf "%s" "${url}" > "${CONFIG_LOCAL}"
        printf "==> PROVISIONING_CONFIG is inline JSON (%s bytes)\n" "$(wc -c < "${CONFIG_LOCAL}")"
        return 0
    fi
    # URL
    if [[ "${url}" =~ ^https?:// ]]; then
        printf "==> Fetching config from %s\n" "${url}"
        if ! curl -fsSL "${url}" -o "${CONFIG_LOCAL}" 2>/tmp/cfg_curl_err.log; then
            printf "!! Failed to fetch config from %s\n" "${url}" >&2
            cat /tmp/cfg_curl_err.log 2>/dev/null | head -5 >&2 || true
            return 1
        fi
        if [[ ! -s "${CONFIG_LOCAL}" ]]; then
            printf "!! Fetched config from %s is empty\n" "${url}" >&2
            return 1
        fi
        printf "==> Config fetched OK (%s bytes)\n" "$(wc -c < "${CONFIG_LOCAL}")"
        return 0
    fi
    # Local file (accept bare path or file:// URL)
    local local_path="${url#file://}"
    if [[ -f "${local_path}" ]]; then
        cp "${local_path}" "${CONFIG_LOCAL}"
        printf "==> Using local config %s (%s bytes)\n" "${url}" "$(wc -c < "${CONFIG_LOCAL}")"
        return 0
    fi
    printf "!! PROVISIONING_CONFIG=%s is not a URL, file path, or inline JSON\n" "${url}" >&2
    return 1
}

# Apply config -> env (HF Xet tuning), modules -> NODES, models -> nothing
# here (provisioning_get_models does the dispatch).
provisioning_apply_config() {
    if [[ ! -f "${CONFIG_LOCAL}" ]]; then
        printf "!! provisioning_apply_config: no config\n" >&2
        return 1
    fi
    if ! python3 -m json.tool "${CONFIG_LOCAL}" >/dev/null 2>&1; then
        printf "!! provisioning_apply_config: %s is not valid JSON — skipping\n" "${CONFIG_LOCAL}" >&2
        return 1
    fi
    local py_out
    py_out=$(python3 << 'PYEOF'
import json, shlex, pathlib
cfg = json.loads(pathlib.Path("/tmp/provisioning_config.json").read_text())

# huggingface.downloads[] -> HF Xet env (engine-specific settings)
hf_cfg = cfg.get("huggingface", {})
for d in hf_cfg.get("downloads", []):
    engine = d.get("engine", "")
    settings = d.get("settings", {}) or {}
    if engine == "xet":
        if settings.get("high_performance"):
            print("export HF_XET_HIGH_PERFORMANCE=1")
        n_concurrent = settings.get("concurrent_range_gets")
        if n_concurrent is not None:
            print(f"export HF_XET_NUM_CONCURRENT_RANGE_GETS={int(n_concurrent)}")
    elif engine == "hf_hub":
        # No special env; hf_hub_download uses sequential range gets (slow but resumable).
        pass
    else:
        print(f"# unknown HF engine: {engine}")

# env block (public, non-secret)
for k, v in cfg.get("env", {}).items():
    if k.replace("_","").isalnum():
        print(f"export {k}={shlex.quote(str(v))}")

# modules -> NODES (overrides hardcoded NODES if present)
# branch values may use shell-style ${VAR:-default} defaults; expand them
# now (os.environ) so we end up with the literal branch name, not the
# unresolved ${...} string. shlex.quote below would otherwise single-quote
# the value, preventing bash from expanding it at eval time.
import os
def _expand_defaults(value: str) -> str:
    # Match ${VAR} or ${VAR:-default}. VAR is shell-var-like: [A-Za-z_][A-Za-z0-9_]*
    import re as _re
    def repl(m):
        var = m.group(1)
        default = m.group(3)  # may be None
        val = os.environ.get(var, default if default is not None else "")
        return val
    return _re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}', repl, value)

mods = cfg.get("modules", [])
if mods:
    nodes = []
    for m in mods:
        url = _expand_defaults(m.get("url", ""))
        branch = _expand_defaults(m.get("branch", ""))
        if branch:
            nodes.append(f"{url}@{branch}")
        else:
            nodes.append(url)
    quoted = " ".join(shlex.quote(n) for n in nodes)
    print(f"NODES=({quoted})")
PYEOF
)
    if [[ -n "${py_out}" ]]; then
        printf "==> Applying config:\n"
        printf "%s\n" "${py_out}" | sed 's/^/    /'
        eval "${py_out}"
    fi
    local model_count
    model_count=$(python3 -c "import json,pathlib; print(len(json.loads(pathlib.Path('/tmp/provisioning_config.json').read_text()).get('models',[])))" 2>/dev/null || echo 0)
    printf "==> Config: %s model(s), %s module(s)\n" "${model_count}" "${#NODES[@]}"
}

# Provider-agnostic model fetcher driven by config.json models[].
# Each entry: { source, ... source-specific fields }
#   source=huggingface: { repo, files[], engine }   engine in ("xet","hf_hub")
#   source=civitai|url: { url, path }                no engine (aria2/wget pick)
provisioning_get_models() {
    if [[ ! -f "${CONFIG_LOCAL}" ]]; then
        printf "!! provisioning_get_models: no config at %s — did provisioning_load_config fail?\n" "${CONFIG_LOCAL}" >&2
        return 1
    fi
    if ! jq -e . "${CONFIG_LOCAL}" >/dev/null 2>&1; then
        printf "!! provisioning_get_models: %s is not valid JSON\n" "${CONFIG_LOCAL}" >&2
        return 1
    fi

    local model_count
    model_count=$(jq '.models | length' "${CONFIG_LOCAL}")
    if [[ "${model_count}" -eq 0 ]]; then
        printf "==> No models in config — nothing to download\n"
        return 0
    fi
    printf "==> Downloading %s model(s) from config\n" "${model_count}"

    # 1) HF xet: group all files per repo, one huggingface_download call per repo.
    #    engine="xet" routes here; engine="hf_hub" routes to section 2 below.
    declare -A xet_repo_groups=()
    while IFS=$'	' read -r repo file; do
        [[ -z "${repo}" || -z "${file}" ]] && continue
        if [[ -z "${xet_repo_groups[${repo}]:-}" ]]; then
            xet_repo_groups["${repo}"]="${file}"
        else
            xet_repo_groups["${repo}"]+=$'\n'"${file}"
        fi
    done < <(jq -r '
        .models[]
        | select(.source == "huggingface")
        | select((.engine // "xet") == "xet")
        | .repo as $r
        | .files[]
        | [$r, .] | @tsv
    ' "${CONFIG_LOCAL}")

    local repo key files
    local xet_failure_count=0
    for repo in "${!xet_repo_groups[@]}"; do
        mapfile -t files <<< "${xet_repo_groups[${repo}]}"
        printf "==> HF[xet] %s (%d file(s)) -> %s\n" "${repo}" "${#files[@]}" "${COMFYUI_DIR}/models"
        if ! huggingface_download "${repo}" "${COMFYUI_DIR}/models" "${files[@]}"; then
            printf "!! HF[xet] %s failed\n" "${repo}" >&2
            xet_failure_count=$((xet_failure_count+1))
        fi
    done
    if [[ "${xet_failure_count}" -gt 0 ]]; then
        printf "!! HF[xet]: %d repo(s) failed — aborting\n" "${xet_failure_count}" >&2
        return 1
    fi

    # 2) HF hf_hub: sequential `hf download` per file (resumable, slow but works
    #    on private/gated repos where xet isn't available).
    # Always declare the assoc array (even if no entries) so `set -u` doesn't
    # trip on `${hf_hub_groups[@]}` when the jq filter returns nothing.
    declare -A hf_hub_groups=()
    while IFS=$'	' read -r repo file; do
        [[ -z "${repo}" || -z "${file}" ]] && continue
        if [[ -z "${hf_hub_groups[${repo}]:-}" ]]; then
            hf_hub_groups["${repo}"]="${file}"
        else
            hf_hub_groups["${repo}"]+=$'\n'"${file}"
        fi
    done < <(jq -r '
        .models[]
        | select(.source == "huggingface")
        | select(.engine == "hf_hub")
        | .repo as $r
        | .files[]
        | [$r, .] | @tsv
    ' "${CONFIG_LOCAL}")

    if [[ "${#hf_hub_groups[@]}" -gt 0 ]]; then
        if ! command -v hf >/dev/null 2>&1; then
            printf "!! ERROR: hf CLI not found but config has %d hf_hub model(s)\n" "${#hf_hub_groups[@]}" >&2
            printf "   (pip install huggingface_hub[cli] or change engine to 'xet' in config)\n" >&2
            return 1
        fi
        # mirror token to both env names so hf CLI picks it up regardless of which was set
        [[ -n "${HF_TOKEN:-}" ]] && export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
        [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]] && export HF_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
        local hf_hub_failure_count=0
        for repo in "${!hf_hub_groups[@]}"; do
            mapfile -t files <<< "${hf_hub_groups[${repo}]}"
            printf "==> HF[hf_hub] %s (%d file(s)) — sequential, resumable\n" "${repo}" "${#files[@]}"
            local f
            for f in "${files[@]}"; do
                local out_path="${COMFYUI_DIR}/models/${f}"
                if [[ -f "${out_path}" && -s "${out_path}" ]]; then
                    printf "    SKIP: %s\n" "${f}"
                    continue
                fi
                printf "    GET %s\n" "${f}"
                mkdir -p "$(dirname "${out_path}")"
                if hf download "${repo}" --include "${f}" --local-dir "${COMFYUI_DIR}/models" \
                        ${HF_TOKEN:+--token "${HF_TOKEN}"} 2>&1 | sed 's/^/      /'; then
                    printf "      OK %s\n" "${f}"
                else
                    printf "      FAIL %s\n" "${f}" >&2
                    hf_hub_failure_count=$((hf_hub_failure_count+1))
                fi
            done
        done
        if [[ "${hf_hub_failure_count}" -gt 0 ]]; then
            printf "!! HF[hf_hub]: %d file(s) failed — aborting\n" "${hf_hub_failure_count}" >&2
            return 1
        fi
    fi

    # 3) Non-HF: civitai / url — delegated to providers/civitai.sh and
    #    providers/url.sh. Each defines a download function with the same
    #    signature: <fn>_download <url> <dest_dir> <dest_filename> [token]
    local non_hf_failure_count=0
    while IFS=$'	' read -r src url path; do
        [[ -z "${src}" || -z "${url}" || -z "${path}" ]] && continue
        printf "==> GET [%s] %s -> %s\n" "${src}" "${url}" "${path}"
        local dest_dir="${COMFYUI_DIR}/models/$(dirname "${path}")"
        local dest_filename
        dest_filename="$(basename "${path}")"
        if ! "${src}_download" "${url}" "${dest_dir}" "${dest_filename}" "${CIVITAI_TOKEN:-}"; then
            printf "!! %s download failed: %s\n" "${src}" "${url}" >&2
            non_hf_failure_count=$((non_hf_failure_count+1))
        fi
    done < <(jq -r '
        .models[]
        | select(.source == "civitai" or .source == "url")
        | select(.url and .path)
        | [.source, .url, .path] | @tsv
    ' "${CONFIG_LOCAL}")
    if [[ "${non_hf_failure_count}" -gt 0 ]]; then
        printf "!! Non-HF: %d url(s) failed — aborting\n" "${non_hf_failure_count}" >&2
        return 1
    fi
}


# ---------------------------------------------------------------------------
# Preflights (items 1-3) — run before any heavy download
# ---------------------------------------------------------------------------
provisioning_check_disk() {
    local need_gb=50
    local target="${COMFYUI_DIR}"
    mkdir -p "${target}" 2>/dev/null || true
    printf "==> Preflight: disk check (need >= %sGB at %s)\n" "${need_gb}" "${target}"
    df -h "${target}" 2>/dev/null | sed 's/^/    /' || true
    local avail_gb
    avail_gb=$(df --output=avail -BG "${target}" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [[ -z "${avail_gb}" ]]; then
        printf "!! WARN: could not determine free space — continuing\n" >&2
        return 0
    fi
    printf "    Free: %sGB\n" "${avail_gb}"
    if [[ "${avail_gb}" -lt "${need_gb}" ]]; then
        printf "!! ERROR: Need %sGB free at %s, have %sGB — pick a larger disk template\n" "${need_gb}" "${target}" "${avail_gb}" >&2
        printf "   Vast lets you pick disk size at create time; 20GB will stall at 40GB\n" >&2
        return 1
    fi
}

provisioning_check_gpu() {
    printf "==> Preflight: GPU/VRAM check\n"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf "!! WARN: nvidia-smi not found — cannot check VRAM\n" >&2
        return 0
    fi
    nvidia-smi --query-gpu=name,total_memory --format=csv,noheader 2>/dev/null | sed 's/^/    /' || true
    local vram_mb
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
    if [[ -n "${vram_mb}" ]]; then
        local vram_gb=$(( (vram_mb + 512) / 1024 ))
        printf "    VRAM: %s MB (~%s GB)\n" "${vram_mb}" "${vram_gb}"
        if [[ "${vram_mb}" -lt 32768 ]]; then
            printf "    VRAM < 32GB — forcing --lowvram (prevents OOM hang)\n"
            if [[ "${COMFYUI_ARGS:-}" != *"--lowvram"* ]]; then
                export COMFYUI_ARGS="${COMFYUI_ARGS:-} --lowvram"
                printf "    COMFYUI_ARGS now: %s\n" "${COMFYUI_ARGS}"
            fi
            # Also ensure the Vast supervisor sees it
            export COMFYUI_ARGS
        fi
    fi
}

provisioning_validate_tokens() {
    printf "==> Preflight: token check\n"
    # Hugging Face — only validate if a token is present AND any H3 file will need it
    # Private/gated models will 401 without it; public ones are fine without.
    if [[ -n "${HF_TOKEN:-}" || -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
        local hf_token_val="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
        printf "    HF_TOKEN set (%s...) — validating... " "${hf_token_val:0:6}"
        if provisioning_has_valid_hf_token; then
            printf "OK (200)\n"
        else
            printf "FAILED\n" >&2
            printf "!! ERROR: HF_TOKEN invalid (401) — check Vast env / HF_TOKEN, not HUGGING_FACE_HUB_TOKEN typo\n" >&2
            printf "   Without a valid token private/gated pulls will 401 x7 after 10 min\n" >&2
            return 1
        fi
    else
        printf "    HF_TOKEN not set — assuming public/gated-with-no-token path (may 401 on private)\n"
    fi
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        printf "    CIVITAI_TOKEN set — validating... "
        if provisioning_has_valid_civitai_token; then
            printf "OK\n"
        else
            printf "FAILED (non-200)\n" >&2
        fi
    fi
}

provisioning_verify_h3_weights() {
    # Verify files listed in config.json. Each model in the config has either:
    #   - .source = "huggingface"  → .files[]  (per-file: check /tmp/hf_xet_expect tag)
    #   - .source = "civitai"|"url" → .path     (just check file exists and >1M)
    # Expected sizes are stored by hf_xet_download.sh as /tmp/hf_xet_expect.*.<name>
    # tag files (Content-Length from HEAD).
    local base="${COMFYUI_DIR}/models"
    local failures=0
    printf "==> Verify: weights size vs expected (config-driven)\n"

    if [[ ! -f "${CONFIG_LOCAL}" ]]; then
        printf "!! Verify: no config at %s — nothing to verify\n" "${CONFIG_LOCAL}" >&2
        return 1
    fi

    # Emit one TSV row per file to verify: source<TAB>relpath<TAB>expect (or empty)
    local verify_tsv
    verify_tsv="$(mktemp)"
    if ! jq -r '
        .models[]?
        | if .source == "huggingface" then
            .files[]? as $f
            | [ "huggingface", $f, "" ]
          elif .source == "civitai" or .source == "url" then
            [ .source, (.path // ""), "" ]
          else empty
          end
        | @tsv
    ' "${CONFIG_LOCAL}" > "${verify_tsv}"; then
        printf "!! Verify: jq failed to parse %s\n" "${CONFIG_LOCAL}" >&2
        rm -f "${verify_tsv}"
        return 1
    fi

    local src rel expect expect_file actual
    local line_no=0
    while IFS=$'\t' read -r src rel expect; do
        line_no=$((line_no+1))
        [[ -z "${rel}" ]] && continue
        local path="${base}/${rel}"
        local name
        name=$(basename "${rel}")
        # Look for an expect-size tag. Prefer the exact one; fall back to glob.
        # Use a fixed glob + null-safe handling: `ls` exits 2 when the glob has
        # no matches, which would trip `set -e` inside the command substitution
        # (pipefail propagates it). Use `compgen -G` or a here-string trick.
        shopt -s nullglob
        expect_file=( /tmp/hf_xet_expect.*."${name}" )
        shopt -u nullglob
        expect_file="${expect_file[0]:-}"
        if [[ -z "${expect_file}" ]]; then
            expect_file=$(find /tmp -maxdepth 2 -name "hf_xet_expect.*.${name}" -type f 2>/dev/null | head -1)
        fi
        expect=""
        if [[ -n "${expect_file}" && -f "${expect_file}" ]]; then
            expect=$(tr -dc '0-9' < "${expect_file}" | head -c 20)
        fi
        if [[ ! -f "${path}" ]]; then
            printf "    FAIL  %-60s missing\n" "${rel}" >&2
            failures=$((failures+1))
            continue
        fi
        actual=$(stat -c %s "${path}" 2>/dev/null || echo 0)
        if [[ "${actual}" -eq 0 ]]; then
            printf "    FAIL  %-60s 0B (corrupt)\n" "${rel}" >&2
            failures=$((failures+1))
            continue
        fi
        if [[ -n "${expect}" && "${expect}" != "0" ]]; then
            # allow 1% slack for header vs actual (LFS pointer etc)
            local diff=$(( actual > expect ? actual - expect : expect - actual ))
            local slack=$(( expect / 100 ))
            if [[ "${diff}" -gt "${slack}" && "${actual}" -lt "${expect}" ]]; then
                printf "    FAIL  %-60s short: %s vs expected %s\n" "${rel}" "${actual}" "${expect}" >&2
                failures=$((failures+1))
                continue
            fi
            printf "    OK    %-60s %s (expected %s)\n" "${rel}" "${actual}" "${expect}"
        else
            # No expected — for HF engines, just ensure >100M; for civitai/url, >1M.
            local min_size_bytes=1048576
            [[ "${src}" == "huggingface" ]] && min_size_bytes=104857600
            if [[ "${actual}" -lt "${min_size_bytes}" ]]; then
                printf "    FAIL  %-60s too small: %s (min %s)\n" "${rel}" "${actual}" "${min_size_bytes}" >&2
                failures=$((failures+1))
            else
                printf "    OK    %-60s %s (no expected, >%s)\n" "${rel}" "${actual}" "${min_size_bytes}"
            fi
        fi
    done < "${verify_tsv}"
    rm -f "${verify_tsv}"

    if [[ "${failures}" -gt 0 ]]; then
        printf "!! Verify: %s file(s) failed — will trigger re-download or abort\n" "${failures}" >&2
        return 1
    fi
    printf "==> Verify: all weights OK\n"
}

function provisioning_start() {
    printf "==> Provisioning started\n"
    provisioning_print_header
    provisioning_check_disk || exit 1
    provisioning_check_gpu || true
    provisioning_validate_tokens || exit 1
    provisioning_get_apt_packages
    # Load config (PROVISIONING_CONFIG_URL, sibling config.json, or DEFAULT_CONFIG_URL)
    # Apply config -> env (HF Xet settings) + NODES (modules)
    provisioning_load_config || true
    provisioning_apply_config || true
    provisioning_get_nodes
    provisioning_get_pip_packages
    printf "==> Downloading models from config\n"
    provisioning_get_models
    local download_rc=$?
    printf "==> Model download phase finished (rc=%s)\n" "${download_rc}"
    if [[ ${download_rc} -ne 0 ]]; then
        printf "!! Model download failed (rc=%s) — not verifying\n" "${download_rc}" >&2
        exit 1
    fi
    provisioning_verify_h3_weights || exit 1
    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
            APT_INSTALL="${APT_INSTALL:-apt-get install -y}"
            # Vast's provisioner already runs as root, no sudo needed.
            # apt-get update first in case the base image has a stale index.
            apt-get update -qq && $APT_INSTALL "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
            pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        # Support an optional "@branch" suffix (e.g. "https://github.com/owner/repo@dev")
        branch=""
        if [[ "${repo}" == *"@"* ]]; then
            branch="${repo##*@}"
            repo="${repo%@*}"
        fi
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                   pip install --no-cache-dir -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            if [[ -n $branch ]]; then
                git clone -b "${branch}" "${repo}" "${path}" --recursive
            else
                git clone "${repo}" "${path}" --recursive
            fi
            if [[ -e $requirements ]]; then
                pip install --no-cache-dir -r "$requirements"
            fi
        fi
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "${HF_TOKEN:-}${HUGGING_FACE_HUB_TOKEN:-}" ]] || return 1
    local hf_token_val="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
    local api_url="https://huggingface.co/api/whoami-v2"
    local http_status
    http_status=$(curl -o /dev/null -s -w "%{http_code}" -X GET "${api_url}" \
        -H "Authorization: Bearer ${hf_token_val}" \
        -H "Content-Type: application/json")
    [[ "${http_status}" -eq 200 ]]
}

function provisioning_has_valid_civitai_token() {
    [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
    local api_url="https://civitai.com/api/v1/models?hidden=1&limit=1"
    local http_status
    http_status=$(curl -o /dev/null -s -w "%{http_code}" -X GET "${api_url}" \
        -H "Authorization: Bearer ${CIVITAI_TOKEN}" \
        -H "Content-Type: application/json")
    [[ "${http_status}" -eq 200 ]]
}

# ---------------------------------------------------------------------------
# /usr/local/bin/vast-h3 — runtime reloader for in-Vast maintenance.
# Two files installed:
#   /usr/local/bin/vast-h3           — the CLI dispatcher
#   /usr/local/share/vast-h3-funcs.sh — function definitions only (loader
#     sources this so it can re-run provisioning_load_config / _apply_config /
#     _get_nodes / _get_models / _verify_h3_weights / preflights without
#     re-running the whole provisioning_start pipeline).
# Usage:
#   vast-h3 status                # show config source + on-disk model state
#   vast-h3 reload config         # re-fetch PROVISIONING_CONFIG_URL
#   vast-h3 reload modules        # re-apply config, re-clone custom nodes
#   vast-h3 reload models         # re-download any missing/short files
#   vast-h3 reload all            # modules + models
#   vast-h3 verify                # re-run provisioning_verify_h3_weights
#   vast-h3 preflight             # re-run disk/gpu/token checks
#   vast-h3 help
# ---------------------------------------------------------------------------
vast_h3_install_loader() {
    local loader="/usr/local/bin/vast-h3"
    local funcs_src="/tmp/vast-h3-functions.sh"
    local providers_dir="/tmp/vast-h3-providers"
    # Extract everything in this file UP TO (but not including) the
    # "Allow user to disable provisioning" block at the bottom. That's the
    # function definitions plus the helpers.
    awk '
        /^# Allow user to disable provisioning if they started/ { exit }
        { print }
    ' "${VAST_H3_SCRIPT}" > "${funcs_src}"
    # The providers/ dir was already fetched + extracted to
    # /tmp/vast-h3-providers/ at startup (provisioning_load_providers). On
    # Vast, the script is at /provisioning.sh — there's no providers/ dir
    # next to it. Export VAST_H3_PROVIDERS_DIR so the extracted funcs file
    # (which lives at /tmp/ and re-sources everything) finds the providers.
    export VAST_H3_PROVIDERS_DIR="${providers_dir}"
    cat > "${loader}" << 'VAST_H3_EOF'
#!/bin/bash
# vast-h3 — runtime reloader; auto-generated by default.sh. Do not edit.
set -euo pipefail

# Locate the functions file written by default.sh.
# We install to /tmp/ since /usr/local/ may be unwritable for the user.
VastH3_Funcs=""
for cand in \
    "/tmp/vast-h3-functions.sh" \
    "/usr/local/share/vast-h3-funcs.sh" \
    "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")")/vast-h3-functions.sh"; do
    if [[ -f "${cand}" ]]; then VastH3_Funcs="${cand}"; break; fi
done
if [[ -z "${VastH3_Funcs}" ]]; then
    echo "vast-h3: cannot find functions file (looked in /tmp, /usr/local/share, script dir)" >&2
    exit 127
fi

# Mark this file as sourced so its own auto-execution of provisioning
# (and the vast_h3_install_loader call) is skipped.
export VAST_H3_SOURCED=1
# Point the provider loader at the bundled providers/ dir.
export VAST_H3_PROVIDERS_DIR="/tmp/vast-h3-providers"

# shellcheck disable=SC1090
source "${VastH3_Funcs}"

# Activate venv if present (matches default.sh behavior).
if [[ -f /venv/main/bin/activate ]]; then
    set +e
    # shellcheck disable=SC1091
    source /venv/main/bin/activate
    set -e
fi

vast_h3_status() {
    printf "==> vast-h3 status\n"
    printf "    functions file   : %s\n" "${VastH3_Funcs}"
    printf "    config_local     : %s\n" "${CONFIG_LOCAL:-/tmp/provisioning_config.json}"
    printf "    config_url       : %s\n" "${PROVISIONING_CONFIG_URL:-(unset)}"
    printf "    comfyui_dir      : %s\n" "${COMFYUI_DIR:-/ComfyUI}"
    if [[ -f "${CONFIG_LOCAL:-/tmp/provisioning_config.json}" ]]; then
        printf "    config_source    : %s\n" \
            "$(python3 -c 'import json,pathlib; c=json.loads(pathlib.Path("'"${CONFIG_LOCAL}"'").read_text()); eng=c.get("huggingface",{}).get("downloads",[{}])[0].get("engine","?"); print("hf engine="+eng)' 2>/dev/null || echo "?")"
    else
        printf "    config_source    : (no config loaded)\n"
    fi
    printf "    models expected  :\n"
    if [[ -f "${CONFIG_LOCAL:-/tmp/provisioning_config.json}" ]]; then
        local comfyui_dir_local="${COMFYUI_DIR:-/ComfyUI}"
        # Pass both CONFIG_LOCAL and HF_Xet expect cache dir so the python
        # can also check the per-file expected size when available.
        COMFYUI_DIR="${comfyui_dir_local}" \
        HF_XET_EXPECT_DIR="/tmp" \
        python3 << 'PYEOF'
import json, os, pathlib, glob
c = json.loads(pathlib.Path(os.environ.get("CONFIG_LOCAL", "/tmp/provisioning_config.json")).read_text())
base = pathlib.Path(os.environ["COMFYUI_DIR"]) / "models"

# Try to find per-file expected sizes written by hf_xet_download.sh:
#   /tmp/hf_xet_expect.*.<filename>
expect_cache = pathlib.Path(os.environ.get("HF_XET_EXPECT_DIR", "/tmp"))

def expected_size(name: str) -> int | None:
    hits = glob.glob(str(expect_cache / f"hf_xet_expect.*.{name}"))
    if not hits:
        return None
    try:
        text = pathlib.Path(hits[0]).read_text().strip()
        return int("".join(ch for ch in text if ch.isdigit()) or 0) or None
    except Exception:
        return None

for m in c.get("models", []):
    if m.get("source") == "huggingface":
        for f in m.get("files", []):
            p = base / f
            name = pathlib.Path(f).name
            if not (p.exists() and p.stat().st_size > 0):
                status_mark = "MISS"
            else:
                exp = expected_size(name)
                if exp and p.stat().st_size < exp * 0.99:
                    status_mark = "SHORT"
                else:
                    status_mark = "OK  "
            print(f"      [{status_mark}] {f}")
    else:
        p = base / m.get("path","")
        if not (p.exists() and p.stat().st_size > 0):
            status_mark = "MISS"
        else:
            status_mark = "OK  "
        print(f"      [{status_mark}] [{m.get('source')}] {m.get('path')}")
PYEOF
    else
        printf "      (no config)\n"
    fi
}

vast_h3_reload_config() {
    printf "==> reload config\n"
    provisioning_load_config
    printf "    reloaded %s\n" "${CONFIG_LOCAL}"
}

vast_h3_reload_modules() {
    printf "==> reload modules\n"
    provisioning_load_config
    provisioning_apply_config
    provisioning_get_nodes
    printf "    modules reloaded\n"
}

vast_h3_reload_models() {
    printf "==> reload models\n"
    provisioning_load_config
    provisioning_apply_config
    provisioning_get_models
    printf "    model download finished\n"
}

vast_h3_reload_all() {
    vast_h3_reload_modules
    vast_h3_reload_models
}

vast_h3_verify() {
    printf "==> verify\n"
    provisioning_verify_h3_weights
}

vast_h3_preflight() {
    printf "==> preflight\n"
    provisioning_check_disk || true
    provisioning_check_gpu || true
    provisioning_validate_tokens || true
}

vast_h3_help() {
    sed -n '2,15p' "${VastH3_Funcs}"
}

cmd="${1:-help}"
shift || true
case "${cmd}" in
    status)              vast_h3_status ;;
    reload)
        sub="${1:-all}"
        case "${sub}" in
            config)  vast_h3_reload_config ;;
            modules) vast_h3_reload_modules ;;
            models)  vast_h3_reload_models ;;
            all)     vast_h3_reload_all ;;
            *)       echo "vast-h3 reload: unknown subcommand '${sub}' (config|modules|models|all)" >&2; exit 2 ;;
        esac
        ;;
    verify)              vast_h3_verify ;;
    preflight)           vast_h3_preflight ;;
    help|-h|--help)      vast_h3_help ;;
    *)                   echo "vast-h3: unknown command '${cmd}' (status|reload|verify|preflight|help)" >&2; exit 2 ;;
esac
VAST_H3_EOF
    chmod 0755 "${loader}"
    printf "==> Installed loader: %s (%s bytes)\n" "${loader}" "$(wc -c < "${loader}")"
    printf "==> Installed funcs:  %s (%s bytes)\n" "${funcs_src}" "$(wc -c < "${funcs_src}")"
}

# ---------------------------------------------------------------------------
# /workspace/reload-modules.sh — self-contained module reloader.
# Re-clones or git-pulls every entry in config.json:modules[], then restarts
# ComfyUI (via s6 / supervisord / kill-TERM in that order). Lives on the
# workspace so you can `cd /workspace && ./reload-modules.sh` after a node
# push without re-running default.sh.
# ---------------------------------------------------------------------------
vast_h3_install_workspace_reloader() {
    local target="${WORKSPACE:-/workspace}/reload-modules.sh"
    cat > "${target}" << 'WORKSPACE_RELOAD_EOF'
#!/usr/bin/env bash
# /workspace/reload-modules.sh — re-clone/update custom nodes + restart ComfyUI.
# Generated by default.sh; safe to edit if you need to customize the restart
# step (the module list comes from /tmp/provisioning_config.json on each run).

set -euo pipefail

CONFIG_LOCAL="${CONFIG_LOCAL:-/tmp/provisioning_config.json}"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
NODES_DIR="${COMFYUI_DIR}/custom_nodes"
AUTO_UPDATE="${AUTO_UPDATE:-true}"

if [[ ! -f "${CONFIG_LOCAL}" ]]; then
    printf "!! %s not found — has default.sh run yet?\n" "${CONFIG_LOCAL}" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    printf "!! jq not installed (default.sh should have added it to APT_PACKAGES)\n" >&2
    exit 1
fi

mapfile -t MODULES < <(jq -r '.modules[]? // empty' "${CONFIG_LOCAL}" 2>/dev/null)
if [[ ${#MODULES[@]} -eq 0 ]]; then
    printf "==> No modules in config — nothing to do\n"
    exit 0
fi

mkdir -p "${NODES_DIR}"
printf "==> %d module(s) in config\n" "${#MODULES[@]}"

failures=0
for repo in "${MODULES[@]}"; do
    [[ -z "${repo}" ]] && continue
    branch=""
    if [[ "${repo}" == *"@"* ]]; then
        branch="${repo##*@}"
        repo="${repo%@*}"
    fi
    dir="${repo##*/}"
    path="${NODES_DIR}/${dir}"
    requirements="${path}/requirements.txt"
    if [[ -d "${path}/.git" ]]; then
        if [[ "${AUTO_UPDATE,,}" == "false" ]]; then
            printf "    SKIP: %s (AUTO_UPDATE=false)\n" "${dir}"
        else
            printf "    UPDATE: %s\n" "${dir}"
            if ! (cd "${path}" && git pull --ff-only 2>&1 | sed 's/^/      /'); then
                printf "      !! git pull failed for %s\n" "${dir}" >&2
                failures=$((failures+1))
                continue
            fi
        fi
    else
        printf "    CLONE: %s\n" "${dir}"
        clone_args=("${repo}" "${path}" --recursive)
        [[ -n "${branch}" ]] && clone_args=(-b "${branch}" "${clone_args[@]}")
        if ! git clone "${clone_args[@]}" 2>&1 | sed 's/^/      /'; then
            printf "      !! git clone failed for %s\n" "${dir}" >&2
            failures=$((failures+1))
            continue
        fi
    fi
    if [[ -f "${requirements}" ]]; then
        printf "      pip install -r %s\n" "${requirements}"
        # Don't fail on pip errors — many nodes have optional deps.
        pip install --no-cache-dir -r "${requirements}" 2>&1 | sed 's/^/        /' || \
            printf "      !! pip install failed for %s (continuing)\n" "${dir}" >&2
    fi
done

# Restart ComfyUI — try each mechanism; first success wins.
printf "==> Restarting ComfyUI\n"
restart_done=0

# a) s6-overlay (vastai/comfy base image)
if [[ -d /run/service && ${restart_done} -eq 0 ]]; then
    for svc in /run/service/*/; do
        [[ -d "${svc}" ]] || continue
        name=$(basename "${svc}")
        case "${name}" in
            s6rc-oneshot-runner|s6rc-fdholder|s6rc-init-catchall|init-diversity|init-migrations|init-folders|legacy-services|cron|cryptdomain|fix-attrs|log-user|format-*|setup-environment|user-rc-services|cleanup) continue ;;
        esac
        if s6-svcan -t 1000 "/run/service/${name}" >/dev/null 2>&1 || true; then
            # Probe: is this service running a python process?
            if pgrep -af "s6-supervise ${name}" >/dev/null 2>&1; then
                if s6-svc -r "/run/service/${name}" 2>/dev/null; then
                    printf "    s6-svc -r /run/service/%s (OK)\n" "${name}"
                    restart_done=1
                    break
                fi
            fi
        fi
    done
fi

# b) supervisord
if [[ ${restart_done} -eq 0 ]] && command -v supervisorctl >/dev/null 2>&1; then
    for prog in comfyui comfy ComfyUI; do
        if supervisorctl status "${prog}" >/dev/null 2>&1; then
            if supervisorctl restart "${prog}" 2>&1 | sed 's/^/      /'; then
                printf "    supervisorctl restart %s (OK)\n" "${prog}"
                restart_done=1
                break
            fi
        fi
    done
fi

# c) Fallback: SIGTERM the comfyui python process; its supervisor (whatever it is) restarts it.
if [[ ${restart_done} -eq 0 ]]; then
    comfy_pid=$(pgrep -f "python.*(main|server)\.py.*(--listen|--port)" 2>/dev/null | head -1 || true)
    if [[ -n "${comfy_pid}" ]]; then
        printf "    kill -TERM %s (no supervisor found)\n" "${comfy_pid}"
        kill -TERM "${comfy_pid}" 2>/dev/null || true
        restart_done=1
    fi
fi

if [[ ${restart_done} -eq 0 ]]; then
    printf "!! Could not find a way to restart ComfyUI. Restart it manually.\n" >&2
    printf "   (tried: s6-svc, supervisorctl, pgrep kill — none matched)\n" >&2
fi

if [[ ${failures} -gt 0 ]]; then
    printf "!! %d module(s) failed to clone/update — see above\n" "${failures}" >&2
    exit 1
fi
printf "==> Reload complete\n"
WORKSPACE_RELOAD_EOF
    chmod 0755 "${target}"
    printf "==> Installed workspace reloader: %s (%s bytes)\n" "${target}" "$(wc -c < "${target}")"
}

# Install the loader as part of provisioning. Skip when this file is being
# sourced (e.g. by the loader itself or by another tool).
if [[ "${VAST_H3_SOURCED:-0}" != "1" ]]; then
    vast_h3_install_loader || printf "!! vast-h3 loader install failed (non-fatal)\n" >&2
    vast_h3_install_workspace_reloader || printf "!! workspace reloader install failed (non-fatal)\n" >&2
fi

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning && "${VAST_H3_SOURCED:-0}" != "1" ]]; then
    provisioning_start
fi