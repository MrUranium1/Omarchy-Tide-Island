#!/usr/bin/env bash
#
# teardown.sh — reverse everything install.sh set up.
#
# Unlike uninstall.sh this is deliberately self-contained: it depends on NO file
# inside the plugin directory, so it still works after `omarchy plugin remove`
# has deleted mehir.tide-island. install.sh copies this script to
# ~/.local/lib/omarchy-tide-island/teardown.sh, and Service.qml runs that copy
# from Component.onDestruction when it notices its own plugin directory
# vanished, so removing the plugin undoes the OSD/notification stand-down (and
# the rest) even when it was removed with `omarchy plugin remove` rather than
# our uninstall.sh.
#
# Flags:
#   --remove-clones    Remove only OSD/notification clones whose complete tree
#                      still matches the creation snapshot.
#   --remove-runtime   Remove the bundled Tide Island from ~/.local.
#   --purge-config     Prompt for PURGE before deleting plugin config.
#   --if-plugin-gone   No-op unless the plugin directory is already missing
#                      (used by the Component.onDestruction guard).
#   --final            Remove state/helper only if no recovery backup or
#                      suppression marker remains.
#
# State lives in ~/.local/state/omarchy/tide-island/installed.json (written by
# install.sh); backups of every file we touched are kept in .../backups/.

set -Eeuo pipefail

PLUGIN_ID="mehir.tide-island"
HOME_DIR="$HOME"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"
BIN_TARGET="$HOME/.local/bin"
CONFIG_TARGET="$HOME/.config/omarchy/tide-island.json"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
BACKUPS="$STATE_DIR/backups"
STATE_MARKERS="$STATE_DIR/patch-state"
CLONE_BASELINES="$STATE_DIR/clone-baselines"
INSTALLED_FILE="$STATE_DIR/installed.json"
SEED_FILE="$STATE_DIR/seeded-userconfig.json"
LIB_DIR="$HOME/.local/lib/omarchy-tide-island"
DESKTOP_STATE="$STATE_DIR/desktop-entries.json"
PATH_STATE="$STATE_DIR/path-links.json"
APPS_DIR="$HOME/.local/share/applications"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PATCHES_DIR="$SCRIPT_DIR/patches"
[[ -d "$SCRIPT_DIR/../patches" ]] && PATCHES_DIR="$SCRIPT_DIR/../patches"
[[ -d $PATCHES_DIR ]] || PATCHES_DIR="$LIB_DIR/patches"
HYPR="$HOME/.config/hypr"
UPSTREAM="/usr/share/omarchy/shell/plugins"
TIDE_USERCONFIG="$HOME/.config/tide-island/userconfig.json"
SYSTEMCTL="${TIDE_SYNC_SYSTEMCTL:-systemctl}"
TSTAMP="$(date +%Y%m%d-%H%M%S.%N)"

opt_remove_clones=0
opt_remove_runtime=0
opt_purge_config=0
opt_if_gone=0
opt_final=0

usage() {
  cat <<USAGE
Usage: teardown.sh [--remove-clones] [--remove-runtime] [--purge-config]
                   [--if-plugin-gone] [--final] [--help]

  --remove-clones    Remove only unchanged clones with a verified fingerprint.
  --remove-runtime   Remove the bundled Tide Island from ~/.local.
  --purge-config     Prompt before deleting ~/.config/omarchy/tide-island.json.
  --if-plugin-gone   Only act when the plugin directory is missing.
  --final            Remove the state directory + this helper when done.
  --help             Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --remove-clones) opt_remove_clones=1 ;;
    --remove-runtime) opt_remove_runtime=1 ;;
    --purge-config) opt_purge_config=1 ;;
    --if-plugin-gone) opt_if_gone=1 ;;
    --final) opt_final=1 ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'teardown: %s\n' "$*"; }

if (( opt_purge_config )); then
  printf 'This permanently deletes %s (a recovery copy will be kept). Type PURGE to continue: ' "$CONFIG_TARGET" >&2
  purge_answer=""
  if ! IFS= read -r purge_answer || [[ $purge_answer != PURGE ]]; then
    log "configuration purge cancelled; no teardown actions were performed." >&2
    exit 1
  fi
