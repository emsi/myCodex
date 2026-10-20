#!/usr/bin/env bash
# Sent by the host launcher to bash inside the container. Keeping this script
# host-side lets existing workstation images display the same attach notice.
set -euo pipefail

session="$(tmux display-message -p -t "=$1:" '#{session_id}')"
mode="$2"
notice="$3"
details="${4:-}"
reopen="${5:-0}"
# Optional for compatibility with callers of the original GUI-only helper.
gpu_badge="${6:-}"
if [[ -n "${gpu_badge}" && ! "${gpu_badge}" =~ ^GPU:(off|\?|[A-Z]+(,[A-Z]+)*)$ ]]; then
  gpu_badge='GPU:?'
fi

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
  left='#{@mycodex-gui} '"${left}"
fi
badge_length=$((${#badge} + 1))
if [[ -n "${gpu_badge}" ]]; then
  tmux set-option -t "${session}" @mycodex-gpu "${gpu_badge}"
  if [[ "${left}" != *'#{@mycodex-gpu}'* ]]; then
    left="${left/'#{@mycodex-gui}'/'#{@mycodex-gui} #{@mycodex-gpu}'}"
  fi
  badge_length=$((badge_length + ${#gpu_badge} + 1))
fi
tmux set-option -t "${session}" status-left "${left}"
length="$(tmux show-options -Av -t "${session}" status-left-length)"
if (( length < badge_length )); then
  tmux set-option -t "${session}" status-left-length "${badge_length}"
fi

# Retain the full text in the session, independent of pane scrollback and any
# alternate-screen application. Keep the last report when a later check is quiet.
if [[ -n "${details}" ]]; then
  tmux set-option -t "${session}" @mycodex-notices \
    "${notice}"$'\n\n'"${details}"$'\n\nPress q to close. Reopen with: myCodex notices'
elif [[ -z "$(tmux show-options -qv -t "${session}" @mycodex-notices)" ]]; then
  tmux set-option -t "${session}" @mycodex-notices "${notice}"
fi

# Queue UI in the attaching client, after tmux owns the screen. The popup reads
# a session option rather than interpolating notice text into a shell command.
# A pager keeps long reports scrollable and waits for explicit dismissal.
if [[ -n "${details}" || "${reopen}" == 1 ]]; then
  # Let attach finish and send terminal queries before waiting for dismissal.
  # A popup in the initial command sequence delays those queries past tmux's
  # startup timeout, leaking device-attribute replies into the shell.
  exec tmux attach-session -t "${session}" \; \
    run-shell -b -C \
      "display-popup -E -w 90% -h 80% -T 'myCodex notices (q to close)' \
        \"tmux show-options -qv -t '${session}' @mycodex-notices | LESS= less -+F -+X\""
fi
exec tmux attach-session -t "${session}" \; display-message -d 8000 -l "${notice}"
