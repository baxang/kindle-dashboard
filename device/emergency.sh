#!/bin/sh
# Dashboard auto-start. The jailbreak's boot job (/etc/upstart/kmc.conf) runs /mnt/us/emergency.sh
# every time the Kindle UI becomes ready. Delete this file to turn auto-start off.

# Once per boot only: exiting the dashboard restarts the Kindle UI, which runs this hook again.
# /tmp is in RAM, so the marker is gone after a reboot.
[ -e /tmp/dash.autostarted ] && exit 0
touch /tmp/dash.autostarted

# Detach so the boot job isn't held up; the delay lets the Kindle finish booting before run.sh stops the UI.
setsid sh -c 'sleep 30; exec /mnt/us/dash/run.sh' >/tmp/dash.log 2>&1 &
