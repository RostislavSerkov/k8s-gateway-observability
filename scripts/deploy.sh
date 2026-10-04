#!/usr/bin/env bash
# Полное развертывание "с нуля" на чистой Ubuntu 24.04:
#   хост -> kubeadm-кластер + Calico -> Envoy Gateway + kube-prometheus-stack -> приложение, Gateway API, логи.
# Повторный запуск безопасен (все шаги идемпотентны).
#
# Использование: sudo ./scripts/deploy.sh
#   SKIP_CLUSTER=1 sudo -E ./scripts/deploy.sh   - не трогать хост/кластер (уже есть кластер, задан KUBECONFIG)
source "$(dirname "$0")/lib.sh"

started=$(date +%s)
DIR="$(dirname "$0")"

if [[ "${SKIP_CLUSTER:-0}" != "1" ]]; then
  require_root
  "${DIR}/00-host-prepare.sh"
  "${DIR}/01-cluster.sh"
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
"${DIR}/02-platform.sh"
"${DIR}/03-apps.sh"

ok "Развертывание завершено за $(( ($(date +%s) - started) / 60 )) мин"
"${DIR}/info.sh"
