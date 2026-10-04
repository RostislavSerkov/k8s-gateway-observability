#!/usr/bin/env bash
# Шаг 1. Single-node кластер на kubeadm + CNI Calico (через tigera-operator).
# Идемпотентен: если кластер уже инициализирован, kubeadm init пропускается.
source "$(dirname "$0")/lib.sh"
require_root
require_cmd kubeadm kubectl

export KUBECONFIG=/etc/kubernetes/admin.conf

# IP интерфейса с маршрутом по умолчанию = адрес API-сервера и ноды
NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
[[ -n "$NODE_IP" ]] || die "Не удалось определить IP ноды, задайте NODE_IP=... явно"

# --- 1. kubeadm init ---
if [[ -f /etc/kubernetes/admin.conf ]] && kubectl get --raw /readyz >/dev/null 2>&1; then
  ok "Кластер уже инициализирован, kubeadm init пропущен"
else
  log "kubeadm init (Kubernetes v${KUBERNETES_VERSION}, node IP ${NODE_IP})"
  rendered=$(mktemp --suffix=.yaml)
  sed -e "s|__NODE_IP__|${NODE_IP}|g" \
      -e "s|__K8S_VERSION__|v${KUBERNETES_VERSION}|g" \
      -e "s|__POD_CIDR__|${POD_CIDR}|g" \
      -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
      -e "s|__NODE_NAME__|$(hostname -s | tr '[:upper:]' '[:lower:]')|g" \
      "${REPO_ROOT}/deploy/kubeadm/kubeadm-config.yaml.tpl" > "$rendered"
  kubeadm config validate --config "$rendered"
  kubeadm config images pull --config "$rendered"
  kubeadm init --config "$rendered" --upload-certs
  rm -f "$rendered"
  ok "kubeadm init выполнен"
fi

# kubeconfig для пользователя, вызвавшего sudo (и для root)
for home_dir in /root "$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; do
  [[ -d "$home_dir" ]] || continue
  owner=$(stat -c '%U:%G' "$home_dir")
  install -d -m 0700 -o "${owner%%:*}" -g "${owner##*:}" "${home_dir}/.kube"
  install -m 0600 -o "${owner%%:*}" -g "${owner##*:}" /etc/kubernetes/admin.conf "${home_dir}/.kube/config"
done
ok "kubeconfig скопирован в ~/.kube/config"

# --- 2. Calico ---
log "Устанавливаю Calico ${CALICO_VERSION} (tigera-operator)"
calico_base="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
kubectl apply --server-side --force-conflicts -f "${calico_base}/operator-crds.yaml" >/dev/null
kubectl apply --server-side --force-conflicts -f "${calico_base}/tigera-operator.yaml" >/dev/null
wait_crd installations.operator.tigera.io
sed "s|__POD_CIDR__|${POD_CIDR}|g" "${REPO_ROOT}/deploy/calico/installation.yaml" | kubectl apply -f -

log "Жду готовности Calico и ноды (до 10 минут)"
retry 60 10 kubectl get tigerastatus calico >/dev/null 2>&1 || die "tigerastatus/calico не появился"
kubectl wait --for=condition=Available tigerastatus/calico --timeout=600s
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s

# Single-node: на всякий случай снимаем taint control-plane (в kubeadm-config он уже пустой)
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true

ok "Кластер готов: $(kubectl get nodes -o wide --no-headers | awk '{print $1, $2, $5, $6}')"
