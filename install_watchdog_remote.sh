#!/bin/sh
set -e

ENGINE_DIR="/home/tc/playlist_engine"
WATCHDOG_SCRIPT="$ENGINE_DIR/playlist_engine_watchdog.sh"
BOOTLOCAL="/opt/bootlocal.sh"

/bin/cp -f /tmp/cti_deploy/playlist_engine_watchdog.sh "$WATCHDOG_SCRIPT"
chmod +x "$WATCHDOG_SCRIPT"

if [ -f "$BOOTLOCAL" ]; then
    cp "$BOOTLOCAL" "$BOOTLOCAL.bak"
fi

cat > "$BOOTLOCAL" <<'EOF'
#!/bin/sh
# put other system startup commands here

GREEN="\033[1;32m"

echo
echo "${GREEN}Running bootlocal.sh..."

if [ -d /home/tc/lms_plugin/PlaylistEngineBridge ]; then
    mkdir -p /usr/local/slimserver/Plugins/PlaylistEngineBridge
    cp -R /home/tc/lms_plugin/PlaylistEngineBridge/. /usr/local/slimserver/Plugins/PlaylistEngineBridge/
fi

# Playlist engine watchdog.
#
# This block MUST come before the pcp_startup line below. That line is
# "pcp_startup.sh | tee -a /var/log/pcp_boot.log" and it never finishes,
# because LMS and the bridges inherit the pipe and keep it open. Everything
# placed after it is therefore never executed.
WATCHDOG=/home/tc/playlist_engine/playlist_engine_watchdog.sh
ENGINE_DIR=/home/tc/playlist_engine

if [ -x "$WATCHDOG" ]; then
    if ps w | grep '[p]laylist_engine_watchdog.sh' >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') bootlocal: watchdog already running" >> "$ENGINE_DIR/boot.log"
    else
        # The lock directory is part of the backup, so it can be left over from
        # a previous boot. Clear it before starting.
        rm -rf "$ENGINE_DIR/.playlist_engine_watchdog.lock"
        nohup "$WATCHDOG" >/dev/null 2>&1 &
        echo "$(date '+%Y-%m-%d %H:%M:%S') bootlocal: started watchdog (pid $!)" >> "$ENGINE_DIR/boot.log"
    fi
fi

#pCPstart------
/usr/local/etc/init.d/pcp_startup.sh 2>&1 | tee -a /var/log/pcp_boot.log
#pCPstop------
EOF

if ! ps w | grep '[p]laylist_engine_watchdog.sh' >/dev/null 2>&1; then
    nohup "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
fi

filetool.sh -b >/tmp/filetool-playlist-engine.log 2>&1 || true

echo "WATCHDOG_INSTALLED"
echo "---"
ps w | grep '[p]laylist_engine_watchdog' || true
echo "---"
tail -n 20 "$ENGINE_DIR/playlist_engine_watchdog.log" 2>/dev/null || true
echo "---"
sed -n '1,220p' "$BOOTLOCAL"