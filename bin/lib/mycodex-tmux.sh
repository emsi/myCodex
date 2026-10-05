#!/usr/bin/env bash
# Sent by the host launcher to bash inside the container. Keeping this script
# host-side lets existing workstation images display the same attach notice.
set -euo pipefail

session="$(tmux display-message -p -t "=$1:" '#{session_id}')"
mode="$2"
notice="$3"

case "${mode}" in
  x11) badge='GUI:X11' ;;
  wayland) badge='GUI:WL' ;;
  none) badge='GUI:off' ;;
  *) badge='GUI:?' ;;
esac

# Keep Byobu/user status formatting and update one session only. The option
# reference makes repeated attaches idempotent without saving config files.
tmux set-option -t "${session}" @mycodex-gui "${badge}"
left="$(tmux show-options -Av -t "${session}" status-left)"
if [[ "${left}" != *'#{@mycodex-gui}'* ]]; then
  tmux set-option -t "${session}" status-left '#{@mycodex-gui} '"${left}"
fi
length="$(tmux show-options -Av -t "${session}" status-left-length)"
if (( length < 8 )); then
  tmux set-option -t "${session}" status-left-length 8
fi

# Queue the message in the attaching client, after tmux owns the screen.
# A host echo or a shell command after a blocking attach would miss this point.
exec tmux attach-session -t "${session}" \; display-message -d 8000 -l "${notice}"
