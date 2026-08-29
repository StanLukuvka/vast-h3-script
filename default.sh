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
declare -a CHECKPOINT_MODELS=()
declare -a UNET_MODELS=()
declare -a LORA_MODELS=()
declare -a CONTROLNET_MODELS=()
declare -a VAE_MODELS=()
declare -a ESRGAN_MODELS=()
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

WORKFLOWS=(

)

CHECKPOINT_MODELS=(
)

UNET_MODELS=(
)

LORA_MODELS=(
)

VAE_MODELS=(
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
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
CONFIG_LOCAL="/tmp/provisioning_config.json"

# Load the standalone Xet downloader (hf_xet_download <repo> <dir> <files...>).
# NOTE: the Vast provisioner writes PROVISIONING_SCRIPT to a fixed path
# (/provisioning.sh) and runs it directly, so BASH_SOURCE sibling resolution
# is unreliable. Instead we fetch the helper from the same raw URL the
# provisioner used for this script. Override via HF_XET_SCRIPT_URL if needed.
HF_XET_SCRIPT_URL="${HF_XET_SCRIPT_URL:-https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/hf_xet_download.sh}"
HF_XET_SCRIPT_LOCAL="/tmp/hf_xet_download.sh"

printf "==> Loading hf_xet_download.sh from %s\n" "${HF_XET_SCRIPT_URL}"
curl -fsSL "${HF_XET_SCRIPT_URL}" -o "${HF_XET_SCRIPT_LOCAL}" 2>/tmp/curl_err.log
CURL_RC=$?
if [[ ${CURL_RC} -ne 0 ]]; then
    printf "!! ERROR: failed to fetch hf_xet_download.sh (curl rc=%s)\n" "${CURL_RC}" >&2
    printf "   %s\n" "$(cat /tmp/curl_err.log 2>/dev/null)" >&2
    exit 1
elif [[ ! -s "${HF_XET_SCRIPT_LOCAL}" ]]; then
    printf "!! ERROR: fetched hf_xet_download.sh but it is empty\n" >&2
    exit 1
else
    # shellcheck source=/dev/null
    source "${HF_XET_SCRIPT_LOCAL}"
    if [[ "$(type -t hf_xet_download)" != "function" ]]; then
        printf "!! ERROR: hf_xet_download.sh sourced but hf_xet_download() not defined\n" >&2
        printf "   First 5 lines of fetched file:\n" >&2
        head -5 "${HF_XET_SCRIPT_LOCAL}" >&2
    else
        printf "==> hf_xet_download() loaded OK (%s bytes)\n" "$(wc -c < "${HF_XET_SCRIPT_LOCAL}")"
    fi
fi

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
    # Local file
    if [[ -f "${url}" ]]; then
        cp "${url}" "${CONFIG_LOCAL}"
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
        n = settings.get("concurrent_range_gets")
        if n is not None:
            print(f"export HF_XET_NUM_CONCURRENT_RANGE_GETS={int(n)}")
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
mods = cfg.get("modules", [])
if mods:
    nodes = []
    for m in mods:
        url = m.get("url", "")
        branch = m.get("branch", "")
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
    local n_models
    n_models=$(python3 -c "import json,pathlib; print(len(json.loads(pathlib.Path('/tmp/provisioning_config.json').read_text()).get('models',[])))" 2>/dev/null || echo 0)
    printf "==> Config: %s model(s), %s module(s)\n" "${n_models}" "${#NODES[@]}"
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

    local n_models
    n_models=$(jq '.models | length' "${CONFIG_LOCAL}")
    if [[ "${n_models}" -eq 0 ]]; then
        printf "==> No models in config — nothing to download\n"
        return 0
    fi
    printf "==> Downloading %s model(s) from config\n" "${n_models}"

    # 1) HF xet: group all files per repo, one hf_xet_download call per repo.
    #    We use --raw-output (-r) so jq emits one line of `files[N]` per file
    #    with no JSON quoting — then mapfile reads them as plain strings.
    declare -A hf_xet_groups=()
    while IFS=$'	' read -r repo file; do
        [[ -z "${repo}" || -z "${file}" ]] && continue
        if [[ -z "${hf_xet_groups[${repo}]:-}" ]]; then
            hf_xet_groups["${repo}"]="${file}"
        else
            hf_xet_groups["${repo}"]+=$'\n'"${file}"
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
    for repo in "${!hf_xet_groups[@]}"; do
        mapfile -t files <<< "${hf_xet_groups[${repo}]}"
        printf "==> HF[xet] %s (%d file(s)) -> %s\n" "${repo}" "${#files[@]}" "${COMFYUI_DIR}/models"
        hf_xet_download "${repo}" "${COMFYUI_DIR}/models" "${files[@]}" || {
            printf "!! WARN: hf_xet_download failed for %s — continuing\n" "${repo}" >&2
        }
    done

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

    if [[ "${#hf_hub_groups[@]}" -gt 0 ]] && ! command -v hf >/dev/null 2>&1; then
        printf "!! ERROR: hf CLI not found — cannot run hf_hub engine\n" >&2
    else
        for repo in "${!hf_hub_groups[@]}"; do
            mapfile -t files <<< "${hf_hub_groups[${repo}]}"
            printf "==> HF[hf_hub] %s (%d file(s)) — sequential, resumable\n" "${repo}" "${#files[@]}"
            # mirror token to both env names
            [[ -n "${HF_TOKEN:-}" ]] && export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
            [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]] && export HF_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
            local f out_path
            for f in "${files[@]}"; do
                out_path="${COMFYUI_DIR}/models/${f}"
                if [[ -f "${out_path}" && -s "${out_path}" ]]; then
                    printf "    SKIP: %s\n" "${f}"
                    continue
                fi
                printf "    GET %s\n" "${f}"
                mkdir -p "$(dirname "${out_path}")"
                if hf download "${repo}" --include "${f}" --local-dir "${COMFYUI_DIR}/models" \
                        ${HF_TOKEN:+--token "${HF_TOKEN}"} >/dev/null 2>&1; then
                    printf "      OK %s\n" "${f}"
                elif hf download "${repo}" --include "${f}" --local-dir "${COMFYUI_DIR}/models" >/dev/null 2>&1; then
                    printf "      OK (no token) %s\n" "${f}"
                else
                    printf "      FAIL %s\n" "${f}" >&2
                fi
            done
        done
    fi

    # 3) Non-HF: civitai / url. No engine choice; aria2c if present, else wget -c.
    while IFS=$'	' read -r src url path; do
        [[ -z "${src}" || -z "${url}" || -z "${path}" ]] && continue
        local dest_dir="${COMFYUI_DIR}/models/$(dirname "${path}")"
        local dest_file="${COMFYUI_DIR}/models/${path}"
        mkdir -p "${dest_dir}"
        if [[ -f "${dest_file}" && -s "${dest_file}" ]]; then
            printf "==> SKIP (already exists): %s\n" "${path}"
            continue
        fi
        printf "==> GET [%s] %s -> %s\n" "${src}" "${url}" "${path}"
        local auth_token=""
        [[ "${src}" == "civitai" ]] && auth_token="${CIVITAI_TOKEN:-}"
        if command -v aria2c >/dev/null 2>&1; then
            local aria_args=(-x16 -s16 -k8M --continue=true --file-allocation=none \
                             --auto-file-renaming=false --allow-overwrite=false \
                             --retry-wait=3 --console-log-level=warn \
                             --dir="${dest_dir}" --out="$(basename "${path}")")
            [[ -n "${auth_token}" ]] && aria_args+=(--header="Authorization: Bearer ${auth_token}")
            if ! aria2c "${aria_args[@]}" "${url}"; then
                printf "    aria2c failed, falling back to wget -c\n" >&2
                provisioning_download "${url}" "${dest_dir}"
            fi
        else
            provisioning_download "${url}" "${dest_dir}"
        fi
        if [[ ! -f "${dest_file}" ]]; then
            local newest
            newest=$(ls -t "${dest_dir}" 2>/dev/null | head -1)
            if [[ -n "${newest}" && -f "${dest_dir}/${newest}" ]]; then
                if [[ "${newest}" != "$(basename "${path}")" ]]; then
                    mv "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || \
                        cp "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || true
                fi
            fi
        fi
    done < <(jq -r '
        .models[]
        | select(.source == "civitai" or .source == "url")
        | select(.url and .path)
        | [.source, .url, .path] | @tsv
    ' "${CONFIG_LOCAL}")
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
        local tok="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
        printf "    HF_TOKEN set (%s...) — validating... " "${tok:0:6}"
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
    local verify_tmp
    verify_tmp="$(mktemp)"
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
    ' "${CONFIG_LOCAL}" > "${verify_tmp}"; then
        printf "!! Verify: jq failed to parse %s\n" "${CONFIG_LOCAL}" >&2
        rm -f "${verify_tmp}"
        return 1
    fi

    local src rel expect expect_file actual
    local line_n=0
    while IFS=$'\t' read -r src rel expect; do
        line_n=$((line_n+1))
        [[ -z "${rel}" ]] && continue
        local path="${base}/${rel}"
        local name
        name=$(basename "${rel}")
        # Look for an expect-size tag. Prefer the exact one; fall back to glob.
        expect_file=$(ls /tmp/hf_xet_expect.*."${name}" 2>/dev/null | head -1)
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
            local min_size=1048576
            [[ "${src}" == "huggingface" ]] && min_size=104857600
            if [[ "${actual}" -lt "${min_size}" ]]; then
                printf "    FAIL  %-60s too small: %s (min %s)\n" "${rel}" "${actual}" "${min_size}" >&2
                failures=$((failures+1))
            else
                printf "    OK    %-60s %s (no expected, >%s)\n" "${rel}" "${actual}" "${min_size}"
            fi
        fi
    done < "${verify_tmp}"
    rm -f "${verify_tmp}"

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
    local models_rc=$?
    printf "==> Model download phase finished (rc=%s)\n" "${models_rc}"
    if [[ ${models_rc} -ne 0 ]]; then
        printf "!! Model download failed (rc=%s) — not verifying\n" "${models_rc}" >&2
        exit 1
    fi
    provisioning_verify_h3_weights || exit 1
    provisioning_get_files \
        "${COMFYUI_DIR}/models/checkpoints" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/lora" \
        "${LORA_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/esrgan" \
        "${ESRGAN_MODELS[@]}"
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

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    
    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
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
    url="https://huggingface.co/api/whoami-v2"
    local tok="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer ${tok}" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer ${CIVITAI_TOKEN}" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# Download from $1 URL to $2 file path
function provisioning_download() {
    if [[ -n "${HF_TOKEN:-}" && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif 
        [[ -n "${CIVITAI_TOKEN:-}" && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n $auth_token ]];then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    fi
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
    # Extract everything in this file UP TO (but not including) the
    # "Allow user to disable provisioning" block at the bottom. That's the
    # function definitions plus the helpers.
    awk '
        /^# Allow user to disable provisioning if they started/ { exit }
        { print }
    ' "${VAST_H3_SCRIPT}" > "${funcs_src}"
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
        local _comfyui_dir="${COMFYUI_DIR:-/ComfyUI}"
        # Pass both CONFIG_LOCAL and HF_Xet expect cache dir so the python
        # can also check the per-file expected size when available.
        COMFYUI_DIR="${_comfyui_dir}" \
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
                mark = "MISS"
            else:
                exp = expected_size(name)
                if exp and p.stat().st_size < exp * 0.99:
                    mark = "SHORT"
                else:
                    mark = "OK  "
            print(f"      [{mark}] {f}")
    else:
        p = base / m.get("path","")
        if not (p.exists() and p.stat().st_size > 0):
            mark = "MISS"
        else:
            mark = "OK  "
        print(f"      [{mark}] [{m.get('source')}] {m.get('path')}")
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
restarted=0

# a) s6-overlay (vastai/comfy base image)
if [[ -d /run/service && ${restarted} -eq 0 ]]; then
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
                    restarted=1
                    break
                fi
            fi
        fi
    done
fi

# b) supervisord
if [[ ${restarted} -eq 0 ]] && command -v supervisorctl >/dev/null 2>&1; then
    for prog in comfyui comfy ComfyUI; do
        if supervisorctl status "${prog}" >/dev/null 2>&1; then
            if supervisorctl restart "${prog}" 2>&1 | sed 's/^/      /'; then
                printf "    supervisorctl restart %s (OK)\n" "${prog}"
                restarted=1
                break
            fi
        fi
    done
fi

# c) Fallback: SIGTERM the comfyui python process; its supervisor (whatever it is) restarts it.
if [[ ${restarted} -eq 0 ]]; then
    comfy_pid=$(pgrep -f "python.*(main|server)\.py.*(--listen|--port)" 2>/dev/null | head -1 || true)
    if [[ -n "${comfy_pid}" ]]; then
        printf "    kill -TERM %s (no supervisor found)\n" "${comfy_pid}"
        kill -TERM "${comfy_pid}" 2>/dev/null || true
        restarted=1
    fi
fi

if [[ ${restarted} -eq 0 ]]; then
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