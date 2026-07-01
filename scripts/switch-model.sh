#!/usr/bin/env bash
# switch-model.sh - Model switcher wrapper for LXD container
# This runs on the host and delegates to the real script inside the container
set -euo pipefail

CT_NAME="plh-ai-engine"
CT_PROJECT="prod"

# Check if container is running
if ! lxc info "$CT_NAME" --project "$CT_PROJECT" >/dev/null 2>&1; then
  echo "❌ Container '$CT_NAME' in project '$CT_PROJECT' is not running"
  echo "   Start it with: lxc start $CT_NAME --project $CT_PROJECT"
  exit 1
fi

# Run the real switch-model.sh inside the container
lxc exec "$CT_NAME" --project "$CT_PROJECT" -- /usr/local/bin/switch-model.sh "$@"
