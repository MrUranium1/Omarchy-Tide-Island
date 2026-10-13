#!/usr/bin/env bash
set -e

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tide-island/cliphist-imgs"
mkdir -p "$CACHE_DIR"

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
