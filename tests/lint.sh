#!/usr/bin/env bash
# tests/lint.sh — static checks for the whole tree, seconds, no stage.
#   Qt 6 qmllint on every QML file (NOT /usr/bin/qmllint, which is Qt 5's 1.0 and fails on Qt 6 files),
#   node --check on every .js (with the .pragma line stripped), Lua 5.5 syntax on every .lua.
# Clean = qmllint exit 0 on every file and no warning outside the two kinds today's code already has
# ([unqualified] from delegates without "pragma ComponentBehavior: Bound", [missing-property] on
# Loader items); anything else (syntax, import, type, missing-type, ...) fails.
set -uo pipefail
cd "$(dirname "$0")/.."
QMLLINT=/usr/lib/qt6/bin/qmllint
for b in "$QMLLINT" node lua git; do command -v "$b" >/dev/null || { echo "lint: missing $b"; exit 2; }; done
fail=0
for f in $(git ls-files -co --exclude-standard '*.qml'); do
  out="$("$QMLLINT" "$f" 2>&1)"; rc=$?
  n=$(printf '%s\n' "$out" | grep -c '^Warning:')
  bad=$(printf '%s\n' "$out" | grep -E '^(Warning|Error):' | grep -vE '\[(unqualified|missing-property)\]$')
  printf '%-34s rc=%s warnings=%s\n' "$f" "$rc" "$n"
  if [ "$rc" -ne 0 ] || [ -n "$bad" ]; then fail=1; printf '%s\n' "$bad" "$out" | head -20; fi
done
for f in $(git ls-files -co --exclude-standard '*.js'); do
  tmp="$(mktemp --suffix=.js)"; grep -v '^\.pragma' "$f" >"$tmp"
  if node --check "$tmp" 2>/dev/null; then printf '%-34s ok\n' "$f"; else echo "$f: js syntax error"; node --check "$tmp"; fail=1; fi
  rm -f "$tmp"
done
for f in $(git ls-files -co --exclude-standard '*.lua'); do
  if lua -e "assert(loadfile('$f'))" 2>/dev/null; then printf '%-34s ok (lua %s)\n' "$f" "$(lua -v 2>&1 | awk '{print $2}')"; else echo "$f: lua syntax error"; lua -e "assert(loadfile('$f'))"; fail=1; fi
done
[ "$fail" = 0 ] && echo "lint: clean" || echo "lint: FAILED"
exit "$fail"
