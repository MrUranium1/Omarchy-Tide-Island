#!/usr/bin/env bash
# Regression test for the upgrade migration (scripts/migrate.sh).
#
# Simulates an already-configured installation that predates the config-privacy
# fix: an existing auto-setup.done marker (so the shell's first-load auto-setup
# is skipped), the OLD bundled runtime whose settings app is the native binary
# at bin/tide-island-config-app (no hardened wrapper / .real), and a
# group/world-readable userconfig.json that can hold a TLP sudo password. It
# then runs the migration the shell service runs on every load and asserts that:
#
#   * the runtime is refreshed so the config-app launch path is the hardened
#     launcher, without touching a customized config or dropping the marker;
#   * the config directory/file are repaired in place to 0700 / 0600 with the
#     saved password preserved byte-for-byte;
#   * a second run is an idempotent no-op, but a config loosened afterwards is
#     re-tightened;
#   * a symlinked userconfig is refused (never chmod'd through) and reported,
#     and a user-modified runtime is preserved rather than clobbered.
#
# Run from anywhere: bash tests/migrate.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MIGRATE="$ROOT/scripts/migrate.sh"
pass=0
fail=0
t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"
# Force the bundled runtime even if this machine has the tide-island package on
# PATH, and keep the runtime installer from poking the real user systemd.
export TIDE_ISLAND_FORCE_BUNDLE=1
export TIDE_SYNC_SYSTEMCTL=true
unset TIDE_ISLAND_PREFIX XDG_CONFIG_HOME || true

PREFIX="$HOME/.local/share/omarchy-tide-island"
STATE="$HOME/.local/state/omarchy/tide-island"
CFGDIR="$HOME/.config/tide-island"
CFG="$CFGDIR/userconfig.json"
MARKER="$STATE/auto-setup.done"

mode_of() { stat -c '%a' "$1" 2>/dev/null || printf 'missing'; }
content_hash() {
  ( cd "$1" 2>/dev/null \
    && { find bin lib share -type f -print0 2>/dev/null \
      | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; } ) || true
}

echo "Tide Island upgrade migration tests"
bash -n "$MIGRATE" && t "migrate.sh parses" && ok || ko

# ------------------------------------------------ model a pre-fix installation
# Build a valid runtime, then downgrade it to the old layout: the native app
# lives at bin/tide-island-config-app and there is no wrapper or .real.
bash "$ROOT/scripts/install-tide-runtime.sh" >/dev/null 2>&1
cp -f "$PREFIX/bin/tide-island-config-app.real" "$PREFIX/bin/tide-island-config-app"
chmod 0755 "$PREFIX/bin/tide-island-config-app"
rm -f "$PREFIX/bin/tide-island-config-app.real"
content_hash "$PREFIX" >"$PREFIX/.content-sha256"

t "precondition: installed config-app is the native binary, not the wrapper"
! grep -q 'umask 077' "$PREFIX/bin/tide-island-config-app" \
  && [[ ! -e "$PREFIX/bin/tide-island-config-app.real" ]] && ok || ko

mkdir -p "$CFGDIR" "$STATE"
printf '{"tlpSudoPassword":"hunter2","islandWidth":321}\n' >"$CFG"
chmod 0755 "$CFGDIR"
chmod 0644 "$CFG"
: >"$MARKER"
cp "$CFG" "$tmp/userconfig.before"

t "precondition: config is group/world readable"
[[ "$(mode_of "$CFGDIR")" == 755 && "$(mode_of "$CFG")" == 644 ]] && ok || ko
t "precondition: auto-setup.done marker exists (setup already ran)"
[[ -f "$MARKER" ]] && ok || ko
t "precondition: config-app PATH link points at the native binary"
[[ "$(readlink -f "$HOME/.local/bin/tide-island-config-app" 2>/dev/null)" == "$PREFIX/bin/tide-island-config-app" ]] \
  && ok || ko

