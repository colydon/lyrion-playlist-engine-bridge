#!/bin/sh

TOKEN="3JHskCFi31nHRKuDg4ObeV4TqZpB07s7-Ni6PaXXOB8"
ENGINE_LOG="/home/tc/playlist_engine/playlist_engine.log"
WATCHDOG_LOG="/home/tc/playlist_engine/playlist_engine_watchdog.log"

pkill -f 'playlist_engine.py --config playlist_engine_config.json' >/dev/null 2>&1 || true

i=0
while [ "$i" -lt 45 ]; do
    if ps w | grep '[p]laylist_engine.py' >/dev/null 2>&1 && \
       curl -fsS --max-time 5 -H "X-API-Key: $TOKEN" http://127.0.0.1:8787/api/health >/dev/null 2>&1; then
        echo "AUTO_RECOVERED"
        echo "---"
        ps w | grep '[p]laylist_engine.py'
        echo "---"
        tail -n 20 "$WATCHDOG_LOG" 2>/dev/null || true
        echo "---"
        tail -n 20 "$ENGINE_LOG" 2>/dev/null || true
        exit 0
    fi

    sleep 1
    i=$((i + 1))
done

echo "RECOVERY_TIMEOUT"
echo "---"
ps w | grep '[p]laylist_engine.py' || true
echo "---"
tail -n 20 "$WATCHDOG_LOG" 2>/dev/null || true
echo "---"
tail -n 20 "$ENGINE_LOG" 2>/dev/null || true
exit 1