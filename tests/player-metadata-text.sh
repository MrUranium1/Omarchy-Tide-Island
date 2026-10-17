#!/usr/bin/env bash
# Security tests for MPRIS media-metadata rendering:
#   * a malicious player controls the track title/artist it advertises, so any
#     Text that renders them must force textFormat: Text.PlainText (Qt Quick's
#     default Text.AutoText parses inline HTML and can fetch a remote image
#     from markup such as <img src="http://evil/">); and
#   * the automatic expansion that fires when the track changes opens the same
#     hardened expanded-player layer.
#
# Two layers of checking:
#   * static wiring - every Text rendering a title/artist/lyric forces
#     PlainText (so a regression to AutoText fails even with no Qt present);
#   * behavioral - in a real Qt QML engine, PlainText is compared against the
#     vulnerable AutoText default over the attack inputs to prove markup is
#     shown literally instead of parsed.
# Run from anywhere: bash tests/player-metadata-text.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
QML="$ROOT/vendor/tide-island/share/tide-island/qml/island"
ISLAND_QML="$ROOT/vendor/tide-island/share/tide-island/DynamicIslandWindow.qml"

pass=0
fail=0
t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Tide Island player metadata security tests"

# ------------------------------------------------------------ static wiring
# Any Text block matching the anchor regex must declare Text.PlainText.
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

echo "  player panel, media strip and custom-track Text force plain text"
for spec in \
  "ExpandedPlayerLayer.qml:text: currentTrack|text: currentArtist" \
  "SwipeLyricsLayer.qml:text: root.previousLyricText|text: root.activeLyricText" \
  "SwipeCustomInfoLayer.qml:text: modelData.text"; do
  file="$QML/${spec%%:*}"
  anchor="${spec#*:}"
  rc=0
  require_text_plain "$file" "$anchor" || rc=$?
  case $rc in
    0) t "$(basename "$file"): title/artist Text forces Text.PlainText" && ok ;;
    2) t "$(basename "$file"): no title/artist Text found - anchor missing" && ko ;;
    *) t "$(basename "$file"): title/artist Text renders without Text.PlainText" && ko ;;
  esac
done

# Track-change auto-expansion must open the hardened expanded player.
echo "  track-change auto-expansion opens the hardened player"
change_block="$tmp/change-block.txt"
awk '
  index($0, "onCurrentTrackChanged:") { infn = 1 }
  infn {
    print
    line = $0
    depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    if (depth > 0) seen = 1
    if (seen && depth == 0) exit
  }
' "$ISLAND_QML" >"$change_block"
if grep -q 'showExpandedPlayer(true)' "$change_block"; then
  t "onCurrentTrackChanged auto-expands via showExpandedPlayer(true)" && ok
else
  t "onCurrentTrackChanged does not route to showExpandedPlayer(true)" && ko
fi
grep -q 'disableAutoExpandOnTrackChange' "$change_block" \
  && t "track-change auto-expansion still honours the user opt-out" && ok \
  || { t "track-change auto-expansion dropped the user opt-out" && ko; }

# ------------------------------------------------- dynamic behavioral checks
# Prove, in the real Qt QML engine, that PlainText shows markup literally while
# the vulnerable AutoText default parses it. Only Qt can do this.
qt_bin=""
if command -v qml >/dev/null 2>&1; then
  qt_bin="$(command -v qml)"
elif [[ -x /usr/lib/qt6/bin/qml ]]; then
  qt_bin=/usr/lib/qt6/bin/qml
fi
engine="${PLAYER_TEXT_ENGINE:-qml}"

echo "  Text.PlainText neutralizes injected markup in a Qt engine"
if [[ -z "$qt_bin" || "$engine" != "qml" ]]; then
  t "no Qt qml engine found; behavioral checks skipped" && ok
else
  cat >"$tmp/harness.qml" <<'QML'
import QtQuick
Item {
  id: root

  function widthFor(format, s) {
    var item = Qt.createQmlObject('import QtQuick; Text { font.pixelSize: 16 }', root);
    item.textFormat = format;
    item.text = s;
    var w = item.contentWidth;
    item.destroy();
    return w;
  }

  function report(name, pass, detail) {
    console.log("RD\t" + (pass ? "PASS" : "FAIL") + "\t" + name + "\t" + detail);
  }

  function runChecks() {
    // Inputs that must never be parsed as rich text.
    var markup = [
      ["literal image tag with malicious src", '<img src="http://evil.example/x.png">'],
      ["literal script tag", "<script>alert(1)</script>tail"],
      ["literal bold tag", "<b>Bold</b>tail"],
      ["encoded image tag", "&lt;img src=x onerror=alert(1)&gt;"],
      ["decimal-encoded delimiters", "&#60;img src=http://evil.example/x.png&#62;"],
      ["hex-encoded delimiters", "&#x3C;img src=x&#x3E;"]
    ];
    var plain = [
      ["ordinary title", "Midnight City"],
      ["artist with ampersand", "M83 & Friends"],
      ["unicode title", "Caf\u00e9 \u2615 42"]
    ];
    var i;
    for (i = 0; i < markup.length; i++) {
      var sp = widthFor(Text.PlainText, markup[i][1]);
      var sa = widthFor(Text.AutoText, markup[i][1]);
      report(markup[i][0] + " is not consumed under PlainText",
        sp > 0 && sp + 0.5 >= sa,
        "plain=" + sp.toFixed(1) + " auto=" + sa.toFixed(1));
    }
    // The literal image tag is the exact historical vector: AutoText parses it
    // (and would fetch the URL), PlainText does not.
    var litPlain = widthFor(Text.PlainText, markup[0][1]);
    var litAuto = widthFor(Text.AutoText, markup[0][1]);
    report("AutoText parses a literal image tag (the vulnerability)",
      litAuto + 1 < litPlain,
      "plain=" + litPlain.toFixed(1) + " auto=" + litAuto.toFixed(1));
    for (i = 0; i < plain.length; i++) {
      var p = widthFor(Text.PlainText, plain[i][1]);
      var a = widthFor(Text.AutoText, plain[i][1]);
      report(plain[i][0] + " identical under PlainText and AutoText",
        p > 0 && Math.abs(p - a) < 0.5,
        "plain=" + p.toFixed(1) + " auto=" + a.toFixed(1));
    }
  }

  Component.onCompleted: { runChecks(); Qt.quit(); }
}
QML
  harness_rc=0
  out="$(QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen timeout 30 \
    "$qt_bin" -f "$tmp/harness.qml" 2>&1 | sed 's/^qml: //')" || harness_rc=$?
  if [[ $harness_rc -ne 0 ]]; then
    t "the Qt engine exited $harness_rc" && ko
  else
    rd_count=0
    while IFS=$'\t' read -r tag status name detail; do
      [[ "$tag" == "RD" ]] || continue
      rd_count=$((rd_count + 1))
      if [[ "$status" == "PASS" ]]; then
        t "$name" && ok
      else
        t "$name ($detail)" && ko
      fi
    done <<<"$out"
    [[ $rd_count -eq 10 ]] \
      && t "all 10 behavioral cases ran" && ok \
      || { t "expected 10 behavioral cases, saw $rd_count" && ko; }
  fi
fi

echo "player-metadata-text: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
