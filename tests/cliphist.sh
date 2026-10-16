#!/usr/bin/env bash
# Privacy tests for the clipboard panel's cliphist-helper.sh:
#   * an inherited umask of 022 must still yield a 0700 image directory and
#     0600 decoded PNGs;
#   * a pre-existing world-readable cache (written by older versions) is
#     repaired before any image is decoded into it;
#   * XDG_CACHE_HOME resolution (unset, empty, relative, unusable);
#   * the panel's list/copy/delete/wipe/watch contracts keep working.
# cliphist and wl-clipboard are faked, so no Wayland session is needed.
# Run from anywhere: bash tests/cliphist.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$ROOT/vendor/tide-island/share/tide-island/scripts/cliphist-helper.sh"
pass=0
fail=0

t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mode_of() { stat -c '%a' "$1" 2>/dev/null || printf 'missing'; }

echo "cliphist-helper.sh clipboard cache privacy tests"

echo "  syntax"
bash -n "$HELPER" && t "cliphist-helper.sh parses" && ok || ko

# --------------------------------------------------------------- fake tools
FAKEBIN="$tmp/fakebin"
mkdir -p "$FAKEBIN" "$tmp/cwd"
TEST_CWD="$tmp/cwd"

cat >"$FAKEBIN/cliphist" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    list)
        printf '101\t[[ binary data 14 bytes image/png 64x48 ]]\n'
        printf '102\thello world\n'
        ;;
    decode)
        # Record the image directory's mode at decode time: the helper must
        # repair a permissive cache before any clipboard image lands in it.
        if [[ -n ${XDG_CACHE_HOME:-} && -d ${XDG_CACHE_HOME}/tide-island/cliphist-imgs ]]; then
            printf 'decode-saw-dir-mode=%s\n' \
                "$(stat -c '%a' "${XDG_CACHE_HOME}/tide-island/cliphist-imgs")" \
                >>"${CLIPHIST_LOG:?}"
        fi
        printf 'PNG-PAYLOAD-%s\n' "${2:-}"
        ;;
    delete)
        cat >/dev/null || true
        ;;
    wipe) ;;
esac
EOS

cat >"$FAKEBIN/wl-paste" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == "--watch" ]]; then
    printf '%s\n' "$*" >>"${WL_LOG:?}"
fi
exit 0
EOS

cat >"$FAKEBIN/wl-copy" <<'EOS'
#!/usr/bin/env bash
cat >"${WLCOPY_OUT:?}"
EOS
chmod +x "$FAKEBIN/"*

# Invoke the helper exactly the way the panel does ("bash <helper> <action>"),
# as a child shell that inherits a common desktop umask of 022 and a scrubbed
# environment. $1 = HOME or "-"; $2 = XDG_CACHE_HOME or "-"; rest = arguments.
run_helper() {
    local home="$1" xdg="$2"
    shift 2
    local rc=0
    local -a envargs=(
        "PATH=$FAKEBIN:/usr/bin:/bin"
        "CLIPHIST_LOG=$tmp/cliphist.log"
        "WLCOPY_OUT=$tmp/wlcopy.out"
        "WL_LOG=$tmp/wl.log"
    )
    [[ "$home" == "-" ]] || envargs+=("HOME=$home")
    [[ "$xdg" == "-" ]] || envargs+=("XDG_CACHE_HOME=$xdg")
    : >"$tmp/cliphist.log"
    : >"$tmp/wlcopy.out"
    : >"$tmp/wl.log"
    (
        umask 022
        cd "$TEST_CWD" || exit 99
        env -i "${envargs[@]}" bash "$HELPER" "$@" >"$tmp/out" 2>"$tmp/err"
    ) || rc=$?
    return "$rc"
}

# The panel contract for a two-entry history: the image row carries the
# \0icon\x1f<path> marker ClipboardLayer.qml parses for its preview.
expect_list_output() {
    {
        printf '%s\t%s\000icon\x1f%s\n' 101 '[[ binary data 14 bytes image/png 64x48 ]]' "$1"
        printf '%s\t%s\n' 102 'hello world'
    } >"$tmp/expected"
    cmp -s "$tmp/expected" "$tmp/out"
}

