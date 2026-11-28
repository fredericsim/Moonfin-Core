#!/usr/bin/env bash
set -euo pipefail

# NAS deployment belongs to Fredflix; do not maintain a second deployer here.
cat >&2 <<'EOF'
This deployer is retired. No deployment was performed.
Use the tracked Fredflix deployment wrapper on the NAS:

  cd /volume1/docker/fredflix
  ./deploy-nas.sh

For validation without replacing the frontend, use ./deploy-nas.sh --dry-run.
See the Fredflix README and the homelab Jellyfin runbook for host configuration.
EOF
exit 1
