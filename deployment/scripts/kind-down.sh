#!/usr/bin/env bash
# Delete the kind cluster kind-up.sh created.
set -euo pipefail
kind delete cluster --name yantra