# ------------------------------------------- fresh cache, inherited umask 022
echo "  fresh cache under an inherited umask of 022"
h1="$tmp/home1"; xdg1="$tmp/xdg1"; mkdir -p "$h1"
rc=0; run_helper "$h1" "$xdg1" list 200 || rc=$?
t "list exits 0 under umask 022"
[[ $rc -eq 0 ]] && ok || ko
d1="$xdg1/tide-island/cliphist-imgs"
t "image directory created under XDG_CACHE_HOME"
[[ -d "$d1" ]] && ok || ko
t "image directory is 0700 despite the inherited umask of 022"
[[ "$(mode_of "$d1")" == 700 ]] && ok || ko
t "binary entry decoded to a PNG"
[[ -f "$d1/101.png" ]] && ok || ko
t "decoded PNG is 0600 despite the inherited umask of 022"
[[ "$(mode_of "$d1/101.png")" == 600 ]] && ok || ko
t "decoded PNG keeps its payload (previews have something to render)"
[[ "$(cat "$d1/101.png")" == "PNG-PAYLOAD-101" ]] && ok || ko
t "list output matches the icon contract ClipboardLayer.qml parses"
expect_list_output "$d1/101.png" && ok || ko
t "directory is already private at the moment of decoding"
grep -q '^decode-saw-dir-mode=700$' "$tmp/cliphist.log" && ok || ko

# ---------------------------------- pre-existing permissive cache (old build)
echo "  pre-existing world-readable cache is repaired, data preserved"
h2="$tmp/home2"; xdg2="$tmp/xdg2"
d2="$xdg2/tide-island/cliphist-imgs"
mkdir -p "$d2"
chmod 0755 "$xdg2" "$xdg2/tide-island" "$d2"
printf 'LEGACY' >"$d2/101.png"; chmod 0644 "$d2/101.png"
printf 'LEGACY-OTHER' >"$d2/777.png"; chmod 0644 "$d2/777.png"
rc=0; run_helper "$h2" "$xdg2" list 200 || rc=$?
t "list still answers against a pre-existing cache"
[[ $rc -eq 0 ]] && ok || ko
t "pre-existing 0755 image directory repaired to 0700"
[[ "$(mode_of "$d2")" == 700 ]] && ok || ko
t "pre-existing world-readable image tightened to 0600"
[[ "$(mode_of "$d2/101.png")" == 600 ]] && ok || ko
t "cached image outside this listing page tightened to 0600 as well"
[[ "$(mode_of "$d2/777.png")" == 600 ]] && ok || ko
t "existing image data preserved (not deleted, not re-decoded)"
[[ "$(cat "$d2/101.png")" == "LEGACY" ]] && ok || ko
t "preview path still resolves for the repaired cache"
expect_list_output "$d2/101.png" && ok || ko
t "unrelated parent directories are left untouched"
[[ "$(mode_of "$xdg2")" == 755 && "$(mode_of "$xdg2/tide-island")" == 755 ]] && ok || ko

# ------------------- per-existing permissive directory + first-time decode
echo "  a permissive directory is repaired before the first decode"
h3="$tmp/home3"; xdg3="$tmp/xdg3"
d3="$xdg3/tide-island/cliphist-imgs"
mkdir -p "$d3"
chmod 0755 "$xdg3/tide-island" "$d3"
rc=0; run_helper "$h3" "$xdg3" list 200 || rc=$?
t "list exits 0 against a freshly repaired directory"
[[ $rc -eq 0 ]] && ok || ko
t "decode ran only after the directory became 0700 (no exposure window)"
grep -q '^decode-saw-dir-mode=700$' "$tmp/cliphist.log" && ok || ko
t "new image in the repaired directory is 0600"
[[ "$(mode_of "$d3/101.png")" == 600 ]] && ok || ko

# ------------------------------------------------- XDG_CACHE_HOME resolution
echo "  XDG_CACHE_HOME resolution"
h4="$tmp/home4"; mkdir -p "$h4"
rc=0; run_helper "$h4" "-" list || rc=$?
d4="$h4/.cache/tide-island/cliphist-imgs"
t "unset XDG_CACHE_HOME falls back to \$HOME/.cache"
[[ $rc -eq 0 && -f "$d4/101.png" ]] && ok || ko
t "fallback cache directory is 0700 with 0600 images"
[[ "$(mode_of "$d4")" == 700 && "$(mode_of "$d4/101.png")" == 600 ]] && ok || ko

h5="$tmp/home5"; mkdir -p "$h5"
rc=0; run_helper "$h5" "" list || rc=$?
t "empty XDG_CACHE_HOME is treated as unset (\$HOME/.cache, 0700)"
[[ $rc -eq 0 && -f "$h5/.cache/tide-island/cliphist-imgs/101.png" \
   && "$(mode_of "$h5/.cache/tide-island/cliphist-imgs")" == 700 ]] && ok || ko

