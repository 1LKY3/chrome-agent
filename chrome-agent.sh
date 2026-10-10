#!/usr/bin/env bash
# Chrome Agent: consent-gated remote debugging for a dedicated Chrome profile.
# The enable flag is the safety boundary; the MCP server refuses when it is absent.
set -euo pipefail

BASE="${CHROME_AGENT_BASE:-$HOME/.config/chrome-agent}"
PROFILE="$BASE/profile"
FLAG="$BASE/enabled"
PIDFILE="$BASE/chrome.pid"
LAYOUT="$BASE/layout.tsv"
CHROME="${CHROME_BIN:-/opt/google/chrome/chrome}"
PORT="${CHROME_AGENT_PORT:-9223}"
PROFILE_MATCH="--user-data-dir=$PROFILE"
SOURCE_PROFILE="${CHROME_AGENT_SOURCE:-$HOME/.config/google-chrome}"
OZONE_FLAG="--ozone-platform=x11"

# Callers started outside the desktop session (a systemd user unit, a terminal
# without X) may lack the display variables; Chrome on X11 then exits at once.
# Borrow them from the session's systemd environment, then fall back to :0.
if [ -z "${DISPLAY:-}" ] || [ -z "${XAUTHORITY:-}" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            DISPLAY|XAUTHORITY|WAYLAND_DISPLAY)
                [ -n "${!key:-}" ] || export "$key=$value" ;;
        esac
    done < <(systemctl --user show-environment 2>/dev/null || true)
    export DISPLAY="${DISPLAY:-:0}"
    if [ -z "${XAUTHORITY:-}" ]; then
        for auth in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/.mutter-Xwaylandauth.*; do
            [ -f "$auth" ] && export XAUTHORITY="$auth" && break
        done
    fi
fi

chrome_pid() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
           grep -qs -- "$PROFILE_MATCH" "/proc/$pid/cmdline"; then
            echo "$pid"
            return 0
        fi
    fi
    pgrep -f -- "$PROFILE_MATCH" | head -n 1 || true
}

port_up() {
    curl -sf --max-time 2 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1
}

# Browser processes of the personal (default-profile) Chrome, excluding
# renderers/helpers and the debug agent itself.
normal_chrome_pids() {
    local pid cmd
    for pid in $(pgrep -f '/opt/google/chrome/chrome' 2>/dev/null); do
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *--type=*|*--user-data-dir=*) continue ;;
        esac
        echo "$pid"
    done
}

sync_profile() {
    # Mirror the personal profile into the non-standard debug directory that
    # Chrome 136+ requires. Caches and history stay out; logins come along.
    if [ ! -d "$SOURCE_PROFILE" ]; then
        echo "No profile at $SOURCE_PROFILE; starting an empty agent profile" >&2
        return 0
    fi
    if ! command -v rsync >/dev/null 2>&1; then
        echo "rsync is unavailable; cannot mirror the personal profile" >&2
        return 1
    fi
    mkdir -p "$PROFILE"
    rsync -a --delete \
        --exclude 'Singleton*' \
        --exclude 'Default/Cache/' \
        --exclude 'Default/Code Cache/' \
        --exclude 'Default/GPUCache/' \
        --exclude 'Default/DawnGraphiteCache/' \
        --exclude 'Default/DawnWebGPUCache/' \
        --exclude 'Default/Service Worker/CacheStorage/' \
        --exclude 'Default/Service Worker/ScriptCache/' \
        --exclude 'Default/History' \
        --exclude 'Default/History-journal' \
        --exclude 'Default/Visited Links' \
        --exclude 'Default/Top Sites' \
        --exclude 'Default/Media History*' \
        --exclude 'ShaderCache/' \
        --exclude 'GrShaderCache/' \
        --exclude 'component_crx_cache/' \
        --exclude 'extensions_crx_cache/' \
        --exclude 'Crashpad/' \
        --exclude 'BrowserMetrics/' \
        "$SOURCE_PROFILE/" "$PROFILE/" || {
        echo "Profile mirror hit errors; continuing with what copied" >&2
    }
}

mark_clean_exit() {
    local target="${1:-$PROFILE}"
    local prefs="$target/Default/Preferences"
    [ -f "$prefs" ] || return 0
    /usr/bin/python3 - "$prefs" <<'PY' || true
import json
import sys

path = sys.argv[1]
try:
    with open(path) as handle:
        data = json.load(handle)
except Exception:
    raise SystemExit(0)
profile = data.setdefault('profile', {})
profile['exit_type'] = 'Normal'
profile['exited_cleanly'] = True
try:
    with open(path, 'w') as handle:
        json.dump(data, handle)
except Exception:
    pass
PY
}

# Remember each visible Chrome window's anchored geometry keyed by its title.
# Screen readers and the layout memory let this work even when a monitor is
# arranged as halves (Super+Left / Super+Right); exact bounds restore the anchor.
capture_layout() {
    command -v xdotool >/dev/null 2>&1 || return 0
    local id name
    : > "$LAYOUT"
    for id in $(xdotool search --onlyvisible --class 'google-chrome' 2>/dev/null || true); do
        name=$(xdotool getwindowname "$id" 2>/dev/null || true)
        [ -n "$name" ] || continue
        eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null || true)"
        [ -n "${X:-}" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$X" "$Y" "$WIDTH" "$HEIGHT" >> "$LAYOUT"
        unset X Y WIDTH HEIGHT
    done
}

