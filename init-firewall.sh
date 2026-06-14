#!/bin/bash
set -euo pipefail
IFS=$' \n\t'

# Preserve Docker's embedded DNS NAT rules before flushing tables.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep '127\.0\.0\.11' || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Reset policies while constructing the ruleset. The final state is DROP.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

if [ -n "$DOCKER_DNS_RULES" ]; then
  echo "Restoring Docker DNS rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
  echo "No Docker DNS rules to restore"
fi

iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -m state --state ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -m state --state ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s --max-time 20 https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
  echo "ERROR: Failed to fetch GitHub IP ranges" >&2
  exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
  echo "ERROR: GitHub API response missing required fields" >&2
  exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
  if [[ ! "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: Invalid CIDR range from GitHub meta: $cidr" >&2
    exit 1
  fi
  echo "Adding GitHub range $cidr"
  ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

resolve_and_add() {
  local domain="$1"
  local mode="$2"
  local ips ip

  echo "Resolving $domain ($mode)..."
  ips=$(dig +short A "$domain" | awk '/^[0-9.]+$/ {print}')
  if [ -z "$ips" ]; then
    if [ "$mode" = "required" ]; then
      echo "ERROR: Failed to resolve required domain $domain" >&2
      exit 1
    fi
    echo "WARNING: Failed to resolve optional domain $domain, skipping" >&2
    return 0
  fi

  while read -r ip; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "ERROR: Invalid IP from DNS for $domain: $ip" >&2
      exit 1
    fi
    echo "Adding $ip for $domain"
    ipset add -exist allowed-domains "$ip"
  done < <(echo "$ips")
}

if [ -n "${CODEX_REQUIRED_DOMAINS:-}" ]; then
  read -r -a REQUIRED_DOMAINS <<< "$CODEX_REQUIRED_DOMAINS"
else
  REQUIRED_DOMAINS=(
    api.openai.com
    api.chatgpt.com
    auth.openai.com
    chatgpt.com
    github.com
    raw.githubusercontent.com
    registry.npmjs.org
    npmjs.com
    npmjs.org
    nodejs.org
    crates.io
    static.crates.io
    index.crates.io
    rustup.rs
  )
fi

if [ -n "${CODEX_OPTIONAL_DOMAINS:-}" ]; then
  read -r -a OPTIONAL_DOMAINS <<< "$CODEX_OPTIONAL_DOMAINS"
else
  OPTIONAL_DOMAINS=(
    sentry.io
    statsig.com
  )
fi

for domain in "${REQUIRED_DOMAINS[@]}"; do
  resolve_and_add "$domain" required
done

for domain in "${OPTIONAL_DOMAINS[@]}"; do
  resolve_and_add "$domain" optional
done

if [ "${CODEX_ALLOW_HOST_NETWORK:-1}" = "1" ]; then
  HOST_IP=$(ip route | awk '/default/ {print $3; exit}')
  if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP" >&2
    exit 1
  fi
  HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
  echo "Host network detected as: $HOST_NETWORK"
  iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
  iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."

if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - reached https://example.com" >&2
  exit 1
fi
echo "Firewall verification passed - https://example.com is blocked"

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - unable to reach https://api.github.com" >&2
  exit 1
fi
echo "Firewall verification passed - https://api.github.com is reachable"

if ! curl --connect-timeout 5 https://api.openai.com/v1/models >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - unable to reach https://api.openai.com" >&2
  exit 1
fi
echo "Firewall verification passed - https://api.openai.com is reachable"
