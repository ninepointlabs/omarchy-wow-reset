#!/bin/bash
# Bar chip clicks and the panel's settings, in a real Quickshell.
# Usage: tests/panel.test.sh
#
# Loads BarWidget.qml -> Panel.qml -> Service.qml from a scratch copy of this
# checkout with the installed shell's Ui/ and Commons/, through the harness in
# tests/qml/PanelHarness.qml. Writes to shell.json are recorded by the harness,
# never made. HOME is a scratch directory and the run is in a network namespace
# (unshare -Urn), so the helper cannot reach an API or touch real state.
#
# It needs the Wayland session: the panel opens briefly on screen. Clicking on
# the desktop while it runs can dismiss the panel; the harness is written so
# that does not fail a check, but leave the mouse alone to be sure.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_SRC="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

skip() { printf 'skip panel tests (%s)\n' "$1"; exit 0; }
command -v qs >/dev/null || skip "qs not installed"
command -v jq >/dev/null || skip "jq not installed"
[ -d "$SHELL_SRC/Ui" ] && [ -d "$SHELL_SRC/Commons" ] || skip "no Omarchy shell at $SHELL_SRC"
[ -n "${WAYLAND_DISPLAY:-}" ] || skip "no Wayland session"
unshare -Urn true 2>/dev/null || skip "unshare -Urn unavailable; not running the helper with network access"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root" "$work/plugin" "$work/home/.local/state" "$work/home/.cache"

# qs resolves qs.Ui / qs.Commons relative to the config root.
cp -r "$SHELL_SRC/Ui" "$SHELL_SRC/Commons" "$work/root/"
cp "$ROOT/tests/qml/PanelHarness.qml" "$work/root/shell.qml"
cp "$ROOT"/*.qml "$ROOT"/*.js "$ROOT/manifest.json" "$work/plugin/"
cp -r "$ROOT/bin" "$work/plugin/"

HOME="$work/home" XDG_STATE_HOME="$work/home/.local/state" XDG_CACHE_HOME="$work/home/.cache" \
  WOW_PLUGIN="$work/plugin" \
  unshare -Urn timeout 60 qs --no-color -p "$work/root/shell.qml" >"$work/log" 2>&1
rc=$?

line=$(grep -o 'RESULT .*' "$work/log" | tail -1)
if [ -z "$line" ]; then
  printf 'FAIL harness produced no result (qs exit %d). Log tail:\n' "$rc"
  tail -30 "$work/log"
  exit 1
fi

warnings=$(grep -E 'WARN|ERROR' "$work/log" | grep -v 'qt\.qpa\.' | grep -v 'RESULT ')
json=${line#RESULT }
echo "$json" | jq -r '.[] | if .ok then "ok   " + .name else "FAIL " + .name + " -- " + .detail end'
pass=$(echo "$json" | jq '[.[] | select(.ok)] | length')
failn=$(echo "$json" | jq '[.[] | select(.ok | not)] | length')
if [ -n "$warnings" ]; then
  failn=$((failn + 1))
  printf 'FAIL QML warnings:\n%s\n' "$warnings"
fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
