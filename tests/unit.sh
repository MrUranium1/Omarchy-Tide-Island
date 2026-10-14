#!/usr/bin/env bash
# Unit tests for scripts/tide-sync.sh. Run from anywhere:
#   bash tests/unit.sh
# Requires: bash, jq, patch, and diff-testable upstream plugin files.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SYNC="$ROOT/scripts/tide-sync.sh"
FAKE="$ROOT/tests/fake-systemctl.sh"
pass=0
fail=0

t() { printf '  - %s\n' "$*"; }

ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A temporary config that points everything at the temp dir.
mkdir -p "$tmp/toggles" "$tmp/home/.local/state/omarchy/toggles"

write_config() { # $1 = coordinateWithBar $2 = startWithBarHidden $3 = stopWithBarShown
  cat >"$tmp/config.json" <<EOF
{
  "coordinateWithBar": $1,
  "startWithBarHidden": $2,
  "stopWithBarShown": $3,
  "togglesDir": "$tmp/toggles"
}
EOF
}

setup_fake() {
  echo "inactive" >"$tmp/active"
  : >"$tmp/calls"
  export TIDE_ISLAND_CONFIG="$tmp/config.json"
  export TIDE_SYNC_SYSTEMCTL="$FAKE"
  export FAKE_SYSTEMCTL_STATE_FILE="$tmp/active"
  export FAKE_SYSTEMCTL_LOG_FILE="$tmp/calls"
}

calls() { wc -l <"$tmp/calls"; }

echo "tide-sync.sh unit tests"

echo "  syntax check"
bash -n "$SYNC" && t "tide-sync.sh parses" && ok || ko

echo "  reconcile matrix (idempotent; no redundant calls)"
setup_fake
write_config true true true
touch "$tmp/toggles/bar-off"

t "bar hidden + service active -> no-op"
echo "active" >"$tmp/active"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 0 ]] && ok || { ko; }

t "bar hidden + service inactive -> one start"
echo "inactive" >"$tmp/active"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 1 && "$(cat "$tmp/active")" == "active" ]] && ok || { ko; }

t "still bar hidden + now active -> no-op"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 1 ]] && ok || { ko; }

t "bar visible + service active -> one stop"
rm -f "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 && "$(cat "$tmp/active")" == "inactive" ]] && ok || { ko; }

t "bar visible + service stopped -> no-op"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "coordinateWithBar=false -> never touches the service"
write_config false true true
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "startWithBarHidden=false -> bar hidden leaves service alone"
write_config true false true
touch "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "stopWithBarShown=false -> bar visible leaves service alone"
write_config true true false
rm -f "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "--dry-run makes no systemctl calls"
write_config true true true
touch "$tmp/toggles/bar-off"
"$SYNC" reconcile --dry-run >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

echo "  probe + config"
setup_fake
write_config true true true
touch "$tmp/toggles/bar-off"
[[ "$("$SYNC" probe)" == "bar-hidden" ]] && ok || ko
rm -f "$tmp/toggles/bar-off"
[[ "$("$SYNC" probe)" == "bar-visible" ]] && ok || ko
"$SYNC" config | jq -e '.config.coordinateWithBar == true' >/dev/null && ok || ko

echo "  defaults parity: default/tide-island.json keys present in Service.qml"
for key in $(jq -r 'keys[]' "$ROOT/default/tide-island.json"); do
  grep -q "      $key:" "$ROOT/Service.qml" && ok || { t "missing key $key in Service.qml" && ko; }
done

