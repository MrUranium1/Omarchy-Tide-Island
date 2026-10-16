#!/usr/bin/env bash
# Privacy tests for the bundled Tide Island settings config:
#   * scripts/harden-tide-config.sh repairs an existing group/world-readable
#     directory and userconfig.json in place, without changing the contents;
#   * it refuses to act through a symlinked config dir or file, so a planted
#     link can never redirect the chmod to an unrelated target;
#   * the hardened launcher (vendor/tide-island/bin/tide-island-config-app)
#     enforces umask 077 on the settings app, so the QSaveFile temp file it
#     creates and then atomically renames is 0600 even under a permissive
#     umask, and it repairs an existing loose file before the app runs;
#   * the launcher refuses to start the GUI if a saved password would still be
#     readable by other users after repair (and never chmods a symlink target);
#   * it resolves XDG_CONFIG_HOME/HOME and handles paths with spaces;
#   * repeated saves keep the file 0600.
# The native app is faked, so no GUI or Qt runtime is needed.
# Run from anywhere: bash tests/config-perms.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER="$ROOT/vendor/tide-island/bin/tide-island-config-app"
HELPER="$ROOT/scripts/harden-tide-config.sh"
pass=0
fail=0

t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mode_of() { stat -c '%a' "$1" 2>/dev/null || printf 'missing'; }

echo "Tide Island settings config privacy tests"

echo "  syntax"
bash -n "$WRAPPER" && t "hardened launcher parses" && ok || ko
bash -n "$HELPER" && t "harden-tide-config.sh parses" && ok || ko

# ---------------------------------------------------- repair helper contract
echo "  harden-tide-config.sh repairs existing config in place"
hdir="$tmp/harden"
mkdir -p "$hdir"
chmod 0777 "$hdir"
printf '{"tlpSudoPassword":"hunter2"}\n' >"$hdir/userconfig.json"
chmod 0666 "$hdir/userconfig.json"
before="$(cat "$hdir/userconfig.json")"
bash "$HELPER" "$hdir" >/dev/null 2>&1
t "directory tightened to 0700"
[[ "$(mode_of "$hdir")" == 700 ]] && ok || ko
t "userconfig.json tightened to 0600"
[[ "$(mode_of "$hdir/userconfig.json")" == 600 ]] && ok || ko
t "contents preserved byte-for-byte"
[[ "$(cat "$hdir/userconfig.json")" == "$before" ]] && ok || ko

t "rerun is a no-op and still succeeds"
bash "$HELPER" "$hdir" && [[ "$(mode_of "$hdir/userconfig.json")" == 600 ]] && ok || ko

t "a 0644 file is tightened"
chmod 0644 "$hdir/userconfig.json"
bash "$HELPER" "$hdir" >/dev/null 2>&1
[[ "$(mode_of "$hdir/userconfig.json")" == 600 ]] && ok || ko

t "an absent file is not created"
rm -f "$hdir/userconfig.json"
bash "$HELPER" "$hdir" >/dev/null 2>&1
[[ ! -e "$hdir/userconfig.json" ]] && ok || ko

t "an absent directory is a clean no-op"
bash "$HELPER" "$tmp/does-not-exist" >/dev/null 2>&1 \
  && [[ ! -e "$tmp/does-not-exist" ]] && ok || ko

t "is a clean no-op when neither HOME nor XDG_CONFIG_HOME is set"
rc=0
( env -u XDG_CONFIG_HOME -u HOME bash "$HELPER" ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] && ok || ko

echo "  harden-tide-config.sh never follows a symlink"
hsdir="$tmp/hardsym"
mkdir -p "$hsdir"
chmod 0755 "$hsdir"
hstarget="$tmp/hard-target.json"
printf '{"tlpSudoPassword":"hunter2"}\n' >"$hstarget"
chmod 0644 "$hstarget"
ln -s "$hstarget" "$hsdir/userconfig.json"
rc=0
bash "$HELPER" "$hsdir" >/dev/null 2>&1 || rc=$?
t "refuses a symlinked userconfig and leaves the target untouched"
[[ "$(mode_of "$hstarget")" == 644 ]] && [[ -L "$hsdir/userconfig.json" ]] && [[ $rc -ne 0 ]] \
  && ok || ko

hrdir="$tmp/hard-realdir"
mkdir -p "$hrdir"
printf '{"tlpSudoPassword":"hunter2"}\n' >"$hrdir/userconfig.json"
chmod 0755 "$hrdir"
chmod 0644 "$hrdir/userconfig.json"
hldir="$tmp/hard-linkdir"
ln -s "$hrdir" "$hldir"
rc=0
bash "$HELPER" "$hldir" >/dev/null 2>&1 || rc=$?
t "refuses a symlinked config directory and leaves the target untouched"
[[ "$(mode_of "$hrdir")" == 755 ]] && [[ "$(mode_of "$hrdir/userconfig.json")" == 644 ]] \
  && [[ -L "$hldir" ]] && [[ $rc -ne 0 ]] && ok || ko

