#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — prepare model directory for the dockerized transcription server.
#
# What it does:
#   1. Loads .env (creating it from .env.example if missing)
#   2. Creates ${MODEL_DIR}/huggingface and ${MODEL_DIR}/parakeet
#   3. If they don't already exist as real dirs, symlinks them to your host
#      caches so the container reuses anything you've already downloaded:
#         ~/.cache/huggingface              → ${MODEL_DIR}/huggingface
#         ~/.cache/local-transcribe/parakeet → ${MODEL_DIR}/parakeet
#   4. Lists what models are visible to the container
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# ── colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'
else
    C_BOLD=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_RST=''
fi
say()  { printf '%s\n' "$*"; }
log()  { printf '  %s%s%s\n'   "$C_CYN"  "$*" "$C_RST"; }
ok()   { printf '  %s✓ %s%s\n' "$C_GRN"  "$*" "$C_RST"; }
warn() { printf '  %s⚠ %s%s\n' "$C_YEL"  "$*" "$C_RST"; }
err()  { printf '  %s✗ %s%s\n' "$C_RED"  "$*" "$C_RST"; }

say ""
say "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RST}"
say "${C_BOLD}  openwhispr-docker — model directory setup${C_RST}"
say "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RST}"
say ""

# ── .env ──────────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env
    ok "Created .env from .env.example"
else
    log "Using existing .env"
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

MODEL_DIR="${MODEL_DIR:-./models}"
HF_HOST_CACHE="${HF_HOST_CACHE:-$HOME/.cache/huggingface}"
PARAKEET_HOST_CACHE="${PARAKEET_HOST_CACHE:-$HOME/.cache/local-transcribe/parakeet}"

log "MODEL_DIR             = ${MODEL_DIR}"
log "Host HF cache         = ${HF_HOST_CACHE}"
log "Host Parakeet cache   = ${PARAKEET_HOST_CACHE}"
say ""

# ── Helper: link or create a model subdir ─────────────────────────────────────
# If the target path doesn't exist, symlink it to the host cache when present.
# If the host cache is missing, create an empty directory.
# If the target already exists (file/dir/symlink), leave it alone.
link_or_mkdir() {
    local target="$1"
    local host_cache="$2"
    local label="$3"

    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -L "$target" ]]; then
            ok "${label}: already linked → $(readlink -f "$target")"
        else
            ok "${label}: already exists at ${target} (left as-is)"
        fi
        return
    fi

    mkdir -p "$(dirname "$target")"

    if [[ -d "$host_cache" ]]; then
        ln -s "$host_cache" "$target"
        ok "${label}: symlinked ${target} → ${host_cache}"
    else
        mkdir -p "$target"
        warn "${label}: host cache not found at ${host_cache}"
        warn "${label}: created empty ${target} — models will be downloaded on first use"
    fi
}

mkdir -p "$MODEL_DIR"
link_or_mkdir "${MODEL_DIR}/huggingface" "$HF_HOST_CACHE"        "HuggingFace"
link_or_mkdir "${MODEL_DIR}/parakeet"    "$PARAKEET_HOST_CACHE"  "Parakeet"

say ""
say "${C_BOLD}─── Whisper models present (in HuggingFace cache) ──────────────${C_RST}"
HF_HUB="${MODEL_DIR}/huggingface/hub"
if [[ -d "$HF_HUB" ]]; then
    found=0
    while IFS= read -r d; do
        name="$(basename "$d")"
        # Only show whisper-related entries
        case "$name" in
            models--*whisper*|models--*Whisper*|models--*WHISPER*)
                ok "$name"; found=1 ;;
        esac
    done < <(find "$HF_HUB" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    [[ $found -eq 0 ]] && warn "no whisper models cached yet (will download on first server start)"
else
    warn "HuggingFace hub directory not found — first model load will download"
fi

say ""
say "${C_BOLD}─── Parakeet models present ────────────────────────────────────${C_RST}"
PK_DIR="${MODEL_DIR}/parakeet"
if [[ -d "$PK_DIR" ]]; then
    found=0
    for d in "$PK_DIR"/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 \
             "$PK_DIR"/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8; do
        if [[ -d "$d" ]]; then
            ok "$(basename "$d")"; found=1
        fi
    done
    [[ $found -eq 0 ]] && warn "no parakeet models cached yet (will download on first use)"
else
    warn "parakeet directory not found"
fi

say ""
say "${C_BOLD}─── Next steps ─────────────────────────────────────────────────${C_RST}"
say "  Edit .env to pick a different MODEL or DEVICE, then:"
say ""
say "    ${C_CYN}docker compose up -d${C_RST}            # build (first time) and start"
say "    ${C_CYN}docker compose logs -f${C_RST}          # watch model loading"
say "    ${C_CYN}curl http://127.0.0.1:${PORT:-8080}/health${C_RST}"
say ""
say "  Switch model: edit MODEL in .env, then ${C_CYN}docker compose up -d${C_RST} again."
say ""
say "  Point OpenWhispr at: ${C_CYN}http://127.0.0.1:${PORT:-8080}${C_RST}"
say ""