echo "  suppression patches apply cleanly to pristine clones then reverse"
for pair in "omarchy.osd:patches/omarchy-osd-suppression.patch:Osd.qml" \
            "omarchy.notifications:patches/omarchy-notifications-suppression.patch:Service.qml"; do
  IFS=: read -r src relpatch entry < <(printf '%s\n' "$pair")
  mkdir -p "$tmp/apply"
  cp "/usr/share/omarchy/shell/plugins/${src#omarchy.}/$entry" "$tmp/apply/$entry"
  if (cd "$tmp/apply" && patch -p1 --batch --no-backup-if-mismatch <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch applies to pristine file" && ok
  else
    t "$relpatch FAILED to apply to pristine file" && ko
  fi
  if (cd "$tmp/apply" && patch -p1 --batch -R --dry-run <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch reverse-applies cleanly" && ok
  else
    t "$relpatch FAILED reverse-apply" && ko
  fi
  rm -rf "$tmp/apply"
done

echo "  ensure-suppression state tracking (sandboxed HOME)"
es_upstream="/usr/share/omarchy/shell/plugins/osd/Osd.qml"
es="$tmp/es"
mkdir -p "$es/bin" "$es/home/.config/omarchy/plugins/mehir.osd"
cat >"$es/bin/omarchy-plugin-list" <<'EOS'
#!/usr/bin/env bash
echo '[{"id":"mehir.osd","firstParty":false,"clonedFrom":"omarchy.osd","enabled":true}]'
EOS
cat >"$es/bin/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$es/bin/omarchy-plugin-list" "$es/bin/omarchy-shell"
printf '{"entryPoints":{"panel":"Osd.qml"}}' >"$es/home/.config/omarchy/plugins/mehir.osd/manifest.json"
es_osd="$es/home/.config/omarchy/plugins/mehir.osd/Osd.qml"
es_state="$es/home/.local/state/omarchy/tide-island/patch-state/mehir.osd"
es_backups="$es/home/.local/state/omarchy/tide-island/backups"
run_es() { HOME="$es/home" PATH="$es/bin:$PATH" bash "$ROOT/scripts/ensure-suppression.sh" "$@"; }

cp "$es_upstream" "$es_osd"
run_es >/dev/null 2>&1 || true
t "apply to a pristine clone patches it and records 'applied'"
grep -q 'The bar-off marker' "$es_osd" && [[ "$(cat "$es_state" 2>/dev/null)" == applied ]] && ok || ko
t "apply backs the pristine file up"
[[ -n "$(ls -1 "$es_backups" 2>/dev/null)" ]] && ok || ko

run_es --restore >/dev/null 2>&1 || true
t "--restore undoes a patch we applied (back to pristine, state cleared)"
cmp -s "$es_osd" "$es_upstream" && [[ ! -f $es_state ]] && ok || ko

# A non-conflicting user edit must survive surgical patch reversal.
run_es >/dev/null 2>&1 || true
printf '\n// user customization\n' >>"$es_osd"
cp "$es_osd" "$es/user-edited.qml"
run_es --restore >"$es/restore-edited.log" 2>&1 || true
t "--restore preserves unrelated edits to a plugin-created clone"
cp "$es_upstream" "$es/expected-restored.qml"
printf '\n// user customization\n' >>"$es/expected-restored.qml"
cmp -s "$es_osd" "$es/expected-restored.qml" && ok || ko
t "keeps the original recovery backup after a user-edited clone is restored"
[[ -n "$(find "$es_backups" -type f -print -quit)" ]] && ok || ko

# A conflict inside the patch hunk must never be repaired by copying the old
# pristine backup over the current user-modified entry point.
cp "$es_upstream" "$es_osd"
run_es >/dev/null 2>&1 || true
sed -i 's/The bar-off marker/The user-off marker/' "$es_osd"
cp "$es_osd" "$es/conflicted.qml"
run_es --restore >"$es/restore-conflict.log" 2>&1 || true
t "--restore reports a conflict and preserves a modified patch hunk"
cmp -s "$es_osd" "$es/conflicted.qml" \
  && grep -q 'conflict' "$es/restore-conflict.log" \
  && find "$es_backups" -type f -print -quit | grep -q . && ok || ko

# Pre-existing suppression: patch the clone, then drop our state marker so the
# clone looks like it was suppressed before the plugin ever ran.
cp "$es_upstream" "$es_osd"
(cd "$es/home/.config/omarchy/plugins/mehir.osd" && patch -p1 --batch --no-backup-if-mismatch <"$ROOT/patches/omarchy-osd-suppression.patch" >/dev/null 2>&1)
rm -f "$es_state"
run_es >/dev/null 2>&1 || true
t "apply on an already-patched clone records 'preexisting'"
[[ "$(cat "$es_state" 2>/dev/null)" == preexisting ]] && ok || ko

run_es --restore >/dev/null 2>&1 || true
t "--restore leaves a pre-existing suppression untouched"
grep -q 'The bar-off marker' "$es_osd" && ok || ko

echo "  teardown clone ownership (sandboxed HOME)"
cr="$tmp/clone-remove"
mkdir -p "$cr/home/.config/omarchy/plugins" "$cr/home/.local/state/omarchy/tide-island" "$cr/bin"
cat >"$cr/bin/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$cr/bin/omarchy-shell"
cr_clone="$cr/home/.config/omarchy/plugins/test.osd"
cr_state="$cr/home/.local/state/omarchy/tide-island"
make_owned_clone() {
  rm -rf "$cr_clone"
  mkdir -p "$cr_clone"
  cp -a /usr/share/omarchy/shell/plugins/osd/. "$cr_clone/"
  baseline="$(
    (
      cd "$cr_clone"
      find . -mindepth 1 -printf '%y %m %P %l\n' | LC_ALL=C sort
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) | sha256sum | cut -d' ' -f1
  )"
  mkdir -p "$cr_state/backups" "$cr_state/patch-state" "$cr_state/clone-baselines" "$cr_state/created-clones"
  cp "$cr_clone/Osd.qml" "$cr_state/backups/20260101.test.osd.Osd.qml"
  printf '%s\n' "$baseline" >"$cr_state/clone-baselines/test.osd"
  : >"$cr_state/created-clones/test.osd"
  (cd "$cr_clone" && patch -p1 --batch --no-backup <"$ROOT/patches/omarchy-osd-suppression.patch" >/dev/null)
  printf 'applied\n' >"$cr_state/patch-state/test.osd"
  jq -n --arg baseline "$baseline" \
    '{suppression:{osd:{after:"test.osd",createdByUs:true,baselineFingerprint:$baseline}}}' \
    >"$cr_state/installed.json"
}
run_clone_teardown() {
  HOME="$cr/home" PATH="$cr/bin:/usr/bin:/bin" \
    bash "$ROOT/scripts/teardown.sh" --remove-clones
}

make_owned_clone
run_clone_teardown >"$cr/remove-clean.log" 2>&1
t "removes an unchanged plugin-created clone after restoring its patch"
[[ ! -e $cr_clone ]] && ok || ko

make_owned_clone
printf 'user customization\n' >"$cr_clone/User.qml"
cp "$cr_clone/User.qml" "$cr/user.qml"
run_clone_teardown >"$cr/remove-edited.log" 2>&1
t "preserves user edits in a plugin-created clone requested for removal"
[[ -f "$cr_clone/User.qml" ]] && cmp -s "$cr_clone/User.qml" "$cr/user.qml" \
  && ! grep -q 'The bar-off marker' "$cr_clone/Osd.qml" && ok || ko
t "reports why an edited clone was retained"
grep -q 'preserving modified clone' "$cr/remove-edited.log" && ok || ko
t "keeps the clone recovery backup after conflict-safe removal"
[[ -f "$cr_state/backups/20260101.test.osd.Osd.qml" ]] && ok || ko

make_owned_clone
jq '.suppression.osd.createdByUs = false' "$cr_state/installed.json" >"$cr_state/installed.json.tmp"
mv "$cr_state/installed.json.tmp" "$cr_state/installed.json"
sed -i 's/The bar-off marker/User-tuned OSD condition/' "$cr_clone/Osd.qml"
cp "$cr_clone/Osd.qml" "$cr/user-modified-preexisting.qml"
run_clone_teardown >"$cr/remove-preexisting-conflict.log" 2>&1
t "preserves an overlapping user edit in a pre-existing clone"
cmp -s "$cr_clone/Osd.qml" "$cr/user-modified-preexisting.qml" \
  && grep -q 'conflict restoring' "$cr/remove-preexisting-conflict.log" \
  && [[ -f "$cr_state/backups/20260101.test.osd.Osd.qml" ]] && ok || ko

echo "  install-tide-runtime.sh (sandboxed HOME, forced bundle)"
ir="$tmp/ir"
ir_prefix="$ir/home/.local/share/omarchy-tide-island"
mkdir -p "$ir/home/.local/bin" "$ir/home/.local/share/applications" "$ir/bin"
printf 'user-owned Tide launcher\n' >"$ir/home/.local/share/applications/tide-island.desktop"
cp "$ir/home/.local/share/applications/tide-island.desktop" "$ir/preexisting.desktop"
printf 'user-owned config command\n' >"$ir/bin/user-config-app"
ln -s "$ir/bin/user-config-app" "$ir/home/.local/bin/tide-island-config-app"
cat >"$ir/bin/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$ir/bin/omarchy-shell"
run_ir() {
  HOME="$ir/home" TIDE_ISLAND_FORCE_BUNDLE=1 TIDE_ISLAND_PREFIX="$ir_prefix" \
    TIDE_SYNC_SYSTEMCTL=/bin/true bash "$ROOT/scripts/install-tide-runtime.sh" "$@"
}
run_ir >/dev/null 2>&1
t "installs the launcher and backend into the prefix"
[[ -x "$ir_prefix/bin/tide-island" && -f "$ir_prefix/lib/libIslandBackend.so" ]] && ok || ko
t "installs the QML tree"
[[ -f "$ir_prefix/share/tide-island/shell.qml" ]] && ok || ko
t "installs the settings GUI into the prefix"
[[ -x "$ir_prefix/bin/tide-island-config-app" ]] && ok || ko
t "links the config app onto PATH"
[[ -L "$ir/home/.local/bin/tide-island-config-app" ]] && ok || ko
t "preserves a pre-existing user PATH symlink"
[[ "$(readlink "$ir/home/.local/bin/tide-island-config-app")" == "$ir/bin/user-config-app" ]] && ok || ko
t "installs both desktop entries"
[[ -f "$ir/home/.local/share/applications/tide-island.desktop" \
  && -f "$ir/home/.local/share/applications/tide-island-config.desktop" ]] && ok || ko
t "preserves a pre-existing user desktop entry byte-for-byte"
cmp -s "$ir/home/.local/share/applications/tide-island.desktop" "$ir/preexisting.desktop" && ok || ko
t "records ownership only for the desktop entry it created"
jq -e 'has("tide-island-config.desktop") and (has("tide-island.desktop") | not)' \
  "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json" >/dev/null && ok || ko
t "writes a user unit carrying our marker"
grep -q 'managed by mehir.tide-island' "$ir/home/.config/systemd/user/tide-island.service" && ok || ko
cp "$ir/home/.config/systemd/user/tide-island.service" "$ir/unit-before-interruption"
cp "$ir_prefix/.unit-sha256" "$ir/unit-hash-before-interruption"
rm "$ir_prefix/.unit-sha256"
printf '# user edit during interrupted install\n' >>"$ir/home/.config/systemd/user/tide-island.service"
cp "$ir/home/.config/systemd/user/tide-island.service" "$ir/unit-user-edited"
run_ir >"$ir/unit-interruption.log" 2>&1
t "preserves a managed-looking service unit when ownership metadata is missing"
cmp -s "$ir/home/.config/systemd/user/tide-island.service" "$ir/unit-user-edited" \
  && grep -q 'ownership metadata is missing' "$ir/unit-interruption.log" && ok || ko
cp "$ir/unit-before-interruption" "$ir/home/.config/systemd/user/tide-island.service"
cp "$ir/unit-hash-before-interruption" "$ir_prefix/.unit-sha256"
t "links tide-island onto PATH"
[[ -L "$ir/home/.local/bin/tide-island" ]] && ok || ko
t "second run is idempotent"
run_ir >/dev/null 2>&1 && [[ "$(cat "$ir_prefix/.version")" == "$(cat "$ROOT/vendor/tide-island/VERSION")" ]] && ok || ko
t "an interrupted install with missing ownership metadata preserves existing desktop files"
cp "$ir/home/.local/share/applications/tide-island-config.desktop" "$ir/managed-before-interruption.desktop"
cp "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json" "$ir/desktop-state.before"
rm "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json"
run_ir >/dev/null 2>&1
cmp -s "$ir/home/.local/share/applications/tide-island-config.desktop" "$ir/managed-before-interruption.desktop" \
  && ! test -e "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json" && ok || ko
cp "$ir/desktop-state.before" "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json"

run_ir_teardown() {
  HOME="$ir/home" PATH="$ir/bin:/usr/bin:/bin" TIDE_ISLAND_PREFIX="$ir_prefix" \
    TIDE_SYNC_SYSTEMCTL=/bin/true bash "$ROOT/scripts/teardown.sh" --remove-runtime
}
run_ir_teardown >/dev/null 2>"$ir/teardown-unmodified.log"
t "removes an unchanged plugin-managed desktop entry"
[[ ! -e "$ir/home/.local/share/applications/tide-island-config.desktop" ]] && ok || ko
t "keeps the pre-existing desktop entry on removal"
cmp -s "$ir/home/.local/share/applications/tide-island.desktop" "$ir/preexisting.desktop" && ok || ko
t "keeps the unowned user PATH symlink on removal"
[[ "$(readlink "$ir/home/.local/bin/tide-island-config-app")" == "$ir/bin/user-config-app" ]] && ok || ko

run_ir >/dev/null 2>&1
printf '\n# user edit\n' >>"$ir/home/.local/share/applications/tide-island-config.desktop"
cp "$ir/home/.local/share/applications/tide-island-config.desktop" "$ir/modified.desktop"
run_ir_teardown >/dev/null 2>"$ir/teardown-modified.log"
t "preserves a user-modified plugin-managed desktop entry"
cmp -s "$ir/home/.local/share/applications/tide-island-config.desktop" "$ir/modified.desktop" && ok || ko
t "retains desktop ownership metadata for manual conflict recovery"
jq -e 'has("tide-island-config.desktop")' \
  "$ir/home/.local/state/omarchy/tide-island/desktop-entries.json" >/dev/null && ok || ko

run_ir >/dev/null 2>&1
printf 'local runtime edit\n' >"$ir_prefix/share/tide-island/user-custom-file"
if run_ir >"$ir/modified-runtime-install.log" 2>&1; then
  t "refuses to overwrite a user-modified runtime during reinstallation"
  ko
else
  t "refuses to overwrite a user-modified runtime during reinstallation"
  grep -q 'refusing to replace a modified runtime prefix' "$ir/modified-runtime-install.log" \
  && grep -q 'local runtime edit' "$ir_prefix/share/tide-island/user-custom-file" && ok || ko
fi
run_ir_teardown >/dev/null 2>"$ir/teardown-modified-runtime.log"
t "preserves a user-modified runtime prefix during removal"
[[ -f "$ir_prefix/share/tide-island/user-custom-file" ]] \
  && grep -q 'local runtime edit' "$ir_prefix/share/tide-island/user-custom-file" && ok || ko
rm "$ir_prefix/share/tide-island/user-custom-file"
run_ir_teardown >/dev/null 2>"$ir/teardown-restored-runtime.log"

run_ir >/dev/null 2>&1
ln -s "$ir_prefix/share/tide-island/shell.qml" "$ir_prefix/share/tide-island/user-runtime-link"
if run_ir >"$ir/modified-runtime-link-install.log" 2>&1; then
  t "refuses to replace a runtime containing an untracked user symlink"
  ko
else
  t "refuses to replace a runtime containing an untracked user symlink"
  grep -q 'refusing to replace a modified runtime prefix' "$ir/modified-runtime-link-install.log" \
    && [[ -L "$ir_prefix/share/tide-island/user-runtime-link" ]] && ok || ko
fi
run_ir_teardown >/dev/null 2>"$ir/teardown-modified-runtime-link.log"
t "preserves an untracked user symlink inside the runtime on removal"
[[ -L "$ir_prefix/share/tide-island/user-runtime-link" ]] && ok || ko
rm "$ir_prefix/share/tide-island/user-runtime-link"
run_ir_teardown >/dev/null 2>"$ir/teardown-restored-runtime-link.log"

# A vendored edit must redeploy even when upstream VERSION is unchanged.
fr="$tmp/fakeroot"
mkdir -p "$fr/vendor/tide-island/bin" "$fr/vendor/tide-island/lib" \
  "$fr/vendor/tide-island/share/tide-island" "$fr/scripts"
cp "$ROOT/scripts/install-tide-runtime.sh" "$fr/scripts/"
printf '1.0.41\n' >"$fr/vendor/tide-island/VERSION"
printf '#!/bin/true\n' >"$fr/vendor/tide-island/bin/tide-island"
printf '#!/bin/true\n' >"$fr/vendor/tide-island/bin/tide-island-config-app"
chmod 0755 "$fr/vendor/tide-island/bin/"*
: >"$fr/vendor/tide-island/lib/libIslandBackend.so"
printf '// v1\n' >"$fr/vendor/tide-island/share/tide-island/shell.qml"
fr_prefix="$fr/home/.local/share/omarchy-tide-island"
run_fr() {
  HOME="$fr/home" TIDE_ISLAND_FORCE_BUNDLE=1 TIDE_ISLAND_PREFIX="$fr_prefix" \
    TIDE_SYNC_SYSTEMCTL=/bin/true bash "$fr/scripts/install-tide-runtime.sh" "$@"
}
run_fr >/dev/null 2>&1
t "content refresh: first install deploys the tree"
grep -q '// v1' "$fr_prefix/share/tide-island/shell.qml" && ok || ko
printf '// v2\n' >"$fr/vendor/tide-island/share/tide-island/shell.qml"
run_fr >/dev/null 2>&1
t "content refresh: a vendored edit redeploys at the same VERSION"
grep -q '// v2' "$fr_prefix/share/tide-island/shell.qml" && ok || ko
run_fr >/dev/null 2>&1
t "content refresh: unchanged tree stays a no-op"
grep -q '// v2' "$fr_prefix/share/tide-island/shell.qml" && ok || ko

printf 'FOREIGN UNIT\n' >"$ir/home/.config/systemd/user/tide-island.service"
run_ir >/dev/null 2>&1
t "never clobbers a foreign (non-managed) unit"
grep -q 'FOREIGN UNIT' "$ir/home/.config/systemd/user/tide-island.service" && ok || ko

echo "  ensure-mount.sh mount enforcement (problem 1 fix)"
EM="$ROOT/scripts/ensure-mount.sh"
umk() { # $1 = HOME subtree; builds sandbox omarchy-shell + patched clone files
  local uh="$1"
  mkdir -p "$uh/.local/state/omarchy/tide-island" \
    "$uh/.config/omarchy/plugins/mehir.osd" \
    "$uh/.config/omarchy/plugins/mehir.notifications"
  printf '// The bar-off marker\n' >"$uh/.config/omarchy/plugins/mehir.osd/Osd.qml"
  printf '// popupsSuppressed\n' >"$uh/.config/omarchy/plugins/mehir.notifications/Service.qml"
  cat >"$tmp/bin/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
st="$HOME/.local/state/omarchy/tide-island/mount-state"
mkdir -p "$(dirname "$st")"
if [[ ${1:-} == shell && ${2:-} == rescanPlugins ]]; then
  d="$HOME/.config/omarchy/plugins"
  osd=0; notif=0
  [[ -f "$d/mehir.osd/Osd.qml" ]] && grep -q 'The bar-off marker' "$d/mehir.osd/Osd.qml" && osd=1
  [[ -f "$d/mehir.notifications/Service.qml" ]] && grep -q 'popupsSuppressed' "$d/mehir.notifications/Service.qml" && notif=1
  printf 'osd=%s notifications=%s\n' "$([[ $osd == 1 ]] && echo mehir.osd || echo omarchy.osd)" \
    "$([[ $notif == 1 ]] && echo mehir.notifications || echo omarchy.notifications)" >"$st"
  exit 0
fi
[[ ${1:-} == osd && ${2:-} == syncSuppression ]] && { grep -qw 'osd=mehir.osd' "$st" && exit 0 || exit 1; }
[[ ${1:-} == notifications && ${2:-} == syncSuppression ]] && { grep -qw 'notifications=mehir.notifications' "$st" && exit 0 || exit 1; }
exit 0
EOS
  chmod +x "$tmp/bin/omarchy-shell"
}
mstate() { printf 'osd=%s notifications=%s\n' "$1" "$2" >"$tmp/uh/.local/state/omarchy/tide-island/mount-state"; }
mkdir -p "$tmp/bin"
umk "$tmp/uh"
mstate "mehir.osd" "mehir.notifications"
HOME="$tmp/uh" PATH="$tmp/bin:$PATH" bash "$EM" --marker "$tmp/m1.marker" >/dev/null 2>&1
t "no bounce needed when the patched clones already serve"
[[ -f "$tmp/m1.marker" ]] && ok || ko

mstate "omarchy.osd" "omarchy.notifications"
HOME="$tmp/uh" PATH="$tmp/bin:$PATH" bash "$EM" --marker "$tmp/m2.marker" >/dev/null 2>&1
t "bounces rescan and mounts the patched clones when the runtime lags (problem 1 repro)"
[[ -f "$tmp/m2.marker" ]] && ok || ko
grep -qw 'osd=mehir.osd' "$tmp/uh/.local/state/omarchy/tide-island/mount-state" && ok || ko
grep -qw 'notifications=mehir.notifications' "$tmp/uh/.local/state/omarchy/tide-island/mount-state" && ok || ko

sed -i '/The bar-off marker/d' "$tmp/uh/.config/omarchy/plugins/mehir.osd/Osd.qml"
mstate "omarchy.osd" "omarchy.notifications"
rc=0
HOME="$tmp/uh" PATH="$tmp/bin:$PATH" bash "$EM" --marker "$tmp/m3.marker" >/dev/null 2>&1 || rc=$?
t "fails loudly and leaves no marker when the patched clone cannot serve"
[[ $rc -eq 1 ]] && ok || ko
[[ ! -e "$tmp/m3.marker" ]] && ok || ko
grep -q 'FAILED' "$tmp/uh/.local/state/omarchy/tide-island/ensure-mount.log" 2>/dev/null && ok || ko

echo
echo "unit: $pass passed, $fail failed"
(( fail == 0 ))
