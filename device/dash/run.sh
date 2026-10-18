#!/bin/sh
# Always-on dashboard: pull the server-rendered PNG and draw it.
# Tap anywhere to refresh; tap the clock (top-left) to exit back to the normal Kindle screen.
# Restart over SSH: kill the run.sh PID (find it via /proc/*/cmdline; `pkill -f` kills your own ssh session).
. /mnt/us/dash/config # sets URL=http://<server>:8090/dash.png; copy config.example
FULL_EVERY=10   # flashing full refresh every N draws to clear e-ink ghosting
SETTLE=2        # fetch this many seconds after each minute, in case the Kindle clock runs ahead of the server
EXIT_X=400      # exit zone: taps left of this x...
EXIT_Y=200      # ...and above this y (the clock). Taps are logged to /tmp/dash.log if this needs tuning.

# KOReader normally runs the SSH server; keep it up while KOReader is closed.
# Firewall holes are checked separately: KOReader can remove them while dropbear lives on.
iptables -C INPUT -p tcp --dport 2222 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null ||
  iptables -A INPUT -p tcp --dport 2222 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
iptables -C OUTPUT -p tcp --sport 2222 -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null ||
  iptables -A OUTPUT -p tcp --sport 2222 -m conntrack --ctstate ESTABLISHED -j ACCEPT
# Check the PID is non-empty first: busybox `kill -0 ""` returns success, which hid a dead server after boot.
pid=$(cat /tmp/dropbear_koreader.pid 2>/dev/null)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null ||
  (cd /mnt/us/koreader && ./dropbear -E -R -s -p 2222 -P /tmp/dropbear_koreader.pid)

stop lab126_gui # hide the Kindle UI so it doesn't draw over us or react to taps
lipc-set-prop com.lab126.powerd preventScreenSaver 1

# Wait for a tap or the next full minute, so the clock and "in X min" are on time. Prints "x y" for a tap, nothing on timeout.
# One read() on the touchscreen returns the whole touch-down frame, so X and Y arrive together.
# Each event is 16 bytes: time (2 x int32), type+code (int32 = type + code*65536), value.
# EV_ABS=3 with ABS_MT_POSITION_X=0x35 -> 3473411, ABS_MT_POSITION_Y=0x36 -> 3538947.
wait_tap() {
  timeout -t $((60 - $(date +%s) % 60 + SETTLE)) dd if=/dev/input/event1 bs=4096 count=1 2>/dev/null |
    od -An -v -t d4 -w16 | awk '$3 == 3473411 { x = $4 } $3 == 3538947 { y = $4 } END { if (x != "" && y != "") print x, y }'
}

n=0
tap=""
while true; do
  [ -n "$tap" ] && eips 2 41 "Refreshing..." >/dev/null
  if wget -q -O /tmp/dash.png "$URL"; then
    # a tap also gets a full refresh, so the "Refreshing..." text and any ghosting are cleared
    if [ -n "$tap" ] || [ $((n % FULL_EVERY)) -eq 0 ]; then eips -f -g /tmp/dash.png; else eips -g /tmp/dash.png; fi
    n=$((n + 1))
  else
    echo "$(date) fetch failed"
    eips 2 41 "No connection, retrying..." >/dev/null
  fi
  tap=$(wait_tap)
  [ -n "$tap" ] || continue
  echo "$(date) tap $tap"
  set -- $tap
  if [ "$1" -lt $EXIT_X ] && [ "$2" -lt $EXIT_Y ]; then
    eips 2 41 "Exiting..." >/dev/null
    lipc-set-prop com.lab126.powerd preventScreenSaver 0
    start lab126_gui
    exit 0
  fi
done