apply_layout() {
    [ -s "$LAYOUT" ] || return 0
    command -v xdotool >/dev/null 2>&1 || return 0
    local tries=0 id wname name x y w h applied
    while [ "$tries" -lt 20 ]; do
        local all_matched=1
        for id in $(xdotool search --onlyvisible --class 'google-chrome' 2>/dev/null || true); do
            wname=$(xdotool getwindowname "$id" 2>/dev/null || true)
            [ -n "$wname" ] || continue
            applied=0
            while IFS=$'\t' read -r name x y w h; do
                [ -n "$name" ] || continue
                case "$wname" in
                    "$name"*)
                        xdotool windowmove "$id" "$x" "$y" 2>/dev/null || true
                        xdotool windowsize "$id" "$w" "$h" 2>/dev/null || true
                        applied=1
                        break
                        ;;
                esac
            done < "$LAYOUT"
            [ "$applied" -eq 1 ] || all_matched=0
        done
        [ "$all_matched" -eq 1 ] && break
        tries=$((tries + 1))
        sleep 1
    done
}

stop_debug_chrome() {
    if [ -n "$(chrome_pid)" ]; then
        pkill -TERM -f -- "$PROFILE_MATCH" 2>/dev/null || true
        for _ in $(seq 1 20); do
            pgrep -f -- "$PROFILE_MATCH" >/dev/null 2>&1 || break
            sleep 0.5
        done
        pkill -KILL -f -- "$PROFILE_MATCH" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

launch_agent() {
    setsid "$CHROME" \
        --user-data-dir="$PROFILE" \
        --remote-debugging-port="$PORT" \
        --remote-debugging-address=127.0.0.1 \
        --no-first-run --no-default-browser-check "$OZONE_FLAG" \
        --hide-crash-restore-bubble "$@" >/dev/null 2>&1 < /dev/null &
    local _
    for _ in $(seq 1 40); do
        sleep 0.5
        port_up && break
    done
    local pid
    pid=$(pgrep -f -- "$PROFILE_MATCH" | head -n 1 || true)
    [ -n "$pid" ] && echo "$pid" > "$PIDFILE" || true
    port_up
}

quit_normal_chrome() {
    local pids pid
    pids=$(normal_chrome_pids)
    if [ -n "$pids" ]; then
        # Graceful quit so the personal profile flushes its session state.
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        for _ in $(seq 1 30); do
            [ -z "$(normal_chrome_pids)" ] && break
            sleep 0.5
        done
        for pid in $(normal_chrome_pids); do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
}

cmd_status() {
    local enabled=no running=no port=down
    [ -f "$FLAG" ] && enabled=yes
    [ -n "$(chrome_pid)" ] && running=yes
    port_up && port=up
    printf 'enabled=%s running=%s port=%s port_number=%s profile=%s\n' \
        "$enabled" "$running" "$port" "$PORT" "$PROFILE"
}

cmd_enable() {
    mkdir -p "$BASE" "$PROFILE"
    chmod 700 "$BASE" "$PROFILE"
    : > "$FLAG"
    chmod 600 "$FLAG"
    if [ -n "$(chrome_pid)" ]; then
        echo "Chrome agent already running (pid $(chrome_pid))"
        return 0
    fi
    sync_profile
    if launch_agent about:blank; then
        apply_layout &
        echo "Chrome agent enabled on 127.0.0.1:$PORT"
    else
        echo "Chrome agent started but the debug port is not responding" >&2
        return 1
    fi
}

cmd_refresh() {
    [ -f "$FLAG" ] || { echo "Enable Agent Chrome Access first" >&2; exit 1; }
    capture_layout
    quit_normal_chrome
    stop_debug_chrome
    sync_profile
    mark_clean_exit
    if launch_agent --restore-last-session; then
        apply_layout &
        echo "Chrome refreshed into the debug browser; tabs and anchored windows restoring"
    else
        echo "Chrome launched but the debug port is not responding" >&2
        return 1
    fi
}

cmd_disable() {
    local urls=""
    capture_layout
    if [ -n "$(chrome_pid)" ]; then
        urls=$(curl -sf --max-time 3 "http://127.0.0.1:$PORT/json" 2>/dev/null | \
            /usr/bin/python3 -c "import json,sys; print(' '.join(t.get('url','') for t in json.load(sys.stdin) if t.get('type')=='page' and t.get('url','').startswith('http')))" 2>/dev/null || true)
    fi
    rm -f "$FLAG"
    stop_debug_chrome
    # The mirror holds copies of the personal profile's cookies; wipe it so
    # disabling leaves no credential copy on disk. Enabling re-syncs.
    case "$PROFILE" in
        "$BASE"/*) rm -rf "$PROFILE" ;;
    esac
    # Hand the sites back to the personal browser when it is not already open.
    if [ -n "$urls" ] && [ -z "$(normal_chrome_pids)" ]; then
        mark_clean_exit "$SOURCE_PROFILE"
        # shellcheck disable=SC2086
        setsid "$CHROME" "$OZONE_FLAG" --hide-crash-restore-bubble $urls >/dev/null 2>&1 < /dev/null &
        apply_layout &
    fi
    echo "Chrome agent disabled; debug port closed and profile mirror wiped"
}

case "${1:-status}" in
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    refresh) cmd_refresh ;;
    status) cmd_status ;;
    restart)
        cmd_disable >/dev/null
        cmd_enable
        ;;
    *)
        echo "usage: $0 {enable|disable|refresh|status|restart}" >&2
        exit 2
        ;;
esac
