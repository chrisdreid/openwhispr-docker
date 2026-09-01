#!/usr/bin/env bash
# Sanity-check the whole OpenWhispr stack: server, GUI, wrapper, hotkey, settings.
# Read-only — changes nothing. See SETUP.md for what each item means.
#
#   ./check-setup.sh            full checklist
#   ./check-setup.sh -q         only problems
#   ./check-setup.sh --no-color plain output
#
# Exit: 0 all good · 1 one or more FAIL · 2 only WARNs

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIET=0; COLOR=1
for a in "$@"; do
    case "$a" in
        -q|--quiet)    QUIET=1 ;;
        --no-color)    COLOR=0 ;;
        -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    esac
done
[[ -t 1 ]] || COLOR=0

if (( COLOR )); then
    G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
    G=""; Y=""; R=""; B=""; D=""; N=""
fi

PASS=0; WARN=0; FAIL=0
declare -a PROBLEMS

_row() { # icon label detail
    printf '  %s %-34s %s\n' "$1" "$2" "$3"
}
ok()   { ((PASS++)); (( QUIET )) || _row "${G}✔${N}" "$1" "${D}$2${N}"; }
warn() { ((WARN++)); _row "${Y}⚠${N}" "$1" "$2"; PROBLEMS+=("${Y}WARN${N}  $1 — $2"); }
bad()  { ((FAIL++)); _row "${R}✘${N}" "$1" "$2"; PROBLEMS+=("${R}FAIL${N}  $1 — $2"); }
head_() { (( QUIET )) || printf '\n%s── %s %s\n' "$B" "$1" "$(printf '─%.0s' $(seq 1 $((56-${#1}))))${N}"; }
have() { command -v "$1" >/dev/null 2>&1; }

(( QUIET )) || printf '\n%s OpenWhispr stack — sanity check%s\n %s%s%s\n' \
    "$B" "$N" "$D" "$(date '+%F %T')  ·  repo: $REPO_DIR" "$N"

# ─── 1. host prerequisites ───────────────────────────────────────────────────
head_ "Host prerequisites"

have docker && ok "docker installed" "$(docker --version 2>/dev/null | cut -d, -f1)" \
             || bad "docker installed" "not on PATH"

if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "user in 'docker' group" "wrapper runs compose without sudo"
else
    bad "user in 'docker' group" "run: sudo usermod -aG docker $USER, then log out and back in"
fi

if docker info 2>/dev/null | grep -qi 'runtimes.*nvidia'; then
    ok "nvidia container runtime" "registered with docker"
else
    bad "nvidia container runtime" "install nvidia-container-toolkit and restart docker"
fi

if have nvidia-smi; then
    GPU_INFO="$(nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader 2>/dev/null | head -1)"
    GPU_CC="$(printf '%s' "$GPU_INFO" | awk -F', ' '{print $3}')"
    [[ -n $GPU_INFO ]] && ok "GPU present" "$GPU_INFO" || warn "GPU present" "nvidia-smi returned nothing"
else
    warn "GPU present" "nvidia-smi missing (CPU-only setups can ignore this)"
fi

for t in curl notify-send; do
    have "$t" && ok "$t available" "" || warn "$t available" "wrapper uses it (toasts / health probe)"
done

SESSION_TYPE="${XDG_SESSION_TYPE:-$(loginctl show-session "$(loginctl list-sessions --no-legend 2>/dev/null | awk '$NF!="" {print $1; exit}')" -p Type --value 2>/dev/null)}"
: "${SESSION_TYPE:=unknown}"

# ─── 2. repo ─────────────────────────────────────────────────────────────────
head_ "Repo"

SUBMOD="$REPO_DIR/multi-model-audio-transcript-server"
if [[ -f "$SUBMOD/server.py" && -f "$SUBMOD/transcribe.py" && -f "$SUBMOD/requirements.txt" ]]; then
    ok "submodule populated" "server.py, transcribe.py present"
