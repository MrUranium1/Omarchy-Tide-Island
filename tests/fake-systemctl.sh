#!/usr/bin/env bash
#
# fake-systemctl — a controllable systemctl stand-in for unit-testing
# tide-sync.sh. Records every invocation and answers `is-active` from a file
# whose contents the test controls, so tests can assert not just *that* a
# start/stop happened but that no redundant call happened.

set -Eeuo pipefail

STATE_FILE="${FAKE_SYSTEMCTL_STATE_FILE:?set the fake is-active state file}"
LOG_FILE="${FAKE_SYSTEMCTL_LOG_FILE:?set the fake invocation log}"

case "$1 $2" in
  "--user is-active")
    if [[ -f $STATE_FILE ]]; then cat "$STATE_FILE"; else echo "inactive"; fi
    exit 0
    ;;
  "--user start")
    printf 'start %s\n' "$3" >>"$LOG_FILE"
    echo "active" >"$STATE_FILE"
    exit 0
    ;;
  "--user stop")
    printf 'stop %s\n' "$3" >>"$LOG_FILE"
    echo "inactive" >"$STATE_FILE"
    exit 0
    ;;
  *)
    echo "fake-systemctl: unhandled: $*" >&2
    exit 1
    ;;
esac