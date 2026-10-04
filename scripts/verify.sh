#!/usr/bin/env bash
# Smoke-тесты решения. Проверяет все обязательные части и дополнительные возможности:
#   1. Приложение через Gateway API (HTTP/HTTPS, path, header, weighted split, Basic Auth)
#   2. Prometheus: targets up + PromQL-запросы к метрикам nginx, Envoy, Fluentd, ноды
#   3. Логирование: запрос с уникальной меткой -> запись в OpenSearch (через Fluentd)
# Выход с кодом != 0 при любой ошибке обязательной части.
source "$(dirname "$0")/lib.sh"
# Проверки не должны обрываться на первой ошибке: собираем все результаты и падаем в конце
set +e +o pipefail
trap - ERR
setup_kubeconfig
require_cmd kubectl curl jq python3

FAILED=0
pass() { ok "$*"; }
fail() { printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; FAILED=1; }

NODE_IP="${NODE_IP:-$(node_ip)}"
ENVOY_SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gw,gateway.envoyproxy.io/owning-gateway-namespace=gateway-infra \
  -o jsonpath='{.items[0].metadata.name}')
HTTP_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SVC" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
HTTPS_PORT=$(kubectl -n envoy-gateway-system get svc "$ENVOY_SVC" -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
GW="http://${NODE_IP}:${HTTP_PORT}"
BASIC_USER=$(kubectl -n monitoring get secret gateway-basic-auth -o jsonpath='{.data.username}' | base64 -d)
BASIC_PASS=$(kubectl -n monitoring get secret gateway-basic-auth -o jsonpath='{.data.password}' | base64 -d)

echo
log "Gateway: сервис ${ENVOY_SVC}, HTTP ${GW}, HTTPS https://${NODE_IP}:${HTTPS_PORT}"

# ---------------------------------------------------------------- 1. Gateway API
log "1. Приложение через Gateway API"

body=$(curl -s --max-time 5 --retry 10 --retry-delay 3 --retry-all-errors "${GW}/")
[[ "$body" == "Hello World!" ]] && pass "GET / -> '${body}'" || fail "GET / вернул '${body}', ожидалось 'Hello World!'"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${GW}/")
[[ "$code" == "200" ]] && pass "HTTP код 200" || fail "HTTP код ${code}"

hdr=$(curl -s -D - -o /dev/null --max-time 5 "${GW}/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')
[[ "$hdr" == "v1" ]] && pass "Заголовок X-App-Version: v1 (ответ от hello-v1)" || fail "X-App-Version='${hdr}'"

body=$(curl -s --max-time 5 "${GW}/v2/")
[[ "$body" == *"v2 canary"* ]] && pass "Маршрут по path: GET /v2/ -> '${body}'" || fail "GET /v2/ -> '${body}'"

body=$(curl -s --max-time 5 -H 'x-canary: true' "${GW}/")
[[ "$body" == *"v2 canary"* ]] && pass "Маршрут по header: x-canary: true -> '${body}'" || fail "x-canary -> '${body}'"

body=$(curl -sk --max-time 5 --resolve "hello.${DEMO_DOMAIN}:${HTTPS_PORT}:${NODE_IP}" "https://hello.${DEMO_DOMAIN}:${HTTPS_PORT}/")
[[ "$body" == "Hello World!" ]] && pass "HTTPS (TLS terminate на Gateway) -> '${body}'" || fail "HTTPS -> '${body}'"

v1=0; v2=0; N=200
for _ in $(seq "$N"); do
  r=$(curl -s --max-time 3 -H "Host: canary.${DEMO_DOMAIN}" "${GW}/")
  if [[ "$r" == *"v2 canary"* ]]; then v2=$((v2 + 1)); elif [[ "$r" == "Hello World!" ]]; then v1=$((v1 + 1)); fi
done
if (( v1 + v2 == N && v2 >= N * 8 / 100 && v2 <= N * 35 / 100 )); then
  pass "Traffic split canary.${DEMO_DOMAIN} (80/20): v1=${v1}, v2=${v2} из ${N}"
else
  fail "Traffic split: v1=${v1}, v2=${v2} из ${N} (ожидалось ~80/20)"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: prometheus.${DEMO_DOMAIN}" "${GW}/-/ready")
[[ "$code" == "401" ]] && pass "Basic Auth: prometheus.${DEMO_DOMAIN} без пароля -> 401" || fail "Prometheus без пароля -> ${code}, ожидалось 401"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "${BASIC_USER}:${BASIC_PASS}" -H "Host: prometheus.${DEMO_DOMAIN}" "${GW}/-/ready")
[[ "$code" == "200" ]] && pass "Basic Auth: prometheus.${DEMO_DOMAIN} с паролем -> 200" || fail "Prometheus с паролем -> ${code}"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: grafana.${DEMO_DOMAIN}" "${GW}/api/health")
[[ "$code" == "200" ]] && pass "Grafana через Gateway: grafana.${DEMO_DOMAIN} -> 200" || fail "Grafana -> ${code}"

# Немного трафика с ошибками для метрик кодов ответа
for _ in $(seq 20); do curl -s -o /dev/null --max-time 3 "${GW}/error"; done

# ---------------------------------------------------------------- 2. Prometheus
log "2. Мониторинг: Prometheus"
prom_query() {
  svc_get monitoring kps-prometheus:9090 "/api/v1/query?query=$(urlencode "$1")"
}
# Запрос к OpenSearch: через прокси API-сервера, если не вышло - curl изнутри пода opensearch-0
os_get() {
  local out
  out=$(svc_get logging opensearch:9200 "$1" 2>/dev/null)
  if [[ -z "$out" ]]; then
    out=$(kubectl -n logging exec opensearch-0 -c opensearch -- curl -s "http://localhost:9200$1" 2>/dev/null)
  fi
  printf '%s' "$out"
}
prom_value() {
  prom_query "$1" | jq -r '.data.result[0].value[1] // empty'
}

# Цели становятся активными не сразу после деплоя: ждем до ~3 минут
check_up() {
  local job_re=$1 name=$2 val
  for _ in $(seq 36); do
    val=$(prom_value "min(up{job=~\"${job_re}\"})")
    [[ "$val" == "1" ]] && { pass "target ${name}: up"; return 0; }
    sleep 5
  done
  fail "target ${name}: не up (значение '${val}')"
}
check_up 'hello-v1|hello-v2'      'nginx-exporter (demo/hello-v1, hello-v2)'
check_up '.*envoy-proxy.*'        'Envoy data plane (PodMonitor envoy-proxy)'
check_up 'envoy-gateway'          'Envoy Gateway controller'
check_up '.*fluentd.*'            'Fluentd (PodMonitor fluentd)'
check_up 'node-exporter'          'node-exporter'
check_up 'kube-state-metrics'     'kube-state-metrics'
check_up 'apiserver'              'kube-apiserver'
check_up 'kube-etcd'              'etcd'

sleep 20  # один-два scrape interval, чтобы трафик выше попал в метрики
for q in \
  'sum(nginx_http_requests_total{namespace="demo"})' \
  'sum by (envoy_response_code_class) (envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/demo/.*"})' \
  'histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/demo/.*"}[5m])))' \
  'sum(rate(container_cpu_usage_seconds_total{namespace="demo", container!=""}[5m]))' \
  'sum(fluentd_output_status_emit_records{type="opensearch"})'
do
  res=$(prom_query "$q" | jq -c '[.data.result[] | {m: (.metric | del(.__name__)), v: .value[1]}]')
  if [[ "$res" != "[]" && -n "$res" ]]; then pass "PromQL: ${q}"; echo "        => ${res:0:220}"; else fail "PromQL без данных: ${q}"; fi
done

# ---------------------------------------------------------------- 3. Logging
log "3. Логирование: Fluentd -> OpenSearch"
probe="probe$(date +%s)$RANDOM"
curl -s -o /dev/null --max-time 5 "${GW}/?probe=${probe}"
echo "        Отправлен запрос: GET ${GW}/?probe=${probe}"
found=""
for _ in $(seq 40); do
  found=$(os_get "/k8s-logs-*/_search?q=${probe}&size=5" \
    | jq -c '.hits.hits[]._source | select(.kubernetes.namespace_name == "demo") | {time: .["@timestamp"], ns: .kubernetes.namespace_name, pod: .kubernetes.pod_name, log_type, status: .http.status, uri: .http.uri}' 2>/dev/null | head -1 || true)
  [[ -n "$found" ]] && break
  sleep 3
done
if [[ -n "$found" ]]; then
  pass "Access-лог nginx с меткой ${probe} найден в OpenSearch"
  echo "        => ${found}"
else
  fail "Запись с меткой ${probe} не появилась в OpenSearch за 2 минуты"
fi

found=$(os_get "/k8s-logs-*/_search?q=${probe}&size=10" \
  | jq -c '.hits.hits[]._source | select(.kubernetes.namespace_name == "envoy-gateway-system") | {pod: .kubernetes.pod_name, code: .http.response_code, path: .http.path}' 2>/dev/null | head -1 || true)
[[ -n "$found" ]] && { pass "Access-лог Envoy (Gateway) для того же запроса найден"; echo "        => ${found}"; } \
  || warn "Access-лог Envoy для запроса пока не найден (не входит в обязательную часть)"

cnt=$(os_get "/k8s-logs-*/_count?q=log_type:access" | jq -r '.count // 0')
(( cnt > 0 )) && pass "Всего access-записей в OpenSearch: ${cnt}" || fail "В OpenSearch нет access-записей"

# ---------------------------------------------------------------- Итог
echo
if (( FAILED == 0 )); then
  ok "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
else
  die "Есть проваленные проверки (см. [FAIL] выше)"
fi
