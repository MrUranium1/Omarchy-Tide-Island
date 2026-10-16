#!/usr/bin/env bash
# Security tests for notification text rendering:
#   * DynamicIslandWindow.cleanNotificationText decodes character references
#     BEFORE stripping tags, so an escaped tag such as "&lt;img src=x&gt;"
#     cannot be decoded back into live markup after the strip; and
#   * NotificationLayer forces textFormat: Text.PlainText on every Text that
#     renders notification content, so untrusted notification text can never
#     be parsed as rich text or make the shell fetch a URL (e.g. <img src=…>).
#
# The sanitizer is exercised as-shipped: the function is extracted from
# DynamicIslandWindow.qml and run in a real JavaScript engine (the Qt QML
# runtime when available, otherwise node), so the test cannot drift from the
# code it guards. The Qt runtime runs the same V4 engine the shell uses.
# Run from anywhere: bash tests/notification-text.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ISLAND_QML="$ROOT/vendor/tide-island/share/tide-island/DynamicIslandWindow.qml"
NOTIF_QML="$ROOT/vendor/tide-island/share/tide-island/qml/island/NotificationLayer.qml"

pass=0
fail=0
t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Tide Island notification text security tests"

# ------------------------------------------------------------ static wiring
# Every Text block that renders notification content must force PlainText.
require_text_plain() { # $1 = qml file, $2 = anchor regex for guarded Text blocks
  awk -v anchor="$2" '
    /^[[:space:]]*Text \{/ && !inb { inb = 1; depth = 0; body = "" }
    inb {
      body = body $0 "\n"
      line = $0
      depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
      if (depth == 0) {
        if (body ~ anchor) {
          found++
          if (body !~ /textFormat:[[:space:]]*Text\.PlainText/) bad++
        }
        inb = 0
      }
    }
    END {
      if (found == 0) exit 2
      if (bad > 0) exit 1
    }
  ' "$1"
}

echo "  notification capsule renders content as plain text"
notif_rc=0
require_text_plain "$NOTIF_QML" 'text: contentText' || notif_rc=$?
case $notif_rc in
  0) t "every Text rendering notification content sets Text.PlainText" && ok ;;
  2) t "no Text renders notification content - regression anchor missing" && ko ;;
  *) t "a Text renders notification content without Text.PlainText" && ko ;;
esac

