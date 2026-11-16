#!/usr/bin/env bash
# Lint and render the chart for every environment and validate every manifest against the Kubernetes and CRD
# schemas; check and unit-test the alert rules with promtool. Needs Docker only: helm, kubeconform and promtool run
# from pinned images. CI runs this on every change under deployment/. `--offline` skips schemas that cannot be
# fetched (CRDs, no network) instead of failing on them.
#
#   deployment/scripts/helm-check.sh [--offline]
set -euo pipefail

HELM_IMAGE="alpine/helm:3.16.3"
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.6.7-alpine"
PROMETHEUS_IMAGE="prom/prometheus:v2.55.1"
# staging and prod leave the ingress pod CIDR to the owner and refuse to render without it: a stand-in here
STAND_IN=(--set config.FORWARDED_ALLOW_IPS=10.0.0.0/8)
KUBE_VERSION="1.31.0"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

offline=false
for arg in "$@"; do
  case "$arg" in
    --offline) offline=true ;;
    *) echo "usage: $0 [--offline]" >&2; exit 2 ;;
  esac
done

deployment="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

helm() { docker run --rm -v "$deployment:/deployment:ro" "$HELM_IMAGE" "$@"; }

kubeconform_args=(-strict -summary -kubernetes-version "$KUBE_VERSION" -schema-location default -schema-location "$CRD_SCHEMAS")
if "$offline"; then
  kubeconform_args+=(-ignore-missing-schemas)
fi
# Manifests travel on stdin (`-`): a temp dir on the host may not be visible to the Docker VM.
kubeconform() { docker run --rm -i -v "$deployment:/deployment:ro" "$KUBECONFORM_IMAGE" "${kubeconform_args[@]}" "$@"; }

render() { # <env> [helm args...]
  local env="$1"
  shift
  local extra=()
  [[ "$env" != local ]] && extra=("${STAND_IN[@]}")
  helm template yantra /deployment/helm/yantra -f "/deployment/helm/yantra/values-$env.yaml" \
    --namespace "yantra-$env" ${extra[@]+"${extra[@]}"} "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

for env in local staging prod; do
  echo "== chart, values-$env.yaml"
  extra=()
  [[ "$env" != local ]] && extra=("${STAND_IN[@]}")
  helm lint /deployment/helm/yantra -f "/deployment/helm/yantra/values-$env.yaml" ${extra[@]+"${extra[@]}"}
  render "$env" | kubeconform -
done

echo "== the chart refuses what a deployed environment must not run on"
render staging --set secrets.external=false > /dev/null 2>&1 && fail "staging rendered with plain secrets"
helm template yantra /deployment/helm/yantra -f /deployment/helm/yantra/values-staging.yaml > /dev/null 2>&1 \
  && fail "staging rendered without FORWARDED_ALLOW_IPS"
render prod --set app.keycloakOrigin= > /dev/null 2>&1 && fail "prod rendered an app without a Keycloak origin"
echo "ok"

echo "== rendered shape (staging)"
staging="$(render staging)"
doc() { # <kind> <name>: one rendered document (fails when there is none, so a negative check cannot pass empty)
  local out
  out="$(awk -v k="kind: $1" -v n="  name: $2" '
    function flush() { if (has_k && has_n) printf "%s", d; d = ""; has_k = has_n = 0 }
    $0 == "---" { flush(); next }
    { d = d $0 "\n"; if ($0 == k) has_k = 1; if ($0 == n) has_n = 1 }
    END { flush() }' <<< "$staging")"
  [[ -n "$out" ]] || fail "no $1 $2 rendered"
  printf '%s\n' "$out"
}
has() { # <kind> <name> <text>: does that document contain the text (exits when the document is missing)
  local d
  d="$(doc "$1" "$2")" || exit 1
  grep -qF -- "$3" <<< "$d"
}
has Deployment yantra-app "mountPath: /etc/nginx/conf.d" && fail "the app hides the image's nginx site under a volume"
has Deployment yantra-work-api "replicas:" && fail "an HPA-scaled Deployment renders replicas"
has Deployment yantra-money-events "replicas: 1" || fail "money-events lost its replicas"
has Deployment yantra-work-api "YANTRA_BANK_KEY" && fail "work holds the bank key"
has Deployment yantra-money-api "name: YANTRA_REQUIRES_BANK_KEY" || fail "money does not demand its bank key"
has Ingress yantra-files 'proxy-body-size: "600m"' || fail "the files host keeps the 1 MiB body limit"
has Ingress yantra 'proxy-body-size: "10m"' || fail "the API keeps the 1 MiB body limit"
has NetworkPolicy yantra-work-api "app.kubernetes.io/name" || fail "work admits the whole monitoring namespace"
has NetworkPolicy yantra-minio "money-" && fail "MinIO admits money"
echo "ok"

echo "== Assessment v2 (staging with Odoo and the exam app on)"
ASSESS=(--set odoo.enabled=true --set odoo.dbHost=postgres.example --set assess.enabled=true
  --set assess.keycloakIssuer=https://auth.staging.yantra.example/realms/yantra --set assess.vertex=true)
render staging --set assess.enabled=true > /dev/null 2>&1 && fail "assess rendered without Odoo"
render staging "${ASSESS[@]}" --set assess.keycloakIssuer= > /dev/null 2>&1 && fail "assess rendered without an issuer"
staging="$(render staging "${ASSESS[@]}")"
kubeconform - <<< "$staging"
has Deployment yantra-assess-app 'value: "yantra-odoo:8069"' || fail "the exam app does not proxy to Odoo"
has Deployment yantra-assess-app "readOnlyRootFilesystem: true" || fail "the exam app writes its root filesystem"
has Ingress yantra-assess "host: assess.staging.yantra.example" || fail "no assess host"
has Ingress yantra-assess 'proxy-body-size: "50m"' || fail "the assess host keeps the 1 MiB body limit"
has Deployment yantra-work-api "name: YANTRA_ASSESS_CLIENT_SECRET" || fail "work-api has no assess client secret"
has Deployment yantra-work-events 'value: "https://auth.staging.yantra.example/realms/yantra/protocol/openid-connect/token"' \
  || fail "work-events has no assess token URL"
has Deployment yantra-money-api "YANTRA_ASSESS" && fail "money holds assess settings"
has Deployment yantra-odoo "/assessments_be/ready" || fail "Odoo is ready before Assessment v2 is"
has Deployment yantra-odoo "--max-cron-threads=2" || fail "Odoo runs no cron threads"
has Deployment yantra-odoo "name: YANTRA_VERTEX_SA_JSON_FILE" || fail "the Vertex key is not handed to Odoo"
has NetworkPolicy yantra-odoo "component: assess-app" || fail "Odoo refuses the exam app"
has NetworkPolicy yantra-odoo "component: money-api" && fail "Odoo admits money"
has ExternalSecret yantra-assess-client-secret "key: yantra/staging/assess-client-secret" \
  || fail "the assess client secret is not read from the store"
echo "ok"

echo "== alert rules"
promtool() { docker run --rm --entrypoint promtool -v "$deployment/observability:/rules:ro" -w /rules "$PROMETHEUS_IMAGE" "$@"; }
promtool check rules alerts.yaml
promtool test rules alerts.test.yaml

echo "== Argo CD applications and Kyverno policies"
kubeconform /deployment/argocd /deployment/policies /deployment/kind/deps.yaml
