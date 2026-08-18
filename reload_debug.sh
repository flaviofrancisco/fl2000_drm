#!/bin/bash
# Reload the fl2000/it66121 modules with debug instrumentation and capture the trace.
set -e

cd "$(dirname "$0")"

if lsmod | grep -q '^it66121'; then
	if ! sudo rmmod it66121; then
		echo "WARNING: it66121 is in use and won't unload. Force-rebooting to get a clean state..." >&2
		sudo reboot -f
		exit 1
	fi
fi

if lsmod | grep -q '^fl2000'; then
	if ! sudo rmmod fl2000; then
		echo "WARNING: fl2000 is in use and won't unload. Force-rebooting to get a clean state..." >&2
		sudo reboot -f
		exit 1
	fi
fi

sudo modprobe drm_dma_helper
sudo insmod ./fl2000.ko
sudo insmod ./it66121.ko

sleep 2

echo "=== dmesg tail ==="
sudo dmesg -T | tail -80

echo "=== connector status ==="
for f in /sys/class/drm/card*-HDMI*; do
	echo "== $f =="
	cat "$f/status"
done
