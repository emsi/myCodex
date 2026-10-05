#!/usr/bin/env bash
# Runs inside the integration image, as the user selected by the entrypoint.
set -euo pipefail
[[ "$(id -u)" == "$MYCODEX_HOST_UID" && "$(id -g)" == "$MYCODEX_HOST_GID" ]]
[[ "$(stat -c '%u:%g:%a' /etc/mycodex/bashrc)" == 0:0:644 ]]
[[ "$(stat -c '%u:%g:%a' /etc/mycodex)" == 0:0:755 ]]
[[ "$(stat -c '%u:%g' "$HOME/.bashrc")" == "$MYCODEX_HOST_UID:$MYCODEX_HOST_GID" ]]
if grep -Fq /home/vscode /usr/local/bin/entrypoint.sh; then exit 1; fi

case "$MYCODEX_TEST_SCENARIO" in
  fresh|old-marker)
    grep -Fxq '. /etc/mycodex/bashrc' "$HOME/.bashrc"
    [[ -s "$HOME/.profile" ]]
    ;;
  empty) [[ ! -s "$HOME/.bashrc" ]] ;;
  custom|symlink|bash-profile|bash-login)
    cmp "$HOME/custom-rc" "$HOME/.bashrc"
    [[ "$MYCODEX_TEST_CUSTOM" == yes && "$MYCODEX_TEST_PROFILE_LOADS" == 1 ]]
    if [[ "$MYCODEX_TEST_SCENARIO" == symlink ]]; then [[ -L "$HOME/.bashrc" ]]; fi
    if [[ "$MYCODEX_TEST_SCENARIO" == bash-* ]]; then [[ ! -e "$HOME/.profile" ]]; fi
    ;;
esac

# Inspect real first/new/split shells. Send assertions only into test-owned
# panes, and wait for marker files so a dead shell cannot look like a success.
first="$(tmux display-message -p -t codex: '#{pane_id}')"
second="$(tmux new-window -P -F '#{pane_id}' -t codex -c /workspace)"
third="$(tmux split-window -P -F '#{pane_id}' -t "$second" -c /workspace)"
for pane in "$first" "$second" "$third"; do
  marker="/tmp/shell-probe-${pane#%}"
  # shellcheck disable=SC2016 # These assertions execute in the pane shell.
  check='[[ $- == *i* ]] && shopt -q login_shell && [[ "$(id -u)" == "$MYCODEX_HOST_UID" ]]'
  case "$MYCODEX_TEST_SCENARIO" in
    fresh|old-marker)
      check+=' && shopt -q histappend && complete -p codex >/dev/null'
      ;;
    custom|symlink|bash-profile|bash-login)
      # shellcheck disable=SC2016
      check+=' && [[ "$MYCODEX_TEST_CUSTOM" == yes && "$MYCODEX_TEST_PROFILE_LOADS" == 1 ]]'
      ;;
  esac
  tmux send-keys -t "$pane" -l "$check && touch $marker"
  tmux send-keys -t "$pane" Enter
  for _ in {1..100}; do
    [[ -f "$marker" ]] && break
    sleep 0.05
  done
  if [[ ! -f "$marker" ]]; then
    tmux capture-pane -p -t "$pane" >&2
    exit 1
  fi
  if tmux capture-pane -p -t "$pane" | grep -Fq 'Permission denied'; then exit 1; fi
done
printf 'PASS: %s:%s %s\n' "$MYCODEX_HOST_UID" "$MYCODEX_HOST_GID" "$MYCODEX_TEST_SCENARIO"