h6="$tmp/home6"; mkdir -p "$h6"
rc=0; run_helper "$h6" "relcache" list || rc=$?
t "relative XDG_CACHE_HOME is ignored, nothing written into the working directory"
[[ $rc -eq 0 && ! -e "$TEST_CWD/relcache" ]] && ok || ko
t "relative XDG_CACHE_HOME falls back to \$HOME/.cache"
[[ -f "$h6/.cache/tide-island/cliphist-imgs/101.png" ]] && ok || ko

rc=0; run_helper "-" "-" list || rc=$?
t "unresolvable cache root exits nonzero"
[[ $rc -ne 0 ]] && ok || ko
t "unresolvable cache root emits no listing (fail closed)"
[[ ! -s "$tmp/out" ]] && ok || ko
t "unresolvable cache root explains itself on stderr"
grep -q 'HOME' "$tmp/err" && ok || ko

# ------------------------------------------------- secure creation failures
echo "  secure creation failures"
h7="$tmp/home7"; xdg7="$tmp/xdg7"
mkdir -p "$xdg7/tide-island"
: >"$xdg7/tide-island/cliphist-imgs"
rc=0; run_helper "$h7" "$xdg7" list || rc=$?
t "aborts when the cache path cannot be created"
[[ $rc -ne 0 ]] && ok || ko
t "decodes nothing when the cache path cannot be created"
[[ ! -s "$tmp/out" ]] && ok || ko
t "reports the creation failure on stderr"
grep -q 'mkdir' "$tmp/err" && ok || ko
t "no image file appears next to the blocking path"
! ls "$xdg7/tide-island/"*.png >/dev/null 2>&1 && ok || ko

h8="$tmp/home8"; xdg8="$tmp/xdg8"
mkdir -p "$xdg8/tide-island/cliphist-imgs"
chmod 0755 "$xdg8/tide-island/cliphist-imgs"
FB_BAD="$tmp/fakebin-badchmod"
cp -a "$FAKEBIN" "$FB_BAD"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FB_BAD/chmod"
chmod +x "$FB_BAD/chmod"
FAKEBIN="$FB_BAD"
rc=0; run_helper "$h8" "$xdg8" list || rc=$?
FAKEBIN="$tmp/fakebin"
t "aborts when the directory cannot be made private"
[[ $rc -ne 0 ]] && ok || ko
t "never decodes an image when permissions cannot be enforced"
[[ ! -s "$tmp/out" && ! -f "$xdg8/tide-island/cliphist-imgs/101.png" ]] && ok || ko

# ------------------------------------------------ panel behaviour preserved
echo "  clipboard panel behaviour preserved"
h9="$tmp/home9"; xdg9="$tmp/xdg9"
rc=0; run_helper "$h9" "$xdg9" count || rc=$?
t "count still reports the history length"
[[ $rc -eq 0 && "$(cat "$tmp/out")" == "2" ]] && ok || ko

rc=0; run_helper "$h9" "$xdg9" copy 101 || rc=$?
t "copy still pipes the decoded image to wl-copy"
[[ $rc -eq 0 && "$(cat "$tmp/wlcopy.out")" == "PNG-PAYLOAD-101" ]] && ok || ko

d9="$xdg9/tide-island/cliphist-imgs"
[[ -f "$d9/101.png" ]] || { run_helper "$h9" "$xdg9" list 200 || true; }
run_helper "$h9" "$xdg9" delete 101 true || true
t "delete still removes the cached image"
[[ ! -f "$d9/101.png" ]] && ok || ko
t "delete leaves the private directory in place"
[[ "$(mode_of "$d9")" == 700 ]] && ok || ko

run_helper "$h9" "$xdg9" list 200 || true
run_helper "$h9" "$xdg9" wipe || true
t "wipe still empties the cache without removing the directory"
[[ ! -e "$d9/101.png" && -d "$d9" ]] && ok || ko
t "directory stays 0700 after wipe"
[[ "$(mode_of "$d9")" == 700 ]] && ok || ko

h10="$tmp/home10"; xdg10="$tmp/xdg10"
rc=0; run_helper "$h10" "$xdg10" watch || rc=$?
t "watch still starts (exits 0 after handing off to the watcher)"
[[ $rc -eq 0 ]] && ok || ko
t "watch execs wl-paste --watch cliphist store"
grep -q -- '--watch cliphist store' "$tmp/wl.log" && ok || ko
t "lock fallback in the cache directory is private (0600)"
[[ "$(mode_of "$xdg10/tide-island/cliphist-imgs/tide-island-clipboard.lock")" == 600 ]] \
    && ok || ko

echo
echo "cliphist: $pass passed, $fail failed"
(( fail == 0 ))
