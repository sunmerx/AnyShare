#!/bin/bash
# Ubuntu side: play the VDD extended-display stream.
# Usage: bash play.sh [udp-port]
# Requires: ffplay (static build in ~/ffmpeg-play/bin), Xwayland access, ufw allows the UDP port.

PORT="${1:-53319}"
XWAY=$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1)

export DISPLAY="${DISPLAY:-:0}"
if [ -n "$XWAY" ]; then
    export XAUTHORITY="$XWAY"
fi

exec ~/ffmpeg-play/bin/ffplay \
    -fflags nobuffer -flags low_delay -framedrop \
    -window_title "AnyShare VDD Demo" \
    "udp://0.0.0.0:${PORT}?overrun_nonfatal=1&fifo_size=10000000"
