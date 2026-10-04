#!/usr/bin/env bash
# Адреса и учетные данные для ручной проверки (пароли генерируются при развертывании).
source "$(dirname "$0")/lib.sh"
setup_kubeconfig

NODE_IP="${NODE_IP:-$(node_ip)}"
secret() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d; }
GRAFANA_PASS=$(secret monitoring grafana-admin admin-password)
BASIC_USER=$(secret monitoring gateway-basic-auth username)
BASIC_PASS=$(secret monitoring gateway-basic-auth password)
H=${GATEWAY_HTTP_NODEPORT}
S=${GATEWAY_HTTPS_NODEPORT}

cat <<EOF

================== Как проверить ==================
Node IP: ${NODE_IP}    Gateway: HTTP :${H}, HTTPS :${S} (NodePort)

Приложение через Gateway API:
  curl http://${NODE_IP}:${H}/                                   # Hello World!
  curl http://${NODE_IP}:${H}/v2/                                # маршрут по path -> v2
  curl -H 'x-canary: true' http://${NODE_IP}:${H}/               # маршрут по header -> v2
  curl -H 'Host: canary.${DEMO_DOMAIN}' http://${NODE_IP}:${H}/        # 80/20 split v1/v2
  curl -k --resolve hello.${DEMO_DOMAIN}:${S}:${NODE_IP} https://hello.${DEMO_DOMAIN}:${S}/   # HTTPS

UI (добавьте в /etc/hosts машины с браузером):
  ${NODE_IP} grafana.${DEMO_DOMAIN} prometheus.${DEMO_DOMAIN} logs.${DEMO_DOMAIN} canary.${DEMO_DOMAIN} hello.${DEMO_DOMAIN}

  Grafana:     http://grafana.${DEMO_DOMAIN}:${H}      admin / ${GRAFANA_PASS}
               дашборд "Hello App & Gateway"
  Prometheus:  http://prometheus.${DEMO_DOMAIN}:${H}   ${BASIC_USER} / ${BASIC_PASS}  (Basic Auth на Gateway)
  Логи (OSD):  http://logs.${DEMO_DOMAIN}:${H}         ${BASIC_USER} / ${BASIC_PASS}  -> Discover, индекс k8s-logs-*

Автоматическая проверка всего:  make verify
====================================================
EOF
