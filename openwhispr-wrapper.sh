#!/bin/bash
EXEC_PATH="/opt/openwhispr/openwhispr"

# ── ensure the dockerized transcription server is up ────────────────────────
# Override either with an env var if you move the compose project.
WHISPR_COMPOSE_DIR="${WHISPR_COMPOSE_DIR:-/home/chris/dev/venv/v-openwhispr-docker}"
WHISPR_PORT="$(grep -E '^PORT=' "${WHISPR_COMPOSE_DIR}/.env" 2>/dev/null | cut -d= -f2-)"
WHISPR_PORT="${WHISPR_PORT:-8080}"

notify() {
    command -v notify-send >/dev/null 2>&1 \
        && notify-send -i audio-input-microphone "openwhispr" "$1" 2>/dev/null
}

ensure_whispr_server() {
    # Already responding → nothing to do.
    if curl -fsS -m 1 "http://127.0.0.1:${WHISPR_PORT}/health" >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        notify "docker not installed — server will not auto-start"
        echo "openwhispr-wrapper: docker not installed" >&2
        return 1
    fi

    if [[ ! -f "${WHISPR_COMPOSE_DIR}/docker-compose.yml" ]]; then
        notify "compose file missing at ${WHISPR_COMPOSE_DIR}"
        echo "openwhispr-wrapper: ${WHISPR_COMPOSE_DIR}/docker-compose.yml not found" >&2
        return 1
    fi

    notify "Starting transcription server..."
    if ! docker compose -f "${WHISPR_COMPOSE_DIR}/docker-compose.yml" up -d >/dev/null 2>&1; then
        notify "Failed to start transcription server (see: docker compose logs whispr)"
        echo "openwhispr-wrapper: docker compose up -d failed" >&2
        return 1
    fi
}

# ── stop: kill the GUI and take the container down ──────────────────────────
if [[ "$1" == "--stop" || "$1" == "stop" ]]; then
    notify "Stopping openwhispr and transcription server..."
    # OpenWhispr ships as an AppImage that self-mounts at a random
    # /tmp/.mount_*/open-whispr path, so $EXEC_PATH does not appear in the
    # children's command lines. All processes share comm=open-whispr-app.
    pkill -TERM -x open-whispr-app 2>/dev/null
    sleep 1
    pkill -KILL -x open-whispr-app 2>/dev/null
    if [[ -f "${WHISPR_COMPOSE_DIR}/docker-compose.yml" ]]; then
        docker compose -f "${WHISPR_COMPOSE_DIR}/docker-compose.yml" down
    fi
    exit 0
fi

ensure_whispr_server

# ── original launch logic ───────────────────────────────────────────────────
if [[ "$1" == openwhispr://* ]]; then
    exec "$EXEC_PATH" --no-sandbox "$@"
else
    nohup "$EXEC_PATH" --no-sandbox "$@" > /dev/null 2>&1 &
    disown
fi