# --------------------------------------------------------------- the migration
rm -f "$STATE/migrate.sha256"
if bash "$MIGRATE" --auto >"$tmp/m1.log" 2>&1; then
  t "migration exits 0 on an existing installation" && ok
else
  t "migration failed" && ko
  tail -n20 "$tmp/m1.log"
fi

t "runtime refreshed to the hardened launcher"
grep -q 'umask 077' "$PREFIX/bin/tide-island-config-app" \
  && grep -q 'tide-island-config-app.real' "$PREFIX/bin/tide-island-config-app" && ok || ko
t "native app restored beside the wrapper"
[[ -x "$PREFIX/bin/tide-island-config-app.real" ]] && ok || ko
t "config-app launch path now resolves to the hardened launcher"
linked="$(readlink -f "$HOME/.local/bin/tide-island-config-app" 2>/dev/null || true)"
[[ "$linked" == "$PREFIX/bin/tide-island-config-app" ]] \
  && grep -q 'umask 077' "$linked" && ok || ko

t "config directory repaired to 0700"
[[ "$(mode_of "$CFGDIR")" == 700 ]] && ok || ko
t "userconfig repaired to 0600"
[[ "$(mode_of "$CFG")" == 600 ]] && ok || ko
t "saved password and settings preserved byte-for-byte"
cmp -s "$CFG" "$tmp/userconfig.before" && ok || ko
t "auto-setup.done preserved (no re-setup or marker deletion required)"
[[ -f "$MARKER" ]] && ok || ko
t "migration generation recorded"
[[ -s "$STATE/migrate.sha256" ]] && ok || ko

# -------------------------------------------------------------- idempotency
sum_before="$(sha256sum "$PREFIX/bin/tide-island-config-app" | cut -d' ' -f1)"
bash "$MIGRATE" --auto >/dev/null 2>&1 && t "second migration exits 0" && ok || ko
sum_after="$(sha256sum "$PREFIX/bin/tide-island-config-app" | cut -d' ' -f1)"
t "no-op run leaves the hardened launcher unchanged"
[[ "$sum_before" == "$sum_after" ]] && ok || ko

t "a config loosened after migration is re-tightened"
chmod 0644 "$CFG"
bash "$MIGRATE" --auto >/dev/null 2>&1 || true
[[ "$(mode_of "$CFG")" == 600 ]] && ok || ko

# ---------------------------------------------------------- symlink safety
sdir="$tmp/symcfg/tide-island"
mkdir -p "$sdir"
starget="$tmp/sym-target.json"
printf '{"tlpSudoPassword":"hunter2"}\n' >"$starget"
chmod 0644 "$starget"
ln -s "$starget" "$sdir/userconfig.json"
chmod 0755 "$sdir"
rc=0
XDG_CONFIG_HOME="$tmp/symcfg" bash "$MIGRATE" --auto >/dev/null 2>&1 || rc=$?
t "refuses a symlinked userconfig, leaves the target untouched, and reports it"
[[ "$(mode_of "$starget")" == 644 ]] && [[ -L "$sdir/userconfig.json" ]] \
  && [[ $rc -ne 0 ]] && ok || ko

# --------------------------------------------- user-modified runtime preserved
# A runtime the user edited must not be clobbered; the migration reports the
# failure (so it retries) but still repairs the config.
rm -f "$STATE/migrate.sha256"
printf '// user edit\n' >>"$PREFIX/bin/tide-island"
chmod 0644 "$CFG"
rc=0
bash "$MIGRATE" --auto >/dev/null 2>&1 || rc=$?
t "refuses to clobber a user-modified runtime"
[[ $rc -ne 0 ]] && grep -q '// user edit' "$PREFIX/bin/tide-island" && ok || ko
t "still repairs the config when the runtime is left untouched"
[[ "$(mode_of "$CFG")" == 600 ]] && ok || ko

echo
printf 'migrate: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