fi

# The automatic path calls us while the shell is being torn down; bail unless the
# plugin really is gone, so a hot-reload or disable is never mistaken for a
# removal.
if (( opt_if_gone )) && [[ -e $PLUGIN_DIR ]]; then
  log "plugin still present at $PLUGIN_DIR; nothing to do."
  exit 0
fi

state="{}"
[[ -f $INSTALLED_FILE ]] && state="$(cat "$INSTALLED_FILE" 2>/dev/null || echo '{}')"

resync_shell() {
  command -v omarchy-shell >/dev/null 2>&1 || return 0
  omarchy-shell -q shell rescanPlugins 2>/dev/null || true
  omarchy-shell -q osd syncSuppression 2>/dev/null || true
  omarchy-shell -q notifications syncSuppression 2>/dev/null || true
}

clone_fingerprint() {
  local dir="$1"
  [[ -d $dir ]] || return 1
  (
    cd "$dir"
    find . -mindepth 1 -printf '%y %m %P %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | cut -d' ' -f1
}

remove_clone() {
  local id="$1" expected="${2:-}" actual
  if [[ -z $expected ]]; then
    log "preserving clone '$id': no creation fingerprint is available; review it manually."
    return 1
  fi
  actual="$(clone_fingerprint "$PLUGINS_DIR/$id" 2>/dev/null || true)"
  if [[ $actual != "$expected" ]]; then
    log "preserving modified clone '$id'; current files differ from the installation snapshot."
    log "Its suppression will be reverted only if the patch can be removed without overwriting edits."
    log "Review $PLUGINS_DIR/$id and backups in $BACKUPS before removing it."
    return 1
  fi
  if command -v omarchy >/dev/null 2>&1 && omarchy plugin remove "$id" --yes >/dev/null 2>&1; then
    log "removed clone '$id'."
  fi
  if [[ -e "$PLUGINS_DIR/$id" && ! -L "$PLUGINS_DIR/$id" ]]; then
    rm -rf "${PLUGINS_DIR:?}/$id"
    log "removed directory $PLUGINS_DIR/$id"
  fi
  rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
  rm -f "$CLONE_BASELINES/$id" "$STATE_DIR/created-clones/$id" 2>/dev/null || true
  return 0
}

restore_managed_patch() {
  local file="$1" backup="$2" patch="$3" restore_dir restore_entry merge_status
  if [[ -z $backup || ! -f $backup || ! -f $patch ]] || ! command -v diff3 >/dev/null 2>&1; then
    return 1
  fi
  restore_dir="$(mktemp -d "${TMPDIR:-/tmp}/tide-island-restore.XXXXXX")"
  restore_entry="$restore_dir/patched/$(basename "$file")"
  mkdir -p "$(dirname "$restore_entry")"
  cp -p "$backup" "$restore_entry"
  if patch -p1 --batch --no-backup -d "$(dirname "$restore_entry")" <"$patch" >/dev/null 2>&1; then
    merge_status=0
    diff3 -m "$file" "$restore_entry" "$backup" >"$restore_dir/merged" || merge_status=$?
    if (( merge_status == 0 )); then
      chmod --reference="$file" "$restore_dir/merged"
      mv -f "$restore_dir/merged" "$file"
      rm -rf -- "$restore_dir"
      return 0
    fi
  fi
  rm -rf -- "$restore_dir"
  return 1
}

# ------------------------------------------------------------- suppression

# State-less fallback: sweep every clone of this role for our own marker. Used
# when installed.json is gone (a previous --final, a manual clear, or a reap
# that ran after the state was already removed) yet our suppression patch is
# still live in the clones. Only clones whose entry point actually carries our
# marker are touched, so an unrelated custom clone is never harmed.
scan_and_clean() {
  local role="$1" skip="$2" m id entry file base backup upstream marker patch
  for m in "$PLUGINS_DIR"/*/manifest.json; do
    [[ -f $m ]] || continue
    id="$(basename "$(dirname "$m")")"
    [[ $id == "$skip" || $id == "$PLUGIN_ID" ]] && continue
    [[ "$(jq -r '.omarchy.clonedFrom // .clonedFrom // empty' "$m" 2>/dev/null || true)" == "omarchy.$role" ]] || continue
    entry="$(jq -r '.entryPoints.panel // .entryPoints.service // .entryPoints.barWidget // empty' "$m" 2>/dev/null || true)"
    [[ -z $entry ]] && continue
    file="${m%/manifest.json}/$entry"
    [[ -f $file ]] || continue
    marker="The bar-off marker"
    [[ $role == notifications ]] && marker="popupsSuppressed"
    grep -q "$marker" "$file" || continue

    base="$(basename "$file")"
    backup="$(ls -1t "$BACKUPS"/*."$id".$base 2>/dev/null | head -1 || true)"
    upstream="$UPSTREAM/$role/$base"
    patch="$PATCHES_DIR/omarchy-$role-suppression.patch"
    if restore_managed_patch "$file" "$backup" "$patch"; then
      rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
      log "de-suppressed '$id' by reversing only the managed patch; other files were preserved."
    elif [[ -f $upstream && -f $file ]] && cmp -s "$file" "$upstream"; then
      rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
      log "'$id' is already pristine."
    else
      log "conflict restoring '$id': preserved $file and its backup ${backup:-<none>}." >&2
      log "Review and merge manually; no clone files were overwritten." >&2
    fi
  done
}

undo_suppression() {
  mkdir -p "$BACKUPS"
  local role id created marker entry file base backup upstream dir handled baseline patch restored
  for role in osd notifications; do
    handled=""
    id="$(jq -r --arg r "$role" '.suppression[$r].after // empty' <<<"$state" 2>/dev/null || true)"
    created="$(jq -r --arg r "$role" '.suppression[$r].createdByUs // false' <<<"$state" 2>/dev/null || true)"
    if [[ -n $id ]]; then
      handled="$id"
      dir="$PLUGINS_DIR/$id"
      if [[ ! -d $dir ]]; then
        rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
      else
        baseline="$(jq -r --arg r "$role" '.suppression[$r].baselineFingerprint // empty' <<<"$state" 2>/dev/null || true)"
        if [[ -z $baseline ]]; then
          baseline="$(cat "$CLONE_BASELINES/$id" 2>/dev/null || true)"
        fi
        marker="$(cat "$STATE_MARKERS/$id" 2>/dev/null || true)"
        if [[ $marker == preexisting ]]; then
          log "clone '$id' was already suppressed before the plugin; leaving it untouched."
        elif [[ $marker == applied ]]; then
          entry="$(jq -r '.entryPoints.panel // .entryPoints.service // .entryPoints.barWidget // empty' \
            "$dir/manifest.json" 2>/dev/null || true)"
          if [[ -z $entry ]]; then
            log "cannot determine the entry point of '$id'; preserving clone and backups."
          else
            file="$dir/$entry"
            base="$(basename "$file")"
            backup="$(ls -1t "$BACKUPS"/*."$id".$base 2>/dev/null | head -1 || true)"
            upstream="$UPSTREAM/$role/$base"
            patch="$PATCHES_DIR/omarchy-$role-suppression.patch"
            restored=0
            if [[ -n $backup && -f $file ]] && cmp -s "$backup" "$file"; then
              restored=1
              log "'$id' is already pristine; kept its recovery backup."
            elif [[ -f $file ]] && restore_managed_patch "$file" "$backup" "$patch"; then
              restored=1
              log "de-suppressed '$id' by reversing only the managed patch; other edits were preserved."
            elif [[ -f $upstream && -f $file ]] && cmp -s "$file" "$upstream"; then
              restored=1
              log "'$id' is already pristine."
            else
              log "conflict restoring '$id': preserved $file and its backup ${backup:-<none>}." >&2
              log "Review and merge manually; no clone files were overwritten." >&2
            fi
            if (( restored )); then
              rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
              if [[ $created == "true" && $opt_remove_clones == 1 ]]; then
                remove_clone "$id" "$baseline" || true
              fi
            fi
          fi
        else
          log "no record of this plugin applying suppression to '$id'; preserving it and its backups."
        fi
      fi
    fi
    scan_and_clean "$role" "$handled"
  done
}

undo_suppression

# ---------------------------------------------------------- desktop entries

restore_desktop_entries() {
  [[ -f $DESKTOP_STATE ]] || return 0
  local entries name expected target current tmp
  entries="$(cat "$DESKTOP_STATE")"
  for name in tide-island.desktop tide-island-config.desktop; do
    expected="$(jq -r --arg n "$name" '.[$n] // empty' <<<"$entries")"
    [[ -n $expected ]] || continue
    target="$APPS_DIR/$name"
    if [[ ! -e $target && ! -L $target ]]; then
      entries="$(jq -c --arg n "$name" 'del(.[$n])' <<<"$entries")"
      continue
    fi
    if [[ -f $target && ! -L $target ]]; then
      current="$(sha256sum "$target" | cut -d' ' -f1)"
      if [[ $current == "$expected" ]]; then
        rm -f "$target"
        entries="$(jq -c --arg n "$name" 'del(.[$n])' <<<"$entries")"
        log "removed unchanged plugin-managed desktop entry $target."
        continue
      fi
    fi
    log "preserving user-modified desktop entry $target; recovery metadata remains in $DESKTOP_STATE." >&2
  done
  tmp="$(mktemp "$STATE_DIR/.desktop-entries.XXXXXX")"
  printf '%s\n' "$entries" >"$tmp"
  mv -f "$tmp" "$DESKTOP_STATE"
}

restore_desktop_entries

# --------------------------------------------------------------- CLI shims

shim_names="$(jq -r '.cliShimHashes // {} | keys[]' <<<"$state" 2>/dev/null || true)"
while IFS= read -r name; do
  [[ -z $name ]] && continue
  dest="$BIN_TARGET/$name"
  expected="$(jq -r --arg n "$name" '.cliShimHashes[$n] // empty' <<<"$state" 2>/dev/null || true)"
  if [[ -f $dest && ! -L $dest && -n $expected ]] \
    && [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$expected" ]]; then
    rm -f "$dest"
    log "removed unchanged plugin-managed CLI shim $dest."
  elif [[ -e $dest || -L $dest ]]; then
    log "preserved unverified or user-modified CLI command $dest." >&2
  fi
done <<<"$shim_names"

# ------------------------------------------------------------- keybinding

if [[ $(jq -r '.keybinding.wired // false' <<<"$state" 2>/dev/null || echo false) == "true" ]]; then
  module="$(jq -r '.keybinding.module // empty' <<<"$state" 2>/dev/null || true)"
  if [[ -n $module && -f $module ]]; then
    module_sha="$(jq -r '.keybinding.moduleSha256 // empty' <<<"$state" 2>/dev/null || true)"
    module_created="$(jq -r '.keybinding.moduleCreatedByUs // false' <<<"$state" 2>/dev/null || true)"
    module_backup="$(jq -r '.keybinding.moduleBackup // empty' <<<"$state" 2>/dev/null || true)"
    current_sha="$(sha256sum "$module" | cut -d' ' -f1)"
    if [[ -n $module_sha && $current_sha == "$module_sha" ]]; then
      if [[ $module_created == true ]]; then
        rm -f "$module"
        log "removed unchanged plugin-managed module $module."
      elif [[ -n $module_backup && -f $module_backup ]]; then
        cp -p "$module_backup" "$module"
        log "restored the pre-existing module $module from its retained backup."
      else
        log "preserved $module: no creation record or recovery backup is available."
      fi
    else
      log "preserved user-modified Hyprland module $module and its backup." >&2
    fi
  fi
  require_created="$(jq -r '.keybinding.requireCreatedByUs // false' <<<"$state" 2>/dev/null || true)"
  require_line='require("default.hypr.require_optional").module("hypr.tide-island")'
  if [[ $require_created == true && -f $HYPR/hyprland.lua ]] \
    && grep -Fxq "$require_line" "$HYPR/hyprland.lua"; then
    mkdir -p "$BACKUPS"
    cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland-require.lua"
    awk -v line="$require_line" '
      !removed && $0 == line { removed = 1; next }
      { print }
    ' "$HYPR/hyprland.lua" >"$HYPR/hyprland.lua.tmp"
    mv "$HYPR/hyprland.lua.tmp" "$HYPR/hyprland.lua"
    log "removed only the exact plugin-managed require line from hyprland.lua."
  fi
else
  log "no keybinding module was wired; leaving hypr config untouched."
fi

# ----------------------------------------------------------- island shortcuts

# Remove the island shortcut block from hyprland.lua, but only when WE wrote it
# (createdByUs) and it is still byte-for-byte what we wrote. A block the user or
# the settings app has since edited is theirs and stays; a block that predated
# the plugin is never touched.
SHORTCUT_BEGIN="-- Tide Island shortcuts: begin (managed by Tide Island Config App)."
SHORTCUT_END="-- Tide Island shortcuts: end."
extract_shortcut_block() {
  [[ -f $1 ]] || return 0
  awk -v b="$SHORTCUT_BEGIN" -v e="$SHORTCUT_END" '
    $0 == b { inb = 1 }
    inb { print }
    $0 == e { inb = 0 }
  ' "$1"
}
if [[ $(jq -r '.shortcutBinding.createdByUs // false' <<<"$state" 2>/dev/null || echo false) == "true" ]]; then
  sb_config="$(jq -r '.shortcutBinding.config // empty' <<<"$state" 2>/dev/null || true)"
  [[ -n $sb_config ]] || sb_config="$HYPR/hyprland.lua"
  sb_sha="$(jq -r '.shortcutBinding.blockSha256 // empty' <<<"$state" 2>/dev/null || true)"
  cur_block="$(extract_shortcut_block "$sb_config")"
  if [[ -z $cur_block ]]; then
    log "no island shortcut block present in $sb_config; nothing to remove."
  else
    cur_sha="$(printf '%s\n' "$cur_block" | sha256sum | awk '{print $1}')"
    if [[ -n $sb_sha && $cur_sha == "$sb_sha" ]]; then
      mkdir -p "$BACKUPS"
      cp "$sb_config" "$BACKUPS/$TSTAMP.hyprland-shortcuts.lua"
      awk -v b="$SHORTCUT_BEGIN" -v e="$SHORTCUT_END" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }
      ' "$sb_config" >"$sb_config.tmp"
      mv "$sb_config.tmp" "$sb_config"
      log "removed our island shortcut block from $sb_config (backup kept)."
    else
      log "the island shortcut block in $sb_config was edited; leaving it untouched."
    fi
  fi
else
  log "no island shortcut block written by this plugin; leaving hypr config untouched."
fi

# ----------------------------------------------------------------- config

if (( opt_purge_config )) && [[ -f $CONFIG_TARGET ]]; then
  mkdir -p "$BACKUPS"
  config_backup="$(mktemp "$BACKUPS/$TSTAMP.tide-island.XXXXXX.json")"
  cp -p "$CONFIG_TARGET" "$config_backup"
  rm -f "$CONFIG_TARGET"
  log "removed $CONFIG_TARGET (backup kept)."
else
  log "left $CONFIG_TARGET in place."
fi

# ---------------------------------------------------------------- runtime

if (( opt_remove_runtime )); then
  PREFIX="${TIDE_ISLAND_PREFIX:-$HOME/.local/share/omarchy-tide-island}"
  unit_conflict=0
  "$SYSTEMCTL" --user stop tide-island.service 2>/dev/null || true
  unit="$HOME/.config/systemd/user/tide-island.service"
  if [[ -f $unit ]] && grep -qF '# managed by mehir.tide-island' "$unit"; then
    unit_sha="$(cat "$PREFIX/.unit-sha256" 2>/dev/null || true)"
    if [[ -n $unit_sha && $(sha256sum "$unit" | cut -d' ' -f1) == "$unit_sha" ]]; then
      rm -f "$unit"
      "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
      log "removed unchanged plugin-managed unit $unit"
    else
      unit_conflict=1
      log "preserved user-modified or unverified unit $unit; inspect it before removing the runtime." >&2
    fi
  fi
  path_state="$(cat "$PATH_STATE" 2>/dev/null || printf '{}')"
  for name in tide-island tide-island-config-app; do
    link="$HOME/.local/bin/$name"
    expected="$(jq -r --arg n "$name" '.[$n] // empty' <<<"$path_state")"
    if [[ ! -e $link && ! -L $link ]]; then
      path_state="$(jq -c --arg n "$name" 'del(.[$n])' <<<"$path_state")"
    elif [[ -L $link && -n $expected && "$(readlink "$link")" == "$expected" ]]; then
      rm -f "$link"
      log "removed $link"
      path_state="$(jq -c --arg n "$name" 'del(.[$n])' <<<"$path_state")"
    else
      log "preserved unowned or user-modified PATH entry $link." >&2
    fi
  done
  if [[ $(jq 'length' <<<"$path_state") -eq 0 ]]; then
    rm -f "$PATH_STATE"
  else
    path_tmp="$(mktemp "$STATE_DIR/.path-links.XXXXXX")"
    printf '%s\n' "$path_state" >"$path_tmp"
    mv -f "$path_tmp" "$PATH_STATE"
  fi
  if [[ -f "$PREFIX/.version" ]]; then
    expected_content="$(cat "$PREFIX/.content-sha256" 2>/dev/null || true)"
    actual_content="$(
      cd "$PREFIX"
      find bin lib share -type f -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    )"
    actual_symlinks="$(
      cd "$PREFIX"
      find bin lib share -type l -printf '%p %l\n' 2>/dev/null | LC_ALL=C sort \
        | sha256sum | cut -d' ' -f1
    )"
    expected_symlinks="$(cat "$PREFIX/.symlink-sha256" 2>/dev/null || true)"
    if [[ -z $expected_symlinks ]]; then
      if find "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share" -type l -print -quit 2>/dev/null | grep -q .; then
        expected_symlinks="unverified"
      else
        expected_symlinks="$actual_symlinks"
      fi
    fi
    extra_prefix_files="$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
      ! -name bin ! -name lib ! -name share ! -name .version ! -name .content-sha256 \
      ! -name .symlink-sha256 ! -name .unit-sha256 -print -quit)"
    if [[ $unit_conflict == 0 && -n $expected_content \
      && $actual_content == "$expected_content" && $actual_symlinks == "$expected_symlinks" \
      && -z $extra_prefix_files ]]; then
      rm -rf "${PREFIX:?}"
      log "removed unchanged bundled runtime $PREFIX"
    else
      log "preserved modified or unverified runtime prefix $PREFIX; review before manual removal." >&2
    fi
  fi
else
  log "kept the bundled runtime."
fi

# ------------------------------------------------------------- tide config

log "preserved Tide Island user configuration at $TIDE_USERCONFIG."

resync_shell

# --------------------------------------------------------------- marker

# The setup-complete marker is transient: it certifies that THIS install
# finished. Clear it on removal so re-adding the plugin runs setup again rather
# than trusting a stale marker and silently leaving the OSD/notification
# stand-down unapplied.
if [[ -f $STATE_DIR/auto-setup.done ]]; then
  rm -f "$STATE_DIR/auto-setup.done"
  log "cleared the setup-complete marker so a re-add sets up again."
fi

# ------------------------------------------------------------------- final

if (( opt_final )); then
  pending_desktop="$(jq 'length' "$DESKTOP_STATE" 2>/dev/null || echo 0)"
  pending_path="$(jq 'length' "$PATH_STATE" 2>/dev/null || echo 0)"
  if { [[ -d $BACKUPS ]] && find "$BACKUPS" -type f -print -quit | grep -q .; } \
    || { [[ -d $STATE_MARKERS ]] && find "$STATE_MARKERS" -type f -print -quit | grep -q .; } \
    || [[ $pending_desktop -gt 0 || $pending_path -gt 0 ]]; then
    log "retaining state, helper, and backups needed for recovery in $STATE_DIR."
  else
    log "no recovery backups remain; removing empty plugin state and helper."
    rm -rf "${STATE_DIR:?}"
    rm -rf "${LIB_DIR:?}"
  fi
fi

log "done."
