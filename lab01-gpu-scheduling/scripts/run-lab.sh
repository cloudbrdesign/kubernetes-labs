#!/usr/bin/env bash
# Runs every step of Lab 1 in order and saves the evidence to runs/<timestamp>/.
# Read the README first: it explains each step. This script is for a clean, recorded run.
# Needs: docker (Docker Desktop or Colima), kind v0.33.0, kubectl, curl.
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=lab01
KWOK_VERSION=v0.8.0
RUN="runs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
log() { echo; echo "== $*" | tee -a "$RUN/steps.log"; }
save() { local name="$1"; shift; { echo "\$ $*"; "$@" 2>&1 || true; } | tee "$RUN/$name.txt"; }
events() { kubectl get events --field-selector involvedObject.name="$POD",reason=FailedScheduling -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers 2>&1 | tail -1; }

log "Versions"
{ uname -a; sw_vers 2>/dev/null || true; sysctl -n hw.memsize 2>/dev/null || true
  docker version --format 'docker client {{.Client.Version}} / server {{.Server.Version}}'
  kind version; kubectl version --client; echo "KWOK ${KWOK_VERSION}"; } | tee "$RUN/versions.txt"

log "Step 0: create the cluster (1 control plane, 2 workers)"
kind create cluster --name "$CLUSTER" --config kind-cluster.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
save nodes-start kubectl get nodes -o wide
GPU_NODE="${CLUSTER}-worker"; CPU_NODE="${CLUSTER}-worker2"

log "Step 1: ask for a GPU on a cluster that has none"
kubectl apply -f manifests/01-gpu-pod.yaml
sleep 10
save step1-pods kubectl get pods -o wide
POD=gpu-pod-1; save step1-event events
save step1-describe kubectl describe pod gpu-pod-1

log "Step 2: advertise one GPU on $GPU_NODE"
save step2-capacity-before kubectl get node "$GPU_NODE" -o jsonpath='{.status.capacity}'
scripts/advertise-gpu.sh "$GPU_NODE" 1 | tee -a "$RUN/steps.log"
kubectl wait --for=condition=Ready pod/gpu-pod-1 --timeout=180s
save step2-capacity-after kubectl get node "$GPU_NODE" -o jsonpath='{.status.capacity}'
save step2-pods kubectl get pods -o wide
save step2-allocated sh -c "kubectl describe node $GPU_NODE | sed -n '/Allocated resources/,/Events/p'"

log "Step 3: a second GPU pod (one GPU = one pod)"
kubectl apply -f manifests/02-gpu-pod-2.yaml
sleep 10
save step3-pods kubectl get pods -o wide
POD=gpu-pod-2; save step3-event events
save step3-describe kubectl describe pod gpu-pod-2

log "Step 4: taint the GPU node so other pods stay off"
kubectl taint nodes "$GPU_NODE" nvidia.com/gpu=present:NoSchedule
kubectl apply -f manifests/03-cpu-pod.yaml
kubectl wait --for=condition=Ready pod/cpu-pod --timeout=120s
save step4-pods kubectl get pods -o wide
save step4-taints kubectl get node "$GPU_NODE" -o jsonpath='{.spec.taints}'
echo "cpu-pod should be on $CPU_NODE" | tee -a "$RUN/steps.log"

log "Step 5: cap team-a at one GPU"
kubectl delete pod gpu-pod-1 gpu-pod-2 --wait=true
kubectl apply -f manifests/04-team-quota.yaml
kubectl apply -f manifests/05-team-a-gpu-1.yaml
kubectl wait -n team-a --for=condition=Ready pod/team-a-gpu-1 --timeout=120s
save step5-second-pod kubectl apply -f manifests/05-team-a-gpu-2.yaml
save step5-quota kubectl describe resourcequota gpu-quota -n team-a

log "Step 6: scale out with KWOK fake GPU nodes"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"
kubectl -n kube-system rollout status deployment/kwok-controller --timeout=180s
kubectl apply -f manifests/06-kwok-gpu-nodes.yaml
sleep 10
save step6-nodes kubectl get nodes -o wide
kubectl apply -f manifests/07-gpu-deployment.yaml
sleep 15
save step6-pods kubectl get pods -l app=trainer -o wide

log "Persistence check: is the hand-advertised GPU still there after 60 s?"
sleep 60
save persistence kubectl get node "$GPU_NODE" -o jsonpath='{.status.capacity}'

log "Done. Evidence in $RUN. Run scripts/check.sh, then scripts/cleanup.sh when finished."
