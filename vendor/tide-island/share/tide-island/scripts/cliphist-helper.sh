#!/usr/bin/env bash
set -e

# Clipboard history is private: nothing this helper writes may be readable by
# group or others, whatever umask the calling shell happened to inherit
# (022 and 002 are common desktop defaults).
umask 077

# XDG_CACHE_HOME counts only when it is an absolute path; an empty or
# relative value falls back to $HOME/.cache (XDG Base Directory spec).
if [[ -n ${XDG_CACHE_HOME:-} && $XDG_CACHE_HOME == /* ]]; then
    CACHE_BASE="$XDG_CACHE_HOME"
else
    CACHE_BASE="${HOME:?HOME is not set, so no cache location can be resolved}/.cache"
fi
CACHE_DIR="$CACHE_BASE/tide-island/cliphist-imgs"

# umask 077 lands a freshly created directory at 0700, and chmod repairs one
# an older install left at the permissive umask default. Both run before any
# clipboard image is decoded, and a failure aborts the action so images are
# never written into a directory other users can enter.
mkdir -p "$CACHE_DIR"
chmod 0700 "$CACHE_DIR"
# PNGs decoded before this fix may still carry the old mode; the private
# directory already keeps others out, so tighten those files as well.
find "$CACHE_DIR" -maxdepth 1 -type f -name '*.png' -exec chmod 0600 {} + || true

ACTION="${1:-list}"

case "$ACTION" in
    watch)
        command -v cliphist >/dev/null 2>&1 || exit 127
        command -v wl-paste >/dev/null 2>&1 || exit 127
        # A user service may already be recording history for an older install.
        # Share one watcher when the updated shell starts later.
        exec 9>"${XDG_RUNTIME_DIR:-$CACHE_DIR}/tide-island-clipboard.lock"
        flock -n 9 || exit 0
        exec wl-paste --watch cliphist store
        ;;
    list)
        if ! command -v cliphist >/dev/null 2>&1 || ! command -v wl-paste >/dev/null 2>&1 || ! command -v wl-copy >/dev/null 2>&1; then
            exit 127
        fi

        LIMIT="${2:-200}"

        cliphist list 2>/dev/null | head -n "$LIMIT" | while IFS=$'\t' read -r id rest; do
            if [[ "$rest" == *"[[ binary data"* ]]; then
                img_path="$CACHE_DIR/$id.png"
                if [[ ! -f "$img_path" ]]; then
                    cliphist decode "$id" > "$img_path" 2>/dev/null || true
                fi
                if [[ -s "$img_path" ]]; then
                    printf "%s\t%s\000icon\x1f%s\n" "$id" "$rest" "$img_path"
                else
                    printf "%s\t%s\n" "$id" "$rest"
                fi
            else
                printf "%s\t%s\n" "$id" "$rest"
            fi
        done
        ;;
    copy)
        id="$2"
        if [[ -n "$id" ]]; then
            cliphist decode "$id" 2>/dev/null | wl-copy
        fi
        ;;
    delete)
        id="$2"
        delete_cache="${3:-true}"
        cache_img="$CACHE_DIR/$id.png"

        if [[ -n "$id" ]]; then
            cliphist list 2>/dev/null | grep -a "^${id}"$'\t' | cliphist delete 2>/dev/null || true
            if [[ "$delete_cache" == "true" && -f "$cache_img" ]]; then
                rm -f "$cache_img"
            fi
        fi
        ;;
    wipe|clear)
        cliphist wipe 2>/dev/null || true
        rm -rf "${CACHE_DIR:?}"/* 2>/dev/null || true
        ;;
    count)
        cliphist list 2>/dev/null | wc -l
        ;;
    *)
        if [[ -n "$1" ]]; then
            cliphist decode "$1" 2>/dev/null | wl-copy
        fi
        ;;
esac
