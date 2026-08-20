#!/bin/bash
set -euo pipefail

source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE:-/workspace}/ComfyUI"

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
    "https://github.com/StanLukuvka/ComfyUI-MiniMax-H3-SPEED@dev"
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
    provisioning_get_nodes
    provisioning_get_pip_packages
    printf "==> Downloading H3 weights\n"
    provisioning_get_h3_weights
    printf "==> H3 weights download finished (rc=%s)\n" "$?"
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
    # Lean t2v+i2v stack (~38GB); add ref2va + turbo loras for r2v if you want all three.
    hf_xet_download "Comfy-Org/MiniMax-H3" "${COMFYUI_DIR}/models" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
        "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
        "vae/minimax_h3_video_vae_fp16.safetensors" \
        "vae/minimax_h3_audio_vae_fp32.safetensors"

    # Turbo LoRAs from drbaph/MiniMax-H3-Turbo-Lora-ComfyUI (dynamic-rank BF16)
    # Files are at repo root but ComfyUI expects them under models/loras/.
    hf_xet_download "drbaph/MiniMax-H3-Turbo-Lora-ComfyUI" "${COMFYUI_DIR}/models/loras" \
        "minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_resized_avg_rank_21_bf16.safetensors" \
        "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_resized_avg_rank_21_bf16.safetensors"
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