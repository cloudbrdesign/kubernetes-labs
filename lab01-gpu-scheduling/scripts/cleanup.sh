#!/usr/bin/env bash
# Deletes the lab cluster and everything in it.
set -euo pipefail
kind delete cluster --name lab01
