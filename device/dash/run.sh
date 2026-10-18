#!/bin/sh
# Always-on dashboard: pull the server-rendered PNG and draw it.
# Tap anywhere to refresh. To exit back to the normal Kindle screen, tap the clock (top-left), then the EXIT
# button that appears mid-screen: carrying the Kindle touches its corners, rarely its centre.
# Restart over SSH: kill the run.sh PID (find it via /proc/*/cmdline; `pkill -f` kills your own ssh session).
. /mnt/us/dash/config # sets URL=http://<server>:8090/dash.png; copy config.example
FULL_EVERY=10   # flashing full refresh every N draws to clear e-ink ghosting
SETTLE=2        # fetch this many seconds after each minute, in case the Kindle clock runs ahead of the server
CLOCK_X=400     # clock zone: taps left of this x...
CLOCK_Y=200     # ...and above this y. Taps are logged to /tmp/dash.log if this needs tuning.
BTN="100 660 420 670" # EXIT button tap area: x from, x to, y from, y to (drawn at x 123-634, y 448-640, plus a margin)
CONFIRM_SECS=5  # how long the EXIT button waits for its tap
FBINK=/mnt/us/libkh/bin/fbink

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

# Wait up to $1 seconds for a tap. Prints "x y" for a tap, nothing on timeout.
# Each read() on the touchscreen returns whole frames of 16-byte events: time (2 x int32), type+code
# (int32 = type + code*65536), value. EV_ABS=3 with ABS_MT_POSITION_X=0x35 -> 3473411, ABS_MT_POSITION_Y=0x36
# -> 3538947, ABS_MT_TRACKING_ID=0x39 -> 3735555 (-1 when a finger lifts). Lift-only frames are skipped.
wait_tap() {
  end=$(($(date +%s) + $1))
  while [ $((left = end - $(date +%s))) -gt 0 ]; do
    t=$(timeout -t $left dd if=/dev/input/event1 bs=4096 count=1 2>/dev/null | od -An -v -t d4 -w16 |
      awk '$3 == 3473411 { x = $4 } $3 == 3538947 { y = $4 } $3 == 3735555 { id = 1; if ($4 >= 0) down = 1 }
           END { if (x != "" && y != "" && (down || !id)) print x, y }')
    [ -n "$t" ] && { echo "$t"; return; }
  done
}

n=0
while true; do
  if wget -q -O /tmp/dash.png "$URL"; then
    if [ $((n % FULL_EVERY)) -eq 0 ]; then eips -f -g /tmp/dash.png; else eips -g /tmp/dash.png; fi
    n=$((n + 1))
  else
    echo "$(date) fetch failed"
    eips 2 41 "No connection, retrying..." >/dev/null
  fi
  tap=$(wait_tap $((60 - $(date +%s) % 60 + SETTLE)))
  [ -n "$tap" ] || continue
  echo "$(date) tap $tap"
  set -- $tap
  if [ "$1" -ge $CLOCK_X ] || [ "$2" -ge $CLOCK_Y ]; then
    eips 2 41 "Refreshing..." >/dev/null
    n=0 # next draw is a flashing full one, clearing the text and any ghosting
    continue
  fi
  # Clock tapped: show the EXIT button. Draw off-screen, then one fast
  # black-and-white refresh (DU), so it appears at once instead of piece by piece.
  $FBINK -q -c -b ""
  $FBINK -q -b -M -m -S 8 -y -1 -h "        " "  EXIT  " "        "
  $FBINK -q -b -M -m -S 3 -y 7 "Tap EXIT to leave"
  $FBINK -q -s -W DU
  confirm=$(wait_tap $CONFIRM_SECS)
  echo "$(date) confirm ${confirm:-timeout}"
  set -- $confirm $BTN
  if [ -n "$confirm" ] && [ "$1" -gt "$3" ] && [ "$1" -lt "$4" ] && [ "$2" -gt "$5" ] && [ "$2" -lt "$6" ]; then
    eips 2 41 "Exiting..." >/dev/null
    lipc-set-prop com.lab126.powerd preventScreenSaver 0
    start lab126_gui
    exit 0
  fi
  eips -f -g /tmp/dash.png >/dev/null # straight back to the last picture; the loop then fetches a fresh one
done
