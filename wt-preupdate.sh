#!/bin/sh
set -eu

if pgrep -f '[c]odex' >/dev/null 2>&1; then
  echo "wt-preupdate: Codex is running; postponing update (exit 75)."
  exit 75
fi

echo "wt-preupdate: no Codex process; allowing update (exit 0)."
exit 0
