#!/usr/bin/env bash
# Runs every laptop step of Lab 2 in order and saves the evidence to runs/<timestamp>/.
# Read the README first: it explains each step. This script is for a clean, recorded run.
# Needs: docker (Docker Desktop or Colima), kind v0.33.0, kubectl, helm v3.
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=lab02
RUN="runs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
log() { echo; echo "== $*" | tee -a "$RUN/steps.log"; }
save() { local name="$1"; shift; { echo "\$ $*"; "$@" 2>&1 || true; } | tee "$RUN/$name.txt"; }
events() { kubectl get events --field-selector involvedObject.name="$1",reason=FailedScheduling -o custom-columns=MESSAGE:.message --no-headers 2>&1 | tail -1; }
ready() { kubectl wait --for=condition=Ready "$@" --timeout=10m; }

if ! docker info >/dev/null 2>&1; then echo "Docker is not running (with Colima: colima start)"; exit 1; fi

log "Versions"
{ uname -a; sw_vers 2>/dev/null || true; sysctl -n hw.memsize 2>/dev/null || true
  docker version --format 'docker client {{.Client.Version}} / server {{.Server.Version}}'
  kind version; kubectl version --client; helm version --short; } | tee "$RUN/versions.txt"

log "Step 0: create the cluster (1 control plane, 1 worker; CDI and two DRA feature gates on)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "Cluster $CLUSTER already exists: reusing it (delete it with scripts/cleanup.sh for a fresh start)" | tee -a "$RUN/steps.log"
  kubectl config use-context "kind-$CLUSTER"
else
  kind create cluster --name "$CLUSTER" --config kind-cluster.yaml
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s
save step0-nodes kubectl get nodes -o wide
save step0-dra-api kubectl api-resources --api-group=resource.k8s.io

log "Step 1: install the mock-GPU DRA driver (one GPU on the worker)"
scripts/install-driver.sh 2>&1 | tee -a "$RUN/steps.log"
save step1-driver kubectl get pods -n dra-example-driver
save step1-deviceclass kubectl get deviceclass
save step1-resourceslice kubectl get resourceslices -o yaml

kubectl delete pod trainer-a trainer-b notebook-a notebook-b notebook-c classic-pod slice-a slice-b slice-c --ignore-not-found --wait=true >/dev/null
kubectl delete resourceclaim shared-gpu shared-gpu-long slice-a slice-b slice-c --ignore-not-found >/dev/null
kubectl delete resourceclaimtemplate one-gpu --ignore-not-found >/dev/null

log "Step 2: break it. Two pods, a claim each, one GPU"
kubectl apply -f manifests/02-one-gpu-each.yaml
ready pod/trainer-a; sleep 10
save step2-pods kubectl get pods -o wide
save step2-claims kubectl get resourceclaims
save step2-trainer-a kubectl logs trainer-a
save step2-event events trainer-b
kubectl delete -f manifests/02-one-gpu-each.yaml --wait=true

log "Step 3: share it. Two pods, one claim"
kubectl apply -f manifests/03-shared-claim.yaml
ready pod/notebook-a pod/notebook-b
save step3-pods kubectl get pods -o wide
save step3-notebook-a kubectl logs notebook-a
save step3-notebook-b kubectl logs notebook-b
save step3-claim kubectl get resourceclaim shared-gpu -o jsonpath='{.status}'
kubectl delete -f manifests/03-shared-claim.yaml --wait=true

log "Step 4: say how to share (driver settings in the claim)"
kubectl apply -f manifests/04-sharing-setting.yaml
ready pod/notebook-c
save step4-notebook-c kubectl logs notebook-c
kubectl delete -f manifests/04-sharing-setting.yaml --wait=true

log "Step 5: the Lab 1 way, served by DRA"
kubectl apply -f manifests/05-classic-pod.yaml
ready pod/classic-pod
save step5-pod kubectl get pod classic-pod -o wide
save step5-classic-pod kubectl logs classic-pod
save step5-claims kubectl get resourceclaims
kubectl delete -f manifests/05-classic-pod.yaml --wait=true

log "Step 6: slice it. Reinstall the driver so claims can take slices of the GPU"
scripts/install-driver.sh slices 2>&1 | tee -a "$RUN/steps.log"
sleep 10
save step6-resourceslice kubectl get resourceslices -o yaml
kubectl apply -f manifests/06-slice-a.yaml; ready pod/slice-a
kubectl apply -f manifests/06-slice-b.yaml; ready pod/slice-b
kubectl apply -f manifests/06-slice-c.yaml; sleep 20
save step6-pods kubectl get pods -o wide
save step6-slice-a kubectl logs slice-a
save step6-claims kubectl get resourceclaims
save step6-allocations sh -c "for c in slice-a slice-b slice-c; do echo \"\$c: \$(kubectl get resourceclaim \$c -o jsonpath='{.status.allocation.devices.results}')\"; done"
save step6-event events slice-c

log "Done. Evidence in $RUN. Run scripts/check.sh, then scripts/cleanup.sh when finished."
