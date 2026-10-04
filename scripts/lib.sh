#!/usr/bin/env bash
# Общие функции для всех скриптов развертывания.
# shellcheck disable=SC2034

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "${REPO_ROOT}/versions.env"

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { printf '%s[%(%H:%M:%S)T] ==>%s %s\n' "$C_BLUE" -1 "$C_RESET" "$*"; }
ok()   { printf '%s  [OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

trap 'die "Ошибка в ${BASH_SOURCE[0]}:${LINENO} (команда: ${BASH_COMMAND})"' ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Этот шаг меняет настройки хоста, запустите его через sudo"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Не найдена команда '$c'. Сначала выполните 'sudo make cluster' или установите её."
  done
}

# Выбор kubeconfig: явный KUBECONFIG -> ~/.kube/config -> admin.conf (root)
setup_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    return
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  elif [[ -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  else
    die "kubeconfig не найден. Выполните 'sudo make cluster' или задайте KUBECONFIG."
  fi
}

# retry <попыток> <пауза_сек> <команда...>
retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    (( i < attempts )) && sleep "$delay"
  done
  return 1
}

# Ожидание появления CRD и перехода в Established
wait_crd() {
  local crd=$1
  retry 60 5 kubectl get crd "$crd" >/dev/null 2>&1 || die "CRD $crd не появилась"
  kubectl wait --for=condition=Established "crd/$crd" --timeout=120s >/dev/null
}

# Внутренний IP единственной (первой) ноды кластера
node_ip() {
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# GET к сервису внутри кластера через API-server proxy (не нужен port-forward)
svc_get() {
  local ns=$1 svc=$2 path=$3
  kubectl get --raw "/api/v1/namespaces/${ns}/services/${svc}/proxy${path}"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
