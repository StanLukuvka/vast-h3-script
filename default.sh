#!/bin/bash
set -euo pipefail

# Vast.ai writes instance env vars (e.g. -e HF_TOKEN=...) to /etc/environment
# inside the container, but the provisioning process sometimes runs without
# them exported. Load them explicitly so tokens reach the downloaders.
if [[ -f /etc/environment ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/environment
    set +a
fi

source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE:-/workspace}/ComfyUI"

# ---------------------------------------------------------------------------
# CONFIG — loaded from PROVISIONING_CONFIG (env URL) at runtime
# ---------------------------------------------------------------------------
# Two-stage flow:
#   PROVISIONING_SCRIPT  = default.sh   (this file, the provisioner)
#   PROVISIONING_CONFIG  = config.json  (public, in repo — declares downloads/models/modules)
# Vast template sets both via --env. We fetch CONFIG at boot so the repo is
# the single source of truth; no hardcoded model lists here.
PROVISIONING_CONFIG_URL="${PROVISIONING_CONFIG:-${CONFIG_URL:-}}"
DEFAULT_CONFIG_URL="https://raw.githubusercontent.com/StanLukuvka/vast-h3-script/main/config.json"
CONFIG_LOCAL="/tmp/provisioning_config.json"

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

function provisioning_start() {
    printf "==> Provisioning started\n"
    provisioning_print_header
    provisioning_get_apt_packages
    # Load config before nodes/models so modules + downloads settings apply
    provisioning_load_config || true
    provisioning_apply_config || true
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_get_models
    printf "==> Model download phase finished (rc=%s)\n" "$?"
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

# ---------------------------------------------------------------------------
# Config loader — fetches PROVISIONING_CONFIG into $CONFIG_LOCAL and
# populates NODES / models via python3. No jq dependency.
# ---------------------------------------------------------------------------
provisioning_load_config() {
    local url=""
    if [[ -n "${PROVISIONING_CONFIG_URL:-}" ]]; then
        url="${PROVISIONING_CONFIG_URL}"
    elif [[ -n "${PROVISIONING_CONFIG:-}" ]]; then
        url="${PROVISIONING_CONFIG}"
    fi

    if [[ "${url}" == "{"* ]]; then
        printf "%s" "${url}" > "${CONFIG_LOCAL}"
        printf "==> PROVISIONING_CONFIG is inline JSON (%s bytes)\n" "$(wc -c < "${CONFIG_LOCAL}")"
        return 0
    fi

    if [[ -n "${url}" ]]; then
        if [[ "${url}" =~ ^https?:// ]]; then
            printf "==> Fetching provisioning config from %s\n" "${url}"
            if ! curl -fsSL "${url}" -o "${CONFIG_LOCAL}" 2>/tmp/config_curl_err.log; then
                printf "!! WARN: failed to fetch PROVISIONING_CONFIG (%s) — will try fallback\n" "${url}" >&2
                cat /tmp/config_curl_err.log 2>/dev/null | head -20 >&2 || true
                url=""
            elif [[ ! -s "${CONFIG_LOCAL}" ]]; then
                printf "!! WARN: fetched config is empty — will try fallback\n" >&2
                url=""
            else
                printf "==> Config fetched OK (%s bytes) from %s\n" "$(wc -c < "${CONFIG_LOCAL}")" "${url}"
                return 0
            fi
        elif [[ -f "${url}" ]]; then
            printf "==> Using local provisioning config %s\n" "${url}"
            cp "${url}" "${CONFIG_LOCAL}"
            return 0
        else
            printf "!! WARN: PROVISIONING_CONFIG=%s is not a URL or file — will try fallback\n" "${url}" >&2
            url=""
        fi
    fi

    local sibling=""
    for cand in "$(dirname "${BASH_SOURCE[0]:-}")/config.json" "./config.json" "/workspace/vast-h3-script/config.json"; do
        if [[ -f "${cand}" ]]; then sibling="${cand}"; break; fi
    done
    if [[ -n "${sibling}" ]]; then
        printf "==> Using sibling config %s\n" "${sibling}"
        cp "${sibling}" "${CONFIG_LOCAL}"
        return 0
    fi

    printf "==> Fetching default config from %s\n" "${DEFAULT_CONFIG_URL}"
    if curl -fsSL "${DEFAULT_CONFIG_URL}" -o "${CONFIG_LOCAL}" 2>/tmp/config_curl_err.log; then
        if [[ -s "${CONFIG_LOCAL}" ]]; then
            printf "==> Default config fetched OK (%s bytes)\n" "$(wc -c < "${CONFIG_LOCAL}")"
            return 0
        fi
    fi
    printf "!! WARN: no provisioning config available — using hardcoded fallback\n" >&2
    cat /tmp/config_curl_err.log 2>/dev/null | head -20 >&2 || true
    return 1
}

provisioning_apply_config() {
    if [[ ! -f "${CONFIG_LOCAL}" ]]; then
        printf "!! provisioning_apply_config: no %s — skipping\n" "${CONFIG_LOCAL}" >&2
        return 1
    fi
    if ! python3 -m json.tool "${CONFIG_LOCAL}" >/dev/null 2>&1; then
        printf "!! provisioning_apply_config: %s is not valid JSON — skipping\n" "${CONFIG_LOCAL}" >&2
        head -20 "${CONFIG_LOCAL}" >&2 || true
        return 1
    fi

    local py_out
    py_out=$(python3 << 'PYEOF'
import json, shlex, pathlib
cfg = json.loads(pathlib.Path("/tmp/provisioning_config.json").read_text())
for d in cfg.get("downloads", []):
    engine = d.get("engine", "")
    settings = d.get("settings", {})
    if engine == "xet":
        if settings.get("high_performance"):
            print("export HF_XET_HIGH_PERFORMANCE=1")
        n = settings.get("concurrent_range_gets")
        if n is not None:
            print(f"export HF_XET_NUM_CONCURRENT_RANGE_GETS={int(n)}")
for k, v in cfg.get("env", {}).items():
    if k.replace("_","").isalnum():
        print(f"export {k}={shlex.quote(str(v))}")
mods = cfg.get("modules", [])
if mods:
    nodes = []
    for m in mods:
        url = m.get("url","")
        branch = m.get("branch","")
        if branch and "${" not in branch and "@" not in url:
            nodes.append(f"{url}@{branch}")
        else:
            if branch:
                nodes.append(f"{url}@{branch}")
            else:
                nodes.append(url)
    quoted = " ".join(shlex.quote(n) for n in nodes)
    print(f"NODES=({quoted})")
PYEOF
)
    if [[ -n "${py_out}" ]]; then
        printf "==> Applying config env/modules:\n"
        printf "%s\n" "${py_out}" | sed 's/^/    /'
        eval "${py_out}"
    fi

    local n_models
    n_models=$(python3 -c "import json,pathlib; print(len(json.loads(pathlib.Path('/tmp/provisioning_config.json').read_text()).get('models',[])))")
    printf "==> Config: %s model(s), %s module(s)\n" "${n_models}" "${#NODES[@]}"
}

# Generic provider-agnostic model fetcher driven by config.json models[].
# Each entry: {provider, url, path, engine}
provisioning_get_models() {
    if [[ ! -f "${CONFIG_LOCAL}" ]]; then
        printf "!! provisioning_get_models: no config — falling back to hardcoded H3 weights\n" >&2
        provisioning_get_h3_weights
        return $?
    fi

    if ! python3 -c "import json,pathlib,sys; json.loads(pathlib.Path('${CONFIG_LOCAL}').read_text())" 2>/dev/null; then
        printf "!! provisioning_get_models: invalid JSON — fallback\n" >&2
        provisioning_get_h3_weights
        return $?
    fi

    local tsv="/tmp/provisioning_models.tsv"
    python3 << 'PYEOF' > "${tsv}"
import json, pathlib
cfg = json.loads(pathlib.Path("/tmp/provisioning_config.json").read_text())
for m in cfg.get("models", []):
    provider = m.get("provider","url")
    url = m.get("url","")
    path = m.get("path","")
    engine = m.get("engine","xet")
    print(f"{provider}\t{url}\t{path}\t{engine}")
PYEOF

    if [[ ! -s "${tsv}" ]]; then
        printf "==> No models in config — nothing to download\n"
        return 0
    fi

    printf "==> Downloading %s model(s) from config\n" "$(wc -l < "${tsv}")"

    declare -A xet_groups
    declare -a generic_queue

    while IFS=$'\t' read -r provider url path engine; do
        [[ -z "${url}" || -z "${path}" ]] && continue
        if [[ "${provider}" == "huggingface" && "${engine}" == "xet" && "${url}" == *"huggingface.co/"*"/resolve/"* ]]; then
            repo=$(printf "%s" "${url}" | sed -E 's|.*huggingface\.co/([^/]+/[^/]+)/resolve/.*|\1|')
            file=$(printf "%s" "${url}" | sed -E 's|.*/resolve/[^/]+/||')
            if [[ "${file}" == "${url}" ]]; then file="${path}"; fi
            if [[ -z "${xet_groups[${repo}]:-}" ]]; then
                xet_groups["${repo}"]="${file}"
            else
                xet_groups["${repo}"]+=$'\n'"${file}"
            fi
        else
            generic_queue+=("${provider}	${url}	${path}	${engine}")
        fi
    done < "${tsv}"

    for repo in "${!xet_groups[@]}"; do
        mapfile -t files <<< "${xet_groups[${repo}]}"
        printf "==> Xet: %s (%d file(s)) -> %s\n" "${repo}" "${#files[@]}" "${COMFYUI_DIR}/models"
        hf_xet_download "${repo}" "${COMFYUI_DIR}/models" "${files[@]}" || {
            printf "!! WARN: hf_xet_download failed for %s — continuing\n" "${repo}" >&2
        }
    done

    for entry in "${generic_queue[@]:-}"; do
        IFS=$'\t' read -r provider url path engine <<< "${entry}"
        dest_dir="${COMFYUI_DIR}/models/$(dirname "${path}")"
        dest_file="${COMFYUI_DIR}/models/${path}"
        mkdir -p "${dest_dir}"
        if [[ -f "${dest_file}" && -s "${dest_file}" ]]; then
            printf "==> SKIP (already exists): %s\n" "${path}"
            continue
        fi
        printf "==> GET [%s/%s] %s -> %s\n" "${provider}" "${engine}" "${url}" "${path}"
        auth_token=""
        if [[ "${provider}" == "huggingface" && -n "${HF_TOKEN:-}" ]]; then
            auth_token="${HF_TOKEN}"
        elif [[ "${provider}" == "civitai" && -n "${CIVITAI_TOKEN:-}" ]]; then
            auth_token="${CIVITAI_TOKEN}"
        elif [[ "${provider}" == "huggingface" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
            auth_token="${HUGGING_FACE_HUB_TOKEN}"
        fi

        if [[ "${engine}" == "aria2" ]] && command -v aria2c >/dev/null 2>&1; then
            aria_args=(-x16 -s16 -k8M --continue=true --file-allocation=none --auto-file-renaming=false --allow-overwrite=false --retry-wait=3 --console-log-level=warn --dir="${dest_dir}" --out="$(basename "${path}")")
            if [[ -n "${auth_token}" ]]; then aria_args+=(--header="Authorization: Bearer ${auth_token}"); fi
            aria2c "${aria_args[@]}" "${url}" || provisioning_download "${url}" "${dest_dir}"
        else
            provisioning_download "${url}" "${dest_dir}"
            if [[ ! -f "${dest_file}" ]]; then
                newest=$(ls -t "${dest_dir}" 2>/dev/null | head -1)
                if [[ -n "${newest}" && -f "${dest_dir}/${newest}" ]]; then
                    if [[ "${newest}" != "$(basename "${path}")" ]]; then
                        mv "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || cp "${dest_dir}/${newest}" "${dest_file}" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
            APT_INSTALL="${APT_INSTALL:-apt-get install -y}"
            sudo $APT_INSTALL "${APT_PACKAGES[@]}"
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

# Pull the MiniMax H3 weights using the standalone Xet downloader.
function provisioning_get_h3_weights() {
    # Lean t2v+i2v stack (~38GB) + turbo LoRAs.
    hf_xet_download "Comfy-Org/MiniMax-H3" "${COMFYUI_DIR}/models" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
        "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
        "vae/minimax_h3_video_vae_fp16.safetensors" \
        "vae/minimax_h3_audio_vae_fp32.safetensors" \
        "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" \
        "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
        "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"
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
    [[ -n "${HF_TOKEN:-}" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
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
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
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

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi