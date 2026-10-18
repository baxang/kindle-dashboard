#!/bin/sh
# Name: Dashboard
# DontUseFBInk

# setsid: run.sh stops the Kindle UI, which launched us, so detach first
setsid /mnt/us/dash/run.sh >/tmp/dash.log 2>&1 &
