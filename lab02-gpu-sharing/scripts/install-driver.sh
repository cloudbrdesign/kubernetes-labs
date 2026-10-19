#!/usr/bin/env bash
# Installs (or reinstalls) the Kubernetes project's example DRA driver: ONE mock GPU per worker node.
#   scripts/install-driver.sh          # one GPU, one claim at a time (steps 1-5)
#   scripts/install-driver.sh slices   # the same GPU, but several claims may take slices of it (step 6)
# Needs: helm v3. The chart and image come from registry.k8s.io (the image is about 60 MB; on a slow
# connection the first download can take several minutes, hence the long timeout).
set -euo pipefail
CHART=oci://registry.k8s.io/dra-example-driver/charts/dra-example-driver
CHART_VERSION=0.5.0
EXTRA=()
if [ "${1:-}" = "slices" ]; then EXTRA=(--set gpuAllowMultipleAllocations=true); fi
helm upgrade -i dra-example-driver "$CHART" --version "$CHART_VERSION" \
  --namespace dra-example-driver --create-namespace \
  --set kubeletPlugin.numDevices=1 ${EXTRA[@]+"${EXTRA[@]}"} --wait --timeout 15m
# Wait until the driver pod on the worker has rolled out (also after a reinstall).
kubectl -n dra-example-driver rollout status daemonset/dra-example-driver-kubeletplugin --timeout=10m
