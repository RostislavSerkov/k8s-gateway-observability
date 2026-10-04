# Шаблон конфигурации kubeadm. Плейсхолдеры __X__ подставляет scripts/01-cluster.sh.
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: __NODE_IP__
  bindPort: 6443
nodeRegistration:
  name: __NODE_NAME__
  criSocket: unix:///run/containerd/containerd.sock
  # Single-node кластер: рабочие нагрузки разрешены на control-plane
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: __K8S_VERSION__
clusterName: gw-observability
networking:
  podSubnet: __POD_CIDR__
  serviceSubnet: __SERVICE_CIDR__
  dnsDomain: cluster.local
# Метрики компонентов control-plane доступны Prometheus (kube-prometheus-stack).
# controller-manager и scheduler отдают /metrics по HTTPS с authn/authz.
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: http://0.0.0.0:2381
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: false
containerLogMaxSize: 50Mi
containerLogMaxFiles: 3
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
metricsBindAddress: 0.0.0.0:10249
