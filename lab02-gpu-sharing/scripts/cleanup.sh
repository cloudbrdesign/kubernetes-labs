#!/usr/bin/env bash
# Deletes the Lab 2 cluster (and everything in it).
set -euo pipefail
kind delete cluster --name lab02