else
    bad "submodule populated" "empty — run: git submodule update --init"
fi

if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -f "$REPO_DIR/.gitmodules" ]]; then
        git -C "$REPO_DIR" ls-files --error-unmatch .gitmodules >/dev/null 2>&1 \
            && ok ".gitmodules tracked" "clone --recurse-submodules will work" \
            || warn ".gitmodules tracked" "exists but UNTRACKED — a fresh clone still breaks; git add .gitmodules"
    else
        bad ".gitmodules present" "missing — submodule has no URL; see SETUP.md §3"
    fi
fi

ENV_FILE="$REPO_DIR/.env"
if [[ -f $ENV_FILE ]]; then
    ok ".env present" ""
    get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"; }
    MODEL="$(get_env MODEL)";       DEVICE="$(get_env DEVICE)"
    COMPUTE="$(get_env COMPUTE_TYPE)"; PORT="$(get_env PORT)"
    BIND="$(get_env BIND_HOST)";    MODEL_DIR="$(get_env MODEL_DIR)"
    : "${PORT:=8080}"; : "${BIND:=127.0.0.1}"
    ok "  MODEL / DEVICE" "${MODEL:-?} / ${DEVICE:-?}"
    ok "  BIND_HOST : PORT" "${BIND}:${PORT}"

    # compute-type advice keyed to the actual card
    case "$GPU_CC" in
        6.*)        WANT=int8 ;;
        7.*)        WANT=float16 ;;
        8.*|9.*|1*) WANT=float16 ;;
        *)          WANT="" ;;
    esac
    if [[ "$DEVICE" == cpu ]]; then
        [[ "$COMPUTE" == int8 ]] && ok "  COMPUTE_TYPE" "int8 (correct for CPU)" \
                                 || warn "  COMPUTE_TYPE" "$COMPUTE — use int8 on CPU"
    elif [[ -n $WANT && -n $COMPUTE ]]; then
        [[ "$COMPUTE" == "$WANT" || ( "$WANT" == float16 && "$COMPUTE" == int8_float16 ) ]] \
            && ok "  COMPUTE_TYPE" "$COMPUTE (matches compute cap $GPU_CC)" \
            || warn "  COMPUTE_TYPE" "$COMPUTE — compute cap $GPU_CC suggests $WANT (SETUP.md §3)"
    else
        ok "  COMPUTE_TYPE" "${COMPUTE:-unset}"
    fi

    if [[ "$BIND" != "127.0.0.1" && "$BIND" != "localhost" ]]; then
        warn "  BIND_HOST exposure" "$BIND — unauthenticated transcription endpoint reachable off-host"
    fi

    MD="${MODEL_DIR:-./models}"; [[ $MD = ./* || $MD != /* ]] && MD="$REPO_DIR/${MD#./}"
    for sub in huggingface parakeet; do
        if [[ -e "$MD/$sub" ]]; then
            tgt=""; [[ -L "$MD/$sub" ]] && tgt="→ $(readlink -f "$MD/$sub")"
            ok "  models/$sub" "$tgt"
        else
            warn "  models/$sub" "missing — run ./setup.sh"
        fi
    done
else
    bad ".env present" "missing — run ./setup.sh"
    PORT=8080
fi

# ─── 3. server ───────────────────────────────────────────────────────────────
head_ "Transcription server"

CID="$(docker ps -q --filter name=openwhispr-server 2>/dev/null)"
if [[ -n $CID ]]; then
    STATE="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$CID" 2>/dev/null)"
    ok "container running" "$STATE"
    [[ "$STATE" == *unhealthy* ]] && warn "container health" "unhealthy — normal for ~2 min after start (start_period 120s)"
else
    bad "container running" "not up — docker compose up -d"
fi

HEALTH="$(curl -fsS -m 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null)"
if [[ -n $HEALTH ]]; then
    ok "GET /health" "$HEALTH"
    SRV_MODEL="$(printf '%s' "$HEALTH" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')"
    SRV_DEV="$(printf '%s' "$HEALTH" | sed -n 's/.*"device":"\([^"]*\)".*/\1/p')"
    [[ -n $MODEL && -n $SRV_MODEL && $MODEL != "$SRV_MODEL" ]] && \
        warn "  loaded vs .env model" "serving '$SRV_MODEL' but .env says '$MODEL' — docker compose up -d to apply"
    [[ -n $DEVICE && -n $SRV_DEV && $DEVICE != "$SRV_DEV" ]] && \
        warn "  loaded vs .env device" "serving on '$SRV_DEV' but .env says '$DEVICE'"
else
    bad "GET /health" "no response on 127.0.0.1:${PORT}"
fi

if curl -fsS -m 3 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
    ok "GET /v1/models" "$(curl -fsS -m 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null \
        | tr ',' '\n' | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | paste -sd' ' -)"
fi

# ─── 4. GUI ──────────────────────────────────────────────────────────────────
head_ "OpenWhispr GUI"

if [[ -e /opt/openwhispr/openwhispr ]]; then
    TARGET="$(readlink -f /opt/openwhispr/openwhispr 2>/dev/null)"
    APP_VER="$(basename "$TARGET" | sed -n 's/OpenWhispr-\([0-9.]*\)-.*/\1/p')"
    ok "/opt/openwhispr/openwhispr" "→ $(basename "$TARGET")"
    [[ -x $TARGET ]] || bad "  AppImage executable" "chmod +x $TARGET"
else
    bad "/opt/openwhispr/openwhispr" "missing — the GUI is a separate project; see SETUP.md §4a"
    APP_VER=""
fi

if pgrep -x open-whispr-app >/dev/null 2>&1; then
    ok "GUI running" "$(pgrep -cx open-whispr-app) processes"
else
    warn "GUI running" "not started — nothing will respond to the hotkey (there is no autostart)"
fi

# ─── 5. wrapper ──────────────────────────────────────────────────────────────
head_ "Wrapper"

W=/usr/local/bin/openwhispr
if [[ -x $W ]]; then
    ok "$W" "mode $(stat -c%a "$W")"
    if [[ -f "$REPO_DIR/openwhispr-wrapper.sh" ]]; then
        diff -q "$W" "$REPO_DIR/openwhispr-wrapper.sh" >/dev/null 2>&1 \
            && ok "  matches repo copy" "no drift" \
            || warn "  matches repo copy" "differs from openwhispr-wrapper.sh — diff them"
    fi
    # Resolve compose dir the same way the wrapper does. Never source it: that launches the GUI.
    if [[ -n "$WHISPR_COMPOSE_DIR" ]]; then
        RES="$WHISPR_COMPOSE_DIR"; VIA="\$WHISPR_COMPOSE_DIR"
    elif [[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/openwhispr-docker/compose-dir" ]]; then
        RES="$(<"${XDG_CONFIG_HOME:-$HOME/.config}/openwhispr-docker/compose-dir")"; VIA="config file"
    else
        RES="$(grep -oP 'WHISPR_COMPOSE_DIR="\K[^"]+' "$W" 2>/dev/null | tail -1)"
        RES="${RES/\$HOME/$HOME}"; RES="${RES/\~/$HOME}"; VIA="built-in default"
    fi
    if [[ -f "$RES/docker-compose.yml" ]]; then
        ok "  compose dir resolves" "$RES ($VIA)"
        [[ "$(readlink -f "$RES")" == "$(readlink -f "$REPO_DIR")" ]] || \
            warn "  resolves to THIS repo" "points at $RES, not $REPO_DIR"
    else
        bad "  compose dir resolves" "$RES ($VIA) has no docker-compose.yml — auto-start and --stop will silently no-op"
    fi
else
    bad "$W" "not installed — sudo install -m 755 ./openwhispr-wrapper.sh $W"
fi

# ─── 6. URL handler ──────────────────────────────────────────────────────────
head_ "URL handler (required for account sign-in)"

DESK="$HOME/.local/share/applications/openwhispr.desktop"
[[ -f $DESK ]] && ok "openwhispr.desktop" "" || bad "openwhispr.desktop" "missing — SSO callback cannot return; SETUP.md §4c"
H="$(xdg-mime query default x-scheme-handler/openwhispr 2>/dev/null)"
[[ "$H" == openwhispr.desktop ]] && ok "x-scheme-handler/openwhispr" "$H" \
    || bad "x-scheme-handler/openwhispr" "${H:-unregistered} — run update-desktop-database"

# ─── 7. hotkey ───────────────────────────────────────────────────────────────
head_ "Hotkey"

KP=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/openwhispr/
KS="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KP"
LIST="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null)"

if [[ "$LIST" == *"custom-keybindings/openwhispr"* ]]; then
    BIND="$(gsettings get "$KS" binding 2>/dev/null | tr -d "'")"
    CMD="$(gsettings get "$KS" command 2>/dev/null | tr -d "'")"
    ok "mechanism" "GNOME keybinding → D-Bus (v1.9.x; works on X11 and Wayland)"
    if [[ -n $BIND ]]; then
        ok "binding" "$BIND"
        [[ "$BIND" == *"<Shift>z"* ]] && warn "  binding collision" "Ctrl+Shift+Z is 'redo' in most apps; a global grab shadows it everywhere"
    else
        bad "binding" "keybinding exists but has no shortcut set"
    fi
    [[ "$CMD" == *dbus-send*openwhispr* ]] && ok "  command" "dbus-send → com.openwhispr.App.Toggle" \
        || warn "  command" "${CMD:-unset} — not the expected dbus-send toggle"
    [[ "$LIST" == *"custom-keybindings/openwhispr"* ]] && \
        { gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null | grep -q "$KP" \
          && ok "  registered in list" "" || bad "  registered in list" "binding exists but is not in custom-keybindings"; }
else
    if [[ -n "$APP_VER" && "$APP_VER" == 1.6.* ]]; then
        ok "mechanism" "Electron globalShortcut (v$APP_VER) — no GNOME binding expected"
    else
        warn "mechanism" "no GNOME keybinding found — Electron globalShortcut, or the hotkey was never set"
    fi
    if [[ "$SESSION_TYPE" == wayland ]]; then
        bad "session type" "wayland — Electron globalShortcut cannot grab keys here; log into Xorg (SETUP.md §5)"
    else
        ok "session type" "$SESSION_TYPE"
    fi
fi
[[ "$SESSION_TYPE" == unknown ]] && warn "session type" "could not determine"

# conflicts against the configured combo
if [[ -n ${BIND:-} ]]; then
    CONFLICT="$( { gsettings list-recursively org.gnome.desktop.wm.keybindings
                   gsettings list-recursively org.gnome.shell.keybindings
                   gsettings list-recursively org.gnome.mutter.keybindings
                   gsettings list-recursively org.gnome.settings-daemon.plugins.media-keys
                 } 2>/dev/null | grep -iF "'$BIND'" | grep -v custom-keybinding | head -3 )"
    [[ -n $CONFLICT ]] && warn "  conflict" "$BIND also bound: $(printf '%s' "$CONFLICT" | awk '{print $2}' | paste -sd' ' -)" \
                       || ok "  no GNOME conflict" "$BIND is unclaimed elsewhere"
fi

# ─── 8. app settings ─────────────────────────────────────────────────────────
head_ "App settings"

PROF="$HOME/.config/open-whispr"
if [[ -d $PROF ]]; then
    ok "profile" "$PROF"
    if [[ -f "$PROF/.env" ]]; then
        AM="$(grep -E '^ACTIVATION_MODE=' "$PROF/.env" 2>/dev/null | cut -d= -f2-)"
        DK="$(grep -E '^DICTATION_KEY=' "$PROF/.env" 2>/dev/null | cut -d= -f2-)"
        [[ -n $AM ]] && ok "  ACTIVATION_MODE" "$AM" || warn "  ACTIVATION_MODE" "unset (laptop uses 'tap')"
        [[ -n $DK ]] && ok "  DICTATION_KEY" "$DK  ${D}(a shortcut, not a secret)${N}"
    fi
    # localStorage is a leveldb blob; grep it rather than parsing.
    LS="$PROF/Local Storage/leveldb"
    if [[ -d $LS ]]; then
        BURL="$(grep -aho 'http://[a-zA-Z0-9.:_-]*' "$LS"/*.log "$LS"/*.ldb 2>/dev/null \
                 | grep -E ':(8080|[0-9]+)' | sort -u | head -3 | paste -sd' ' -)"
        [[ -n $BURL ]] && ok "  base URL seen in profile" "$BURL" \
                       || warn "  base URL" "not found in profile — set it in the GUI (SETUP.md §6)"
        if grep -aq '"useLocalWhisper".*true\|useLocalWhisper\x00\{0,4\}true' "$LS"/*.log "$LS"/*.ldb 2>/dev/null; then
            warn "  useLocalWhisper" "appears enabled — transcription would bypass this server"
        fi
    fi
    LOCALBIN="$PROF/bin"
    [[ -d $LOCALBIN ]] && warn "  local whisper binary" "$(du -sh "$LOCALBIN" 2>/dev/null | cut -f1) in $LOCALBIN — only used when local Whisper is on"
else
    warn "profile" "$PROF missing — the GUI has not completed first run"
fi

# ─── 9. round trip ───────────────────────────────────────────────────────────
head_ "End-to-end evidence"

if have docker && [[ -n $CID ]]; then
    NPOST="$(docker logs "$CID" 2>&1 | grep -c 'POST /.*transcriptions.* 200' )"
    NUNM="$(docker logs "$CID" 2>&1 | grep -c 'UNMATCHED POST')"
    (( NPOST > 0 )) && ok "successful POSTs to server" "$NPOST since container start" \
                    || warn "successful POSTs to server" "none yet — press the hotkey and speak"
    (( NUNM  > 0 )) && warn "UNMATCHED POSTs" "$NUNM — the GUI called a path the server lacks; check the base URL"
fi

DB="$PROF/transcriptions.db"
if [[ -f $DB ]] && have sqlite3; then
    ROW="$(sqlite3 "file:$DB?mode=ro" \
        "select status||'  '||coalesce(provider,'?')||'/'||coalesce(model,'?')||'  '||timestamp
         from transcriptions order by id desc limit 1;" 2>/dev/null)"
    NOK="$(sqlite3 "file:$DB?mode=ro" "select count(*) from transcriptions where status='completed';" 2>/dev/null)"
    NBAD="$(sqlite3 "file:$DB?mode=ro" "select count(*) from transcriptions where status!='completed';" 2>/dev/null)"
    [[ -n $ROW ]] && ok "last transcription" "$ROW" || warn "last transcription" "table empty"
    [[ -n $NOK ]] && ok "  completed / failed" "${NOK} / ${NBAD:-0}"
elif [[ -f $DB ]]; then
    warn "transcriptions.db" "present but sqlite3 not installed — sudo apt install sqlite3"
else
    warn "transcriptions.db" "no dictation has completed yet"
fi

# ─── summary ─────────────────────────────────────────────────────────────────
printf '\n%s── Summary %s\n' "$B" "$(printf '─%.0s' $(seq 1 46))${N}"
printf '  %s%d passed%s   %s%d warnings%s   %s%d failures%s\n' \
    "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"

if (( ${#PROBLEMS[@]} )); then
    printf '\n%sNeeds attention:%s\n' "$B" "$N"
    for p in "${PROBLEMS[@]}"; do printf '  %s\n' "$p"; done
    printf '\n  %sReference: SETUP.md%s\n' "$D" "$N"
fi
printf '\n'

(( FAIL )) && exit 1
(( WARN )) && exit 2
exit 0
