#!/bin/sh

ENGINE_DIR="/home/tc/playlist_engine"
ENGINE_SCRIPT="$ENGINE_DIR/playlist_engine.py"
ENGINE_CONFIG="$ENGINE_DIR/playlist_engine_config.json"
ENGINE_LOG="$ENGINE_DIR/playlist_engine.log"
WATCHDOG_LOG="$ENGINE_DIR/playlist_engine_watchdog.log"
WATCHDOG_LOCKDIR="$ENGINE_DIR/.playlist_engine_watchdog.lock"
WATCHDOG_PIDFILE="$WATCHDOG_LOCKDIR/pid"
RATING_SYNC_SCRIPT="$ENGINE_DIR/sync_ratings.py"
RATING_SYNC_LOG="$ENGINE_DIR/rating_sync.log"
# Een keer per dag als vangnet; normaal draait de sync meteen na een bibliotheekscan.
RATING_SYNC_INTERVAL=86400
RATING_SYNC_SETTLE=120
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
# Let op: een handler op TERM/INT moet ook echt stoppen, anders negeert de
# watchdog een kill en blijven er meerdere instanties naast elkaar leven.
trap 'rm -rf "$WATCHDOG_LOCKDIR"' EXIT
trap 'exit 0' INT TERM

API_TOKEN="$(read_config_value token 2>/dev/null)"
API_PORT="$(read_config_value port 2>/dev/null)"
[ -n "$API_PORT" ] || API_PORT=8787
HEALTH_URL="http://127.0.0.1:${API_PORT}/api/health"

FAILED_CHECKS=0
LAST_RATING_SYNC=0
SCAN_SEEN=0
SCAN_DONE_AT=0
RATING_SYNC_DUE=0
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

    # Vul ontbrekende/gewijzigde ratings en verouderde genres aan vanuit de tags.
    # Dat gebeurt automatisch zodra een bibliotheekscan klaar is (met een korte
    # wachttijd zodat LMS zijn nasleep afmaakt), met een dagelijkse fallback.
    NOW=$(date +%s)
    if ps w | grep -q '[s]canner\.pl'; then
        SCAN_SEEN=1
    elif [ "$SCAN_SEEN" = "1" ]; then
        SCAN_SEEN=0
        SCAN_DONE_AT=$NOW
        RATING_SYNC_DUE=1
        log_line "Library scan finished; rating/genre sync scheduled."
    fi
    if [ $((NOW - LAST_RATING_SYNC)) -ge "$RATING_SYNC_INTERVAL" ]; then
        RATING_SYNC_DUE=1
        [ "$SCAN_DONE_AT" -gt "$NOW" ] && SCAN_DONE_AT=$NOW
    fi
    if [ "$RATING_SYNC_DUE" = "1" ] && [ -f "$RATING_SYNC_SCRIPT" ] \
        && [ $((NOW - SCAN_DONE_AT)) -ge "$RATING_SYNC_SETTLE" ] \
        && ! ps w | grep -q '[s]canner\.pl' \
        && ! ps w | grep -q '[s]ync_ratings\.py'; then
        LAST_RATING_SYNC=$NOW
        RATING_SYNC_DUE=0
        nohup "$PYTHON_BIN" -u "$RATING_SYNC_SCRIPT" >> "$RATING_SYNC_LOG" 2>&1 < /dev/null &
        log_line "Started rating/genre sync (pid $!)."
    fi

    sleep "$CHECK_INTERVAL"
done