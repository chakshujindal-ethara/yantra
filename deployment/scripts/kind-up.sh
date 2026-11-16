#!/usr/bin/env bash
# Install the chart on a local kind cluster and prove it with `yantra smoke`. For the owner, and for an agent
# with Docker before merging a chart change; not run in CI (image loads make it slow and flaky there).
#
# Host prerequisites: docker, kind (>= 0.24), kubectl (>= 1.29), helm (3.16), uv (for `yantra smoke`).
# The compose rig must be stopped first: this script port-forwards the same ports (8090 gateway, 8180 Keycloak,
# 8095 app) so the app and CLI defaults work unchanged.
#
#   deployment/scripts/kind-up.sh          # create, build, load, install, smoke
#   deployment/scripts/kind-down.sh        # delete the cluster
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster="yantra"
ns="yantra-local"

for tool in docker kind kubectl helm uv; do
  command -v "$tool" > /dev/null || { echo "missing prerequisite: $tool" >&2; exit 1; }
done
for port in 8090 8180 8095; do
  if lsof -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "port $port is in use (stop the compose rig: docker compose -f deployment/local/compose.yaml stop)" >&2
    exit 1
  fi
done

if ! kind get clusters | grep -qx "$cluster"; then
  kind create cluster --config "$repo/deployment/kind/cluster.yaml"
fi
kubectl config use-context "kind-$cluster"

echo "== build and load images"
docker build -t yantra/python:local "$repo"
docker build -t yantra/app:local \
  --build-arg GATEWAY_URL=http://localhost:8090 --build-arg KEYCLOAK_URL=http://localhost:8180 \
  --build-arg DIRECT_LOGIN=true "$repo/app"
kind load docker-image --name "$cluster" yantra/python:local yantra/app:local

echo "== infrastructure"
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ns" create configmap yantra-realm \
  --from-file=yantra-realm.json="$repo/deployment/local/keycloak/yantra-realm.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ns" apply -f "$repo/deployment/kind/deps.yaml"
kubectl -n "$ns" rollout status deploy/postgres deploy/redis deploy/nats --timeout=180s
kubectl -n "$ns" rollout status deploy/keycloak --timeout=300s

echo "== chart (migrations run as pre-install hooks)"
helm upgrade --install yantra "$repo/deployment/helm/yantra" --namespace "$ns" \
  -f "$repo/deployment/helm/yantra/values.yaml" -f "$repo/deployment/helm/yantra/values-local.yaml" \
  --wait --timeout 10m

echo "== port-forwards"
pids=()
kubectl -n "$ns" port-forward svc/yantra-gateway 8090:8090 > /dev/null & pids+=($!)
kubectl -n "$ns" port-forward svc/keycloak 8180:8080 > /dev/null & pids+=($!)
kubectl -n "$ns" port-forward svc/yantra-app 8095:8080 > /dev/null & pids+=($!)
kubectl -n "$ns" port-forward svc/yantra-minio 9000:9000 > /dev/null & pids+=($!)
trap 'kill "${pids[@]}" 2> /dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf localhost:8090/health > /dev/null && break
  sleep 1
done

echo "== smoke"
(cd "$repo" && uv run yantra smoke)
echo "kind-up: PASS (port-forwards stop when this script exits; rerun them by hand to keep using the cluster)"
