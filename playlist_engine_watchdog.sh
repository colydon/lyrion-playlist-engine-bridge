#!/bin/sh

ENGINE_DIR="/home/tc/playlist_engine"
ENGINE_SCRIPT="$ENGINE_DIR/playlist_engine.py"
ENGINE_CONFIG="$ENGINE_DIR/playlist_engine_config.json"
ENGINE_LOG="$ENGINE_DIR/playlist_engine.log"
WATCHDOG_LOG="$ENGINE_DIR/playlist_engine_watchdog.log"
WATCHDOG_LOCKDIR="$ENGINE_DIR/.playlist_engine_watchdog.lock"
WATCHDOG_PIDFILE="$WATCHDOG_LOCKDIR/pid"
PYTHON_BIN="/usr/local/bin/python3.11"
CHECK_INTERVAL=30
HEALTH_TIMEOUT=10
MAX_FAILED_CHECKS=2

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
    echo "$(timestamp) $*" >> "$WATCHDOG_LOG"
}

read_config_value() {
    key="$1"
    "$PYTHON_BIN" - "$ENGINE_CONFIG" "$key" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text())
key = sys.argv[2]

if key == 'token':
    print(config.get('api', {}).get('token', ''))
elif key == 'port':
    print(config.get('api', {}).get('port', 8787))
PY
}

engine_running() {
    ps w | grep '[p]laylist_engine.py --config playlist_engine_config.json' >/dev/null 2>&1
}

engine_healthcheck() {
    if [ -n "$API_TOKEN" ]; then
        curl -fsS --max-time "$HEALTH_TIMEOUT" -H "X-API-Key: $API_TOKEN" "$HEALTH_URL" >/dev/null 2>&1
    else
        curl -fsS --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" >/dev/null 2>&1
    fi
}

stop_engine() {
    pkill -f 'playlist_engine.py --config playlist_engine_config.json' >/dev/null 2>&1 || true
}

start_engine() {
    if [ ! -x "$PYTHON_BIN" ] || [ ! -f "$ENGINE_SCRIPT" ] || [ ! -f "$ENGINE_CONFIG" ]; then
        log_line "Cannot start engine because python, script or config is missing."
        return 1
    fi

    cd "$ENGINE_DIR" || return 1
    nohup "$PYTHON_BIN" playlist_engine.py --config playlist_engine_config.json --log-level INFO >> "$ENGINE_LOG" 2>&1 < /dev/null &
    log_line "Started playlist engine with pid $!"
    return 0
}

if ! mkdir "$WATCHDOG_LOCKDIR" 2>/dev/null; then
    OLD_PID="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi

    rm -rf "$WATCHDOG_LOCKDIR"
    mkdir "$WATCHDOG_LOCKDIR"
fi

echo $$ > "$WATCHDOG_PIDFILE"
trap 'rm -rf "$WATCHDOG_LOCKDIR"' EXIT INT TERM

API_TOKEN="$(read_config_value token 2>/dev/null)"
API_PORT="$(read_config_value port 2>/dev/null)"
[ -n "$API_PORT" ] || API_PORT=8787
HEALTH_URL="http://127.0.0.1:${API_PORT}/api/health"

FAILED_CHECKS=0
log_line "Watchdog started for $HEALTH_URL"

while :; do
    if ! engine_running; then
        log_line "Engine process missing; starting engine."
        start_engine
        FAILED_CHECKS=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if engine_healthcheck; then
        FAILED_CHECKS=0
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        log_line "Health check failed ($FAILED_CHECKS/$MAX_FAILED_CHECKS)."
        if [ "$FAILED_CHECKS" -ge "$MAX_FAILED_CHECKS" ]; then
            log_line "Restarting engine after repeated health check failures."
            stop_engine
            sleep 2
            start_engine
            FAILED_CHECKS=0
        fi
    fi

    sleep "$CHECK_INTERVAL"
done