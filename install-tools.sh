#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root, e.g.: docker exec -u 0 <container> install-tools <pkg>..." >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: install-tools <package>..." >&2
  exit 1
fi

APT_MIRRORS=(archive.ubuntu.com security.ubuntu.com ports.ubuntu.com)
FIREWALL_ACTIVE=0
if ipset list allowed-domains >/dev/null 2>&1; then
  FIREWALL_ACTIVE=1
fi

add_mirrors() {
  local domain ip ips
  for domain in "${APT_MIRRORS[@]}"; do
    ips=$(dig +short A "$domain" | awk '/^[0-9.]+$/ {print}')
    for ip in $ips; do
      if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        ipset add -exist allowed-domains "$ip"
      fi
    done
  done
}

relock() {
  if [ "$FIREWALL_ACTIVE" -eq 1 ]; then
    echo "Restoring firewall..."
    /usr/local/bin/init-firewall.sh
  fi
}
trap relock EXIT

if [ "$FIREWALL_ACTIVE" -eq 1 ]; then
  echo "Temporarily allowing apt mirrors through the firewall..."
  add_mirrors
fi

attempt=1
max_attempts=3
until apt-get update && apt-get install -y --no-install-recommends "$@"; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "ERROR: apt failed after ${max_attempts} attempts" >&2
    exit 1
  fi
  echo "apt attempt ${attempt} failed; re-resolving mirrors and retrying..."
  if [ "$FIREWALL_ACTIVE" -eq 1 ]; then
    add_mirrors
  fi
  attempt=$((attempt + 1))
done

echo "Installed: $*"
echo "Firewall will be restored on exit."
