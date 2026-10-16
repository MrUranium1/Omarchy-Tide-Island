#!/usr/bin/env bash
#
# harden-tide-config.sh — tighten permissions on Tide Island's own config.
#
# The bundled Tide Island settings app can store an optional TLP sudo password
# in ~/.config/tide-island/userconfig.json. Earlier builds seeded that file 0644
# and the app's QSaveFile save set no permissions, so an existing installation
# may still hold a group/world-readable secret. This repairs the directory and
# the file in place: only mode bits change, and the contents are never
# rewritten, copied, or read, so the secret is never exposed while it is fixed.
# Idempotent; safe to run repeatedly.
#
# It deliberately refuses to act through a symlink, so a link planted at the
# config path can never make it chmod an unrelated target, and it only ever
# touches the config directory and userconfig.json inside it.
#
# Usage: harden-tide-config.sh [config-dir]
#   config-dir  overrides the default ${XDG_CONFIG_HOME:-$HOME/.config}/tide-island
#
# Exit 0 when the directory is already tight or was repaired or absent, 1 when an
# existing file or directory could not be tightened (or the path is a symlink).

set -Eeuo pipefail

log() { printf 'harden-tide-config: %s\n' "$*" >&2; }

if [[ -n ${1:-} ]]; then
    config_dir="$1"
elif [[ -n ${XDG_CONFIG_HOME:-} ]]; then
    config_dir="$XDG_CONFIG_HOME/tide-island"
elif [[ -n ${HOME:-} ]]; then
    config_dir="$HOME/.config/tide-island"
else
    log "neither XDG_CONFIG_HOME nor HOME is set; nothing to repair."
    exit 0
fi

if [[ -L $config_dir ]]; then
    log "refusing to touch $config_dir: it is a symlink." >&2
    exit 1
fi

if [[ ! -d $config_dir ]]; then
    log "no Tide config directory at $config_dir; nothing to repair."
    exit 0
fi

rc=0

if [[ $(stat -c '%a' "$config_dir" 2>/dev/null) != 700 ]]; then
    if chmod 0700 -- "$config_dir"; then
        log "set $config_dir to 0700."
    else
        log "could not tighten $config_dir." >&2
        rc=1
    fi
fi

userconfig="$config_dir/userconfig.json"
if [[ -L $userconfig ]]; then
    log "refusing to touch $userconfig: it is a symlink." >&2
    rc=1
elif [[ -f $userconfig ]] && [[ $(stat -c '%a' "$userconfig" 2>/dev/null) != 600 ]]; then
    if chmod 0600 -- "$userconfig"; then
        log "set $userconfig to 0600."
    else
        log "could not tighten $userconfig." >&2
        rc=1
    fi
fi

exit "$rc"
