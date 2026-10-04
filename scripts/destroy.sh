#!/usr/bin/env bash
# Полное удаление кластера (kubeadm reset) и состояния CNI/Fluentd на ноде.
# Пакеты (containerd, kubeadm, helm) остаются установленными.
source "$(dirname "$0")/lib.sh"
require_root

if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "Удалить кластер Kubernetes на этой машине? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]] || { warn "Отменено"; exit 0; }
fi

log "kubeadm reset"
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true
rm -rf /etc/cni/net.d /var/lib/calico /var/run/calico /var/lib/fluentd /etc/kubernetes
rm -f /root/.kube/config
if [[ -n "${SUDO_USER:-}" ]]; then
  rm -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.kube/config"
fi
# Очистка правил, созданных kube-proxy и Calico
iptables-save | grep -v -E 'KUBE|cali-' | iptables-restore || true
ip link delete vxlan.calico 2>/dev/null || true
ok "Кластер удален. Повторное развертывание: make deploy"