# ------------------------------------------------------- hardened launcher
echo "  hardened launcher enforces user-only permissions"
lbin="$tmp/bin"
ldir="$tmp/xdg/tide-island"
mkdir -p "$lbin" "$ldir"
cp "$WRAPPER" "$lbin/tide-island-config-app"
cat >"$lbin/tide-island-config-app.real" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'umask=%s\n' "$(umask)" >>"${FAKE_LOG:?}"
printf 'args=%s\n' "$*" >>"${FAKE_LOG:?}"
printf 'seen=%s\n' "$([[ -f $FAKE_CFG ]] && stat -c '%a' "$FAKE_CFG" || echo absent)" >>"${FAKE_LOG:?}"
# Emulate QSaveFile::open + commit: the temporary file is created with
# 0666 & ~umask, inherits an existing target's mode, and is renamed over it.
existing=""
[[ -f $FAKE_CFG ]] && existing="$(stat -c '%a' "$FAKE_CFG")"
tmpfile="${FAKE_CFG}.tmp.$$"
rm -f "$tmpfile"
: >"$tmpfile"
if [[ -n $existing ]]; then chmod "$existing" "$tmpfile"; fi
printf '{"tlpSudoPassword":"secret"}\n' >"$tmpfile"
mv -f "$tmpfile" "$FAKE_CFG"
printf 'saved=%s\n' "$(stat -c '%a' "$FAKE_CFG")" >>"${FAKE_LOG:?}"
exit "${FAKE_EXIT:-0}"
EOS
chmod 0755 "$lbin/tide-island-config-app" "$lbin/tide-island-config-app.real"

lcfg="$ldir/userconfig.json"
llog="$tmp/launcher.log"

