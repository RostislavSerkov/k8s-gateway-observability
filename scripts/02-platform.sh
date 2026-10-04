#!/usr/bin/env bash
# Шаг 2. Платформенные компоненты:
#   namespaces, секреты (генерируются, в репозитории их нет), Envoy Gateway, kube-prometheus-stack.
# Идемпотентен: helm upgrade --install, kubectl apply, секреты создаются только если их нет.
source "$(dirname "$0")/lib.sh"
setup_kubeconfig
require_cmd kubectl helm openssl

MANIFESTS="${REPO_ROOT}/deploy/manifests"
HELM_VALUES="${REPO_ROOT}/deploy/helm"

log "Namespaces"
kubectl apply -f "${MANIFESTS}/namespaces.yaml"

# ---------- Секреты ----------
rand_pw() { openssl rand -hex 12; }
secret_exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

log "Секреты (генерируются один раз и переиспользуются)"
if ! secret_exists monitoring grafana-admin; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(rand_pw)"
  ok "monitoring/grafana-admin создан"
else
  ok "monitoring/grafana-admin уже существует"
fi

# Basic Auth для Prometheus и OpenSearch Dashboards на Gateway (Envoy Gateway SecurityPolicy)
if ! secret_exists monitoring gateway-basic-auth; then
  pw=$(rand_pw)
  sha=$(printf '%s' "$pw" | openssl dgst -binary -sha1 | openssl base64)
  kubectl -n monitoring create secret generic gateway-basic-auth \
    --from-literal=.htpasswd="admin:{SHA}${sha}" \
    --from-literal=username=admin --from-literal=password="$pw"
  ok "monitoring/gateway-basic-auth создан"
fi
# Тот же секрет нужен в namespace logging (SecurityPolicy ссылается на секрет в своем namespace)
kubectl -n monitoring get secret gateway-basic-auth -o json \
  | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences)' \
  | kubectl -n logging apply -f - >/dev/null
ok "basic-auth секреты синхронизированы"

# Самоподписанный wildcard-сертификат для HTTPS listener Gateway
if ! secret_exists gateway-infra demo-tls; then
  tmpd=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 \
    -keyout "${tmpd}/tls.key" -out "${tmpd}/tls.crt" \
    -subj "/CN=*.${DEMO_DOMAIN}/O=gw-observability-demo" \
    -addext "subjectAltName=DNS:*.${DEMO_DOMAIN},DNS:${DEMO_DOMAIN}" 2>/dev/null
  kubectl -n gateway-infra create secret tls demo-tls --cert="${tmpd}/tls.crt" --key="${tmpd}/tls.key"
  rm -rf "$tmpd"
  ok "gateway-infra/demo-tls создан (self-signed, *.${DEMO_DOMAIN})"
else
  ok "gateway-infra/demo-tls уже существует"
fi

# ---------- Envoy Gateway ----------
log "Envoy Gateway ${ENVOY_GATEWAY_VERSION} (+ CRD Gateway API ${GATEWAY_API_VERSION})"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system \
  -f "${HELM_VALUES}/envoy-gateway-values.yaml" \
  --wait --timeout 10m
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=300s
wait_crd gateways.gateway.networking.k8s.io
wait_crd httproutes.gateway.networking.k8s.io
ok "Envoy Gateway установлен"

# ---------- kube-prometheus-stack ----------
log "kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION} (Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update prometheus-community >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
  --namespace monitoring \
  -f "${HELM_VALUES}/kube-prometheus-stack-values.yaml" \
  --wait --timeout 15m
wait_crd servicemonitors.monitoring.coreos.com
wait_crd podmonitors.monitoring.coreos.com
wait_crd prometheusrules.monitoring.coreos.com
ok "kube-prometheus-stack установлен"
