#!/usr/bin/env bash
# Advertise COUNT "nvidia.com/gpu" on NODE by patching the node's status, as the Kubernetes docs
# show for any extended resource. No GPU is involved: the scheduler only counts the number.
# Usage: scripts/advertise-gpu.sh <node> <count>
set -euo pipefail
NODE="${1:?node name}"; COUNT="${2:?count}"
PORT="${PORT:-8001}"

kubectl proxy --port="$PORT" >/dev/null 2>&1 &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -s "http://localhost:${PORT}/api" >/dev/null && break; sleep 0.5; done

# "~1" encodes "/" inside a JSON-Patch path, so this path means .../capacity/nvidia.com/gpu
curl --silent --show-error --fail \
  --header "Content-Type: application/json-patch+json" \
  --request PATCH \
  --data "[{\"op\": \"add\", \"path\": \"/status/capacity/nvidia.com~1gpu\", \"value\": \"${COUNT}\"}]" \
  "http://localhost:${PORT}/api/v1/nodes/${NODE}/status" >/dev/null

echo "Advertised nvidia.com/gpu=${COUNT} on ${NODE}"