t "launcher forces umask 077 on the app"
: >"$llog"
( umask 022; XDG_CONFIG_HOME="$tmp/xdg" FAKE_LOG="$llog" FAKE_CFG="$lcfg" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
grep -qE '^umask=0*77$' "$llog" && ok || ko

t "launcher tightens the config directory to 0700"
chmod 0755 "$ldir"
( umask 022; XDG_CONFIG_HOME="$tmp/xdg" FAKE_LOG="$llog" FAKE_CFG="$lcfg" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
[[ "$(mode_of "$ldir")" == 700 ]] && ok || ko

t "a fresh save under the launcher lands 0600"
[[ -f $lcfg && "$(mode_of "$lcfg")" == 600 ]] && ok || ko

t "without the launcher the same save is 0644 (regression guard)"
rm -f "$lcfg"
: >"$llog"
( umask 022; FAKE_LOG="$llog" FAKE_CFG="$lcfg" "$lbin/tide-island-config-app.real" ) >/dev/null 2>&1 || true
[[ "$(mode_of "$lcfg")" == 644 ]] && ok || ko

t "repeated saves keep the file 0600"
: >"$llog"
for _ in 1 2 3; do
  ( umask 022; XDG_CONFIG_HOME="$tmp/xdg" FAKE_LOG="$llog" FAKE_CFG="$lcfg" \
      "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
done
grep -qE '^saved=600$' "$llog" && [[ "$(mode_of "$lcfg")" == 600 ]] && ok || ko

t "launcher repairs a pre-existing 0666 file before the app runs"
chmod 0666 "$lcfg"
: >"$llog"
( umask 022; XDG_CONFIG_HOME="$tmp/xdg" FAKE_LOG="$llog" FAKE_CFG="$lcfg" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
grep -qE '^seen=600$' "$llog" && [[ "$(mode_of "$lcfg")" == 600 ]] && ok || ko

t "launcher passes arguments through and propagates the exit code"
: >"$llog"
rc=0
( umask 022; XDG_CONFIG_HOME="$tmp/xdg" FAKE_LOG="$llog" FAKE_CFG="$lcfg" FAKE_EXIT=7 \
    "$lbin/tide-island-config-app" --ensure-niri-shortcuts ) >/dev/null 2>&1 || rc=$?
grep -qE '^args=--ensure-niri-shortcuts$' "$llog" && [[ $rc -eq 7 ]] && ok || ko

echo "  hardened launcher fail-safe and edge cases"
# A chmod shim that always fails, so repair cannot succeed.
mkdir -p "$tmp/fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/fakebin/chmod"
chmod 0755 "$tmp/fakebin/chmod"

# Exposed (world-readable file in a traversable directory) and repair fails:
# the GUI must not start.
fsdir="$tmp/failsafe/tide-island"
mkdir -p "$fsdir"
printf '{"tlpSudoPassword":"secret"}\n' >"$fsdir/userconfig.json"
chmod 0755 "$fsdir"
chmod 0644 "$fsdir/userconfig.json"
: >"$llog"
rc=0
( umask 022; PATH="$tmp/fakebin:$PATH" XDG_CONFIG_HOME="$tmp/failsafe" \
    FAKE_LOG="$llog" FAKE_CFG="$fsdir/userconfig.json" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || rc=$?
t "refuses to launch the GUI when an exposed file cannot be tightened"
[[ $rc -eq 1 ]] && ! grep -q '^args=' "$llog" && ok || ko

# Same-exposed state but a non-GUI caller (shortcut wiring) may proceed.
: >"$llog"
rc=0
( umask 022; PATH="$tmp/fakebin:$PATH" XDG_CONFIG_HOME="$tmp/failsafe" \
    FAKE_LOG="$llog" FAKE_CFG="$fsdir/userconfig.json" \
    "$lbin/tide-island-config-app" --ensure-niri-shortcuts ) >/dev/null 2>&1 || rc=$?
t "still allows --ensure-niri-shortcuts through (it never handles the password)"
grep -q '^args=--ensure-niri-shortcuts$' "$llog" && ok || ko

# Not exposed: the directory already blocks traversal, so a 0644 file is not a
# leak and the app runs even though chmod failed.
fsdir2="$tmp/failsafe2/tide-island"
mkdir -p "$fsdir2"
printf '{"tlpSudoPassword":"secret"}\n' >"$fsdir2/userconfig.json"
chmod 0700 "$fsdir2"
chmod 0644 "$fsdir2/userconfig.json"
: >"$llog"
( umask 022; PATH="$tmp/fakebin:$PATH" XDG_CONFIG_HOME="$tmp/failsafe2" \
    FAKE_LOG="$llog" FAKE_CFG="$fsdir2/userconfig.json" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
t "runs when the directory already blocks traversal"
grep -q '^args=' "$llog" && ok || ko

# A symlinked password file is never chmod'd through, even when the file is
# world-readable; and because it is exposed it is refused, so the link target
# keeps its original mode.
fsdir3="$tmp/failsafe3/tide-island"
mkdir -p "$fsdir3"
fstarget="$tmp/failsafe3/target.json"
printf '{"tlpSudoPassword":"secret"}\n' >"$fstarget"
chmod 0666 "$fstarget"
ln -s "$fstarget" "$fsdir3/userconfig.json"
chmod 0755 "$fsdir3"
: >"$llog"
rc=0
( umask 022; PATH="$tmp/fakebin:$PATH" XDG_CONFIG_HOME="$tmp/failsafe3" \
    FAKE_LOG="$llog" FAKE_CFG="$fsdir3/userconfig.json" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || rc=$?
t "never chmods through a symlinked userconfig (target untouched, refused)"
[[ "$(mode_of "$fstarget")" == 666 ]] && [[ -L "$fsdir3/userconfig.json" ]] \
  && [[ $rc -eq 1 ]] && ! grep -q '^args=' "$llog" && ok || ko

# Missing native target.
nobin="$tmp/nobin"
mkdir -p "$nobin"
cp "$WRAPPER" "$nobin/tide-island-config-app"
chmod 0755 "$nobin/tide-island-config-app"
rc=0
( XDG_CONFIG_HOME="$tmp/emptycfg" "$nobin/tide-island-config-app" ) >/dev/null 2>&1 || rc=$?
t "exits 127 when the native launcher target is missing"
[[ $rc -eq 127 ]] && ok || ko

# XDG_CONFIG_HOME unset: fall back to $HOME/.config.
hhome="$tmp/homerun"
mkdir -p "$hhome/.config/tide-island"
printf '{"tlpSudoPassword":"secret"}\n' >"$hhome/.config/tide-island/userconfig.json"
chmod 0777 "$hhome/.config/tide-island"
chmod 0666 "$hhome/.config/tide-island/userconfig.json"
( env -u XDG_CONFIG_HOME HOME="$hhome" FAKE_LOG="$llog" \
    FAKE_CFG="$hhome/.config/tide-island/userconfig.json" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
t "repairs under \$HOME/.config when XDG_CONFIG_HOME is unset"
[[ "$(mode_of "$hhome/.config/tide-island")" == 700 ]] \
  && [[ "$(mode_of "$hhome/.config/tide-island/userconfig.json")" == 600 ]] && ok || ko

# Path with spaces.
spbase="$tmp/dir with spaces"
spdir="$spbase/tide-island"
mkdir -p "$spdir"
printf '{"tlpSudoPassword":"secret"}\n' >"$spdir/userconfig.json"
chmod 0777 "$spdir"
chmod 0666 "$spdir/userconfig.json"
( XDG_CONFIG_HOME="$spbase" FAKE_LOG="$llog" FAKE_CFG="$spdir/userconfig.json" \
    "$lbin/tide-island-config-app" ) >/dev/null 2>&1 || true
t "handles a config path containing spaces"
[[ "$(mode_of "$spdir")" == 700 ]] && [[ "$(mode_of "$spdir/userconfig.json")" == 600 ]] \
  && ok || ko

echo
printf 'config-perms: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
