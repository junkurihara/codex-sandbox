#!/bin/sh
set -eu

sudo /usr/local/bin/init-firewall.sh

codex_home="${CODEX_HOME:-"$HOME/.codex"}"
mkdir -p "$codex_home"

if [ ! -e "$codex_home/AGENTS.md" ]; then
  cp /usr/local/share/codex-sandbox/sandbox-AGENTS.md "$codex_home/AGENTS.md"
fi

if [ ! -e "$codex_home/config.toml" ]; then
  cp /usr/local/share/codex-sandbox/sandbox-config.toml "$codex_home/config.toml"
fi

mkdir -p "$codex_home/rules"
if [ ! -e "$codex_home/rules/default.rules" ]; then
  cp /usr/local/share/codex-sandbox/rules/default.rules "$codex_home/rules/default.rules"
fi

mkdir -p /commandhistory
touch "${HISTFILE:-/commandhistory/.zsh_history}"

exec sleep infinity
