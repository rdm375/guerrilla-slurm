#!/usr/bin/env bash
set -euo pipefail

if ! command -v avahi-browse >/dev/null 2>&1; then
  echo "Install avahi-utils to discover Guerrilla Cluster nodes." >&2
  exit 1
fi

echo "Discovering nodes on the local link for 5 seconds..."
timeout 5 avahi-browse --resolve --terminate --parsable _guerrilla-node._tcp || status=$?
if [[ ${status:-0} -ne 0 && ${status:-0} -ne 124 ]]; then
  exit "$status"
fi
