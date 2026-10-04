#!/usr/bin/env bash
# Шаг 0. Подготовка хоста Ubuntu 24.04 к kubeadm:
#   swap, модули ядра, sysctl, containerd (SystemdCgroup), kubeadm/kubelet/kubectl, helm.
# Идемпотентен: каждый шаг проверяет текущее состояние и меняет только то, что нужно.
source "$(dirname "$0")/lib.sh"
require_root

export DEBIAN_FRONTEND=noninteractive

# --- 0. Проверка ОС ---
. /etc/os-release
if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
  warn "Решение тестировалось на Ubuntu 24.04, обнаружено: ${PRETTY_NAME}. Продолжаю на ваш риск."
fi
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
(( $(nproc) >= 2 )) || die "Нужно минимум 2 vCPU (рекомендуется 4)"
(( mem_mb >= 6000 )) || warn "Памяти ${mem_mb} МБ, рекомендуется не меньше 8 ГБ"

# --- 1. Swap: kubelet по умолчанию требует отключенный swap ---
log "Отключаю swap"
swapoff -a
sed -ri '/^[^#].*\sswap\s/s/^/# disabled-by-k8s-bootstrap: /' /etc/fstab
ok "swap отключен"

# --- 2. Модули ядра и sysctl ---
log "Модули ядра и sysctl"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# OpenSearch: требуемое значение для mmap
vm.max_map_count                    = 262144
# Fluentd и kubelet используют inotify на /var/log
fs.inotify.max_user_instances       = 1024
fs.inotify.max_user_watches         = 524288
EOF
sysctl --system >/dev/null
ok "модули и sysctl применены"

# --- 3. Базовые пакеты ---
log "Устанавливаю базовые пакеты"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg jq openssl conntrack socat ebtables ethtool ipset >/dev/null
ok "базовые пакеты"

# --- 4. kubeadm / kubelet / kubectl из официального репозитория pkgs.k8s.io ---
keyring=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
repo_line="deb [signed-by=${keyring}] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /"
if [[ ! -f "$keyring" ]] || ! grep -qsF "$repo_line" /etc/apt/sources.list.d/kubernetes.list; then
  log "Подключаю репозиторий pkgs.k8s.io (${KUBERNETES_MINOR})"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" | gpg --dearmor --yes -o "$keyring"
  echo "$repo_line" > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
fi

installed=$(dpkg-query -W -f='${Version}' kubeadm 2>/dev/null || true)
if [[ "$installed" != "${KUBERNETES_VERSION}-"* ]]; then
  log "Устанавливаю kubeadm/kubelet/kubectl ${KUBERNETES_VERSION}"
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  apt-get install -y -qq --allow-downgrades --allow-change-held-packages \
    "kubelet=${KUBERNETES_VERSION}-*" "kubeadm=${KUBERNETES_VERSION}-*" "kubectl=${KUBERNETES_VERSION}-*" >/dev/null
  apt-mark hold kubelet kubeadm kubectl >/dev/null
fi
systemctl enable kubelet >/dev/null
ok "kubeadm $(kubeadm version -o short)"

# crictl должен смотреть в containerd
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# --- 5. containerd ---
if ! command -v containerd >/dev/null 2>&1; then
  log "Устанавливаю containerd из репозитория Ubuntu"
  apt-get install -y -qq containerd >/dev/null
fi
log "Настраиваю containerd ($(containerd --version | awk '{print $3}'))"
mkdir -p /etc/containerd
# pause-образ = версия, которую ожидает kubeadm (убирает предупреждение preflight)
pause_image=$(kubeadm config images list --kubernetes-version "v${KUBERNETES_VERSION}" 2>/dev/null | grep pause || true)
tmp_cfg=$(mktemp)
containerd config default > "$tmp_cfg"
# cgroup-драйвер systemd (как у kubelet)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$tmp_cfg"
grep -q 'SystemdCgroup = true' "$tmp_cfg" || die "Не удалось включить SystemdCgroup в конфиге containerd"
if [[ -n "$pause_image" ]]; then
  sed -ri "s#(sandbox_image|sandbox) = ['\"][^'\"]*pause[^'\"]*['\"]#\1 = '${pause_image}'#" "$tmp_cfg"
fi
if ! cmp -s "$tmp_cfg" /etc/containerd/config.toml; then
  install -m 0644 "$tmp_cfg" /etc/containerd/config.toml
  systemctl restart containerd
  ok "конфиг containerd обновлен, сервис перезапущен"
else
  ok "конфиг containerd уже актуален"
fi
rm -f "$tmp_cfg"
systemctl enable --now containerd >/dev/null

# crictl должен смотреть в containerd
cat > /etc/crictl.yaml <<'EOT'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOT

# --- 6. Helm (бинарь с проверкой sha256) ---
if ! command -v helm >/dev/null 2>&1 || [[ "$(helm version --template '{{.Version}}')" != "${HELM_VERSION}" ]]; then
  log "Устанавливаю Helm ${HELM_VERSION}"
  arch=$(dpkg --print-architecture)
  tgz="helm-${HELM_VERSION}-linux-${arch}.tar.gz"
  workdir=$(mktemp -d)
  curl -fsSL -o "${workdir}/${tgz}" "https://get.helm.sh/${tgz}"
  curl -fsSL -o "${workdir}/${tgz}.sha256sum" "https://get.helm.sh/${tgz}.sha256sum"
  (cd "$workdir" && sha256sum -c "${tgz}.sha256sum" >/dev/null) || die "Контрольная сумма Helm не совпала"
  tar -xzf "${workdir}/${tgz}" -C "$workdir"
  install -m 0755 "${workdir}/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "$workdir"
fi
ok "helm $(helm version --template '{{.Version}}')"

ok "Хост подготовлен"
