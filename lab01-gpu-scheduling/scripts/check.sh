#!/usr/bin/env bash
# Lab 1 checks. Run after run-lab.sh (or after doing the steps by hand). Prints PASS/FAIL per check.
set -uo pipefail
CLUSTER=lab01; GPU_NODE="${CLUSTER}-worker"; CPU_NODE="${CLUSTER}-worker2"
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

check "1 GPU node advertises nvidia.com/gpu=1" \
  "[ \"\$(kubectl get node $GPU_NODE -o jsonpath='{.status.capacity.nvidia\.com/gpu}')\" = 1 ]"
check "2 GPU node is tainted nvidia.com/gpu:NoSchedule" \
  "kubectl get node $GPU_NODE -o jsonpath='{.spec.taints[*].key}' | grep -q nvidia.com/gpu"
check "3 CPU-only pod avoided the GPU node and runs on $CPU_NODE" \
  "[ \"\$(kubectl get pod cpu-pod -o jsonpath='{.spec.nodeName}')\" = $CPU_NODE ]"
check "4 team-a quota allows 1 GPU and 1 is used" \
  "[ \"\$(kubectl get resourcequota gpu-quota -n team-a -o jsonpath='{.status.used.requests\.nvidia\.com/gpu}')\" = 1 ]"
check "5 the second team-a GPU pod was refused (does not exist)" \
  "! kubectl get pod team-a-gpu-2 -n team-a"
check "6 three fake GPU nodes are Ready" \
  "[ \"\$(kubectl get nodes -l type=kwok --no-headers | grep -c ' Ready')\" = 3 ]"
check "7 trainer pods landed on fake GPU nodes" \
  "[ \"\$(kubectl get pods -l app=trainer -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | grep -c kwok-gpu)\" = 3 ]"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
