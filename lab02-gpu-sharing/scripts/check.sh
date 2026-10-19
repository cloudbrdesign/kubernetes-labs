#!/usr/bin/env bash
# Lab 2 checks. Run after step 6 (run-lab.sh ends there). Prints PASS/FAIL per check.
set -uo pipefail
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
alloc() { kubectl get resourceclaim "$1" -o jsonpath='{.status.allocation.devices.results[0].device}{" "}{.status.allocation.devices.results[0].consumedCapacity.memory}'; }

check "1 the DRA API (resource.k8s.io/v1) is served" \
  "kubectl get --raw /apis/resource.k8s.io/v1"
check "2 the device class gpu.example.com exists" \
  "kubectl get deviceclass gpu.example.com"
check "3 the driver offers one GPU that several claims may share" \
  "[ \"\$(kubectl get resourceslices -o jsonpath='{.items[*].spec.devices[*].allowMultipleAllocations}')\" = true ]"
check "4 slice-a and slice-b are Running" \
  "[ \"\$(kubectl get pod slice-a slice-b -o jsonpath='{.items[*].status.phase}')\" = 'Running Running' ]"
check "5 both took 16Gi from the same device, gpu-0" \
  "[ \"\$(alloc slice-a)\" = 'gpu-0 16Gi' ] && [ \"\$(alloc slice-b)\" = 'gpu-0 16Gi' ]"
check "6 slice-c (64Gi) is Pending: 16 + 16 + 64 is more than 80" \
  "[ \"\$(kubectl get pod slice-c -o jsonpath='{.status.phase}')\" = Pending ]"
check "7 slice-c's claim is not allocated" \
  "[ -z \"\$(kubectl get resourceclaim slice-c -o jsonpath='{.status.allocation}')\" ]"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
