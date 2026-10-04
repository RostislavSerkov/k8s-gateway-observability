#!/usr/bin/env bash
# Шаг 3. Ресурсы решения через Kustomize: приложение, Gateway API, логирование, мониторинг.
# Идемпотентен: kubectl apply (декларативно), повторный запуск приводит к тому же состоянию.
source "$(dirname "$0")/lib.sh"
setup_kubeconfig
require_cmd kubectl

log "Применяю deploy/manifests (kubectl apply -k)"
kubectl apply -k "${REPO_ROOT}/deploy/manifests"

log "Жду готовности приложения"
kubectl -n demo rollout status deployment/hello-v1 --timeout=300s
kubectl -n demo rollout status deployment/hello-v2 --timeout=300s

log "Жду Gateway (Programmed) и Envoy data plane"
kubectl -n gateway-infra wait --for=condition=Programmed gateway/public-gw --timeout=300s \
  || warn "Gateway пока не Programmed (статус адресов), продолжаю: доступность проверит make verify"
envoy_deploy_exists() {
  kubectl -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=public-gw -o name | grep -q .
}
retry 30 5 envoy_deploy_exists || die "Deployment Envoy для public-gw не создан"
kubectl -n envoy-gateway-system rollout status deployment \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gw --timeout=300s 2>/dev/null \
  || kubectl -n envoy-gateway-system wait --for=condition=Available deployment \
       -l gateway.envoyproxy.io/owning-gateway-name=public-gw --timeout=300s
for route in demo/hello demo/hello-canary monitoring/grafana monitoring/prometheus logging/opensearch-dashboards; do
  kubectl -n "${route%%/*}" wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    "httproute/${route##*/}" --timeout=120s >/dev/null
done
ok "Gateway и HTTPRoute приняты контроллером"

log "Жду стек логирования (OpenSearch, Dashboards, Fluentd)"
kubectl -n logging rollout status statefulset/opensearch --timeout=600s
kubectl -n logging rollout status deployment/opensearch-dashboards --timeout=600s
kubectl -n logging rollout status daemonset/fluentd --timeout=300s

# Шаблон индекса для Discover в OpenSearch Dashboards (идемпотентно: overwrite=true)
log "Создаю index pattern k8s-logs-* в OpenSearch Dashboards"
if kubectl -n logging exec deploy/opensearch-dashboards -- \
     curl -sf -o /dev/null -X POST \
     'http://localhost:5601/api/saved_objects/index-pattern/k8s-logs?overwrite=true' \
     -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
     -d '{"attributes":{"title":"k8s-logs-*","timeFieldName":"@timestamp"}}' 2>/dev/null; then
  kubectl -n logging exec deploy/opensearch-dashboards -- \
    curl -sf -o /dev/null -X POST 'http://localhost:5601/api/opensearch-dashboards/settings' \
    -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d '{"changes":{"defaultIndex":"k8s-logs"}}' 2>/dev/null || true
  ok "index pattern k8s-logs-* готов"
else
  warn "Не удалось создать index pattern автоматически (создайте k8s-logs-* вручную в UI), на сбор логов это не влияет"
fi

ok "Все компоненты развернуты"