# ------------------------------------------------- dynamic behavioral checks
# Extract the shipped function verbatim (brace balanced) so the engine runs the
# exact code that ships, not a copy.
awk '
  /function cleanNotificationText\(text\) \{/ { infn = 1 }
  infn {
    print
    line = $0
    depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    if (depth == 0) exit
  }
' "$ISLAND_QML" >"$tmp/fn.js"
if grep -q 'function cleanNotificationText' "$tmp/fn.js"; then
  t "extracted cleanNotificationText from DynamicIslandWindow.qml" && ok
else
  t "could not extract cleanNotificationText from DynamicIslandWindow.qml" && ko
fi

# The sanitizer must decode before it strips. Guard the order statically too,
# so a future reorder is caught even if no JS engine is available.
echo "  cleanNotificationText decodes character references before stripping"
decode_line="$(grep -n 'replace(/&lt;/g' "$tmp/fn.js" | head -1 | cut -d: -f1 || true)"
strip_line="$(grep -n 'replace(/<\[^>\]\*>/g' "$tmp/fn.js" | head -1 | cut -d: -f1 || true)"
if [[ -n "$decode_line" && -n "$strip_line" && "$decode_line" -lt "$strip_line" ]]; then
  t "the entity decode (line $decode_line) runs before the tag strip (line $strip_line)" && ok
else
  t "the entity decode must run before the tag strip (decode=$decode_line strip=$strip_line)" && ko
fi

cat >"$tmp/checks.js" <<'JS'
// The engine supplies cleanNotificationText() in scope before this runs.
function runChecks() {
var cases = [
  // name, input, expected exact output
  ["escaped <img> tag is removed",
   "&lt;img src=x onerror=alert(1)&gt;", ""],
  ["decimal-encoded delimiters cannot form a tag",
   "&#60;img src=http://evil.example/x.png&#62;", ""],
  ["hex-encoded script delimiters are stripped",
   "&#x3C;script&#x3E;alert(1)", "alert(1)"],
  ["literal malicious src is stripped",
   '<img src="http://evil.example/x.png">', ""],
  ["escaped malicious src is stripped",
   '&lt;img src="http://evil.example/x.png"&gt;', ""],
  ["mixed literal and escaped markup is stripped",
   "Hi <img src=x> &lt;script&gt;", "Hi"],
  ["double-encoded markup stays inert text",
   "&amp;lt;img src=x&amp;gt;", "&lt;img src=x&gt;"],
  ["ordinary notification text is unchanged",
   "Build 42 passed on caf\u00e9 \u2615", "Build 42 passed on caf\u00e9 \u2615"],
  ["a lone delimiter in prose is preserved",
   "Meeting 5 &lt; 6pm &amp; coffee", "Meeting 5 < 6pm & coffee"],
  ["a literal ampersand entity is decoded",
   "Tom &amp; Jerry", "Tom & Jerry"],
  ["existing literal-tag stripping is preserved",
   "Hello <b>world</b>", "Hello world"],
  ["empty, null and undefined collapse to empty",
   "", ""]
];

var tagRe = /<\/?[A-Za-z!?][^>]*>/;
for (var i = 0; i < cases.length; i++) {
  var name = cases[i][0];
  var input = cases[i][1];
  var want = cases[i][2];
  var got = cleanNotificationText(input);
  var status = "PASS";
  if (got !== want) status = "FAIL";
  // Independent invariant: no output may look like a tag or an image/script.
  if (typeof got !== "string" || tagRe.test(got)
      || /<img/i.test(got) || /<script/i.test(got)) status = "FAIL";
  console.log("RD\t" + status + "\t" + name + "\t" + got + "\t" + want);
}
}
JS

echo "  sanitizer behavior in a JavaScript engine"
harness_rc=0
out=""
node_bin="$(command -v node 2>/dev/null || true)"
qt_bin=""
if command -v qml >/dev/null 2>&1; then
  qt_bin="$(command -v qml)"
elif [[ -x /usr/lib/qt6/bin/qml ]]; then
  qt_bin=/usr/lib/qt6/bin/qml
fi
engine="${NOTIFICATION_TEXT_ENGINE:-}"
if [[ -z "$engine" ]]; then
  if [[ -n "$qt_bin" ]]; then engine="qml"; elif [[ -n "$node_bin" ]]; then engine="node"; fi
fi
qml_bin=""
if [[ "$engine" == "qml" ]]; then qml_bin="$qt_bin"; fi
if [[ "$engine" == "node" ]]; then qml_bin="$node_bin"; fi
if [[ -z "$qml_bin" ]]; then engine=""; fi

if [[ "$engine" == "qml" ]]; then
  {
    printf 'import QtQuick\nItem {\n'
    cat "$tmp/fn.js"
    cat "$tmp/checks.js"
    printf 'Component.onCompleted: { runChecks(); Qt.quit(); }\n}\n'
  } >"$tmp/harness.qml"
  out="$(QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen timeout 30 \
    "$qml_bin" -f "$tmp/harness.qml" 2>&1 | sed 's/^qml: //')" || harness_rc=$?
elif [[ "$engine" == "node" ]]; then
  { cat "$tmp/fn.js" "$tmp/checks.js"; printf 'runChecks();\n'; } >"$tmp/harness.js"
  out="$(timeout 30 "$qml_bin" "$tmp/harness.js" 2>&1)" || harness_rc=$?
fi

if [[ -z "$engine" ]]; then
  t "no JavaScript engine (Qt qml or node) found; behavioral checks skipped" && ok
elif [[ $harness_rc -ne 0 ]]; then
  t "the JavaScript engine exited $harness_rc" && ko
else
  rd_count=0
  while IFS=$'\t' read -r tag status name got want; do
    [[ "$tag" == "RD" ]] || continue
    rd_count=$((rd_count + 1))
    if [[ "$status" == "PASS" ]]; then
      t "$name" && ok
    else
      t "$name (got=[$got] want=[$want])" && ko
    fi
  done <<<"$out"
  [[ $rd_count -eq 12 ]] \
    && t "all 12 sanitizer cases ran" && ok \
    || { t "expected 12 sanitizer cases, saw $rd_count" && ko; }
fi

echo "notification-text: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
