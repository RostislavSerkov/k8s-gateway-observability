# k8s-gateway-observability

[![ci](https://github.com/RostislavSerkov/k8s-gateway-observability/actions/workflows/ci.yaml/badge.svg)](https://github.com/RostislavSerkov/k8s-gateway-observability/actions/workflows/ci.yaml)

Решение задания: поднять с нуля Kubernetes, развернуть в нем простое веб-приложение, опубликовать его через
Gateway API и собрать вокруг него мониторинг (Prometheus) и сбор логов (Fluentd).

Кратко:

- кластер ставится через kubeadm на Ubuntu 24.04 (single-node, containerd, Calico);
- приложение: nginx, отвечает `Hello World!`, есть две версии (v1 и v2 для canary);
- Gateway API: Envoy Gateway;
- метрики: kube-prometheus-stack (Prometheus, Grafana, Alertmanager);
- логи: Fluentd DaemonSet, хранилище OpenSearch, просмотр в OpenSearch Dashboards;
- все разворачивается командой `make deploy`, проверяется командой `make verify`.

```bash
git clone https://github.com/RostislavSerkov/k8s-gateway-observability.git
cd k8s-gateway-observability
make deploy
make verify
```

## Архитектура

```
                       Ubuntu 24.04, Kubernetes v1.36.5 (kubeadm, 1 нода), Calico
 +--------+   :30080   +--------------------------+      +--------------------------+
 | client | ---------> | Envoy (data plane)       | ---> | ns demo                  |
 |  curl  |   :30443   | ns envoy-gateway-system  |      |  hello-v1 x2  (v1)       |
 +--------+            |  управляет Envoy Gateway |      |  hello-v2 x1  (canary)   |
                       +--------------------------+      |  nginx + nginx-exporter  |
                          ^ Gateway public-gw            +--------------------------+
                          | HTTPRoute hello, hello-canary,     |  stdout/stderr
                          | grafana, prometheus, logs          v
 +----------------------------------+        +---------------------------------------+
 | ns monitoring                    |        | ns logging                            |
 |  Prometheus  <- scrape: nginx-   |        |  Fluentd (DaemonSet)                  |
 |    exporter, Envoy, Fluentd,     |        |    /var/log/containers -> OpenSearch  |
 |    node-exporter, kubelet, ...   |        |  OpenSearch Dashboards (поиск логов)  |
 |  Grafana, Alertmanager           |        +---------------------------------------+
 +----------------------------------+
```

Как ходит запрос: клиент стучится на NodePort ноды (30080 для HTTP, 30443 для HTTPS), попадает в Envoy,
Envoy по правилам HTTPRoute отправляет запрос в Service нужной версии приложения.

Метрики: Prometheus собирает nginx-prometheus-exporter (sidecar в подах приложения), Envoy (запросы, коды
ответов, latency), контроллер Envoy Gateway, Fluentd и стандартные цели kube-prometheus-stack: node-exporter,
kube-state-metrics, kubelet/cAdvisor, apiserver, etcd, scheduler, controller-manager, kube-proxy, CoreDNS.

Логи: nginx пишет access-лог в stdout в формате JSON, ошибки в stderr. containerd складывает это в
`/var/log/containers`. Fluentd читает файлы, добавляет метаданные Kubernetes (namespace, pod, labels),
разбирает JSON на поля и отправляет все в OpenSearch, в индексы `k8s-logs-YYYY.MM.DD`. Access-логи самого
Envoy тоже собираются.

Grafana, Prometheus и OpenSearch Dashboards опубликованы через тот же Gateway по именам
`grafana.demo.local`, `prometheus.demo.local`, `logs.demo.local`. Prometheus и Dashboards закрыты Basic Auth.

### Ресурсы Gateway API

| Ресурс | Namespace | Что делает |
|---|---|---|
| GatewayClass `envoy` | - | контроллер Envoy Gateway; через EnvoyProxy `public-proxy` задан NodePort, JSON access-лог и метрики |
| Gateway `public-gw` | gateway-infra | listener `http` (80) и `https` (443, TLS terminate, `*.demo.local`); принимает маршруты только из namespace с лейблом `gateway-access=true` |
| HTTPRoute `hello` | demo | `/` -> hello-v1; `/v2` -> hello-v2 (с URLRewrite); заголовок `x-canary: true` -> hello-v2; таймаут 10s |
| HTTPRoute `hello-canary` | demo | `canary.demo.local`: 80% на v1, 20% на v2 |
| HTTPRoute `grafana`, `prometheus` | monitoring | `grafana.demo.local`, `prometheus.demo.local` |
| HTTPRoute `opensearch-dashboards` | logging | `logs.demo.local` |
| SecurityPolicy | monitoring, logging | Basic Auth для Prometheus и Dashboards |
| BackendTrafficPolicy | demo | retry, circuit breaker, local rate limit |
| ClientTrafficPolicy | gateway-infra | таймауты клиентских соединений |

SecurityPolicy, BackendTrafficPolicy и ClientTrafficPolicy это CRD Envoy Gateway, остальное стандартный Gateway API.

## Версии

Все версии собраны в [`versions.env`](versions.env), теги образов указаны в манифестах.

| Компонент | Версия |
|---|---|
| ОС | Ubuntu 24.04 LTS |
| Kubernetes (kubeadm, kubelet, kubectl) | v1.36.5, из pkgs.k8s.io |
| Container runtime | containerd из репозитория Ubuntu |
| CNI | Calico v3.32.2 (tigera-operator) |
| Gateway API CRD | v1.6.1 (ставятся вместе с Envoy Gateway) |
| Реализация Gateway API | Envoy Gateway v1.9.2 (Helm-чарт `oci://docker.io/envoyproxy/gateway-helm`) |
| Helm | v3.22.0 |
| Приложение | `nginxinc/nginx-unprivileged:1.29.8-alpine` |
| Экспортер метрик nginx | `nginx/nginx-prometheus-exporter:1.5.3` |
| Мониторинг | kube-prometheus-stack 91.9.0 (Helm) |
| Логи | Fluentd v1.19.3, образ `fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-opensearch-1.1` |
| Хранилище логов | OpenSearch 3.8.0, OpenSearch Dashboards 3.8.0 |

Kubernetes взят v1.36, а не самый свежий v1.37, потому что Envoy Gateway v1.9 официально поддерживает v1.33-v1.36.
Платных сервисов и облачных балансировщиков решение не использует.

## Требования

- Ubuntu 24.04 LTS, x86_64, чистая VM или железо;
- 4 vCPU, 8 ГБ RAM, 30 ГБ диска (на 2 vCPU / 6 ГБ тоже поднимется, но медленнее);
- пользователь с sudo и доступ в интернет (apt, pkgs.k8s.io, get.helm.sh, Docker Hub, quay.io, registry.k8s.io, GitHub);
- свободны порты 6443, 30080, 30443; swap скрипт отключит сам;
- `git` и `make`: `sudo apt-get install -y git make`.

Проверялось на Ubuntu 24.04 LTS в GitHub Actions (раннер `ubuntu-24.04`), см. раздел CI ниже.

## Развертывание

```bash
sudo apt-get update && sudo apt-get install -y git make
git clone https://github.com/RostislavSerkov/k8s-gateway-observability.git
cd k8s-gateway-observability
make deploy
```

На чистой VM занимает примерно 15-20 минут. `make deploy` запускает `sudo ./scripts/deploy.sh`, который по очереди выполняет:

1. `scripts/00-host-prepare.sh` - подготовка хоста: отключает swap, включает модули `overlay` и `br_netfilter`,
   sysctl, ставит containerd (`SystemdCgroup = true`), kubeadm/kubelet/kubectl нужной версии (apt hold) и Helm
   (с проверкой sha256).
2. `scripts/01-cluster.sh` - `kubeadm init` по шаблону [`deploy/kubeadm/kubeadm-config.yaml.tpl`](deploy/kubeadm/kubeadm-config.yaml.tpl),
   копирует kubeconfig в `~/.kube/config`, ставит Calico. Taint с control-plane снят, так как нода одна.
3. `scripts/02-platform.sh` - создает namespace и секреты (пароль Grafana, Basic Auth, самоподписанный TLS),
   ставит Envoy Gateway и kube-prometheus-stack через Helm.
4. `scripts/03-apps.sh` - `kubectl apply -k deploy/manifests` (приложение, Gateway API, логирование,
   ServiceMonitor/PodMonitor, алерты, дашборд) и ждет, пока все поднимется.

В конце выводятся адреса и сгенерированные пароли. Их можно посмотреть еще раз через `make info`.

Повторный `make deploy` ничего не ломает: если кластер уже есть, `kubeadm init` пропускается, containerd
перезапускается только при изменении конфига, Helm-релизы обновляются через `helm upgrade --install`,
манифесты применяются через `kubectl apply`, секреты создаются только если их еще нет.

Другие команды:

```bash
make help        # список команд
make cluster     # только хост + kubeadm + Calico
make platform    # только Envoy Gateway и kube-prometheus-stack
make apps        # только манифесты (Kustomize)
make status      # ноды, Gateway, маршруты, поды
make info        # адреса и пароли
make destroy     # kubeadm reset
```

Если кластер уже есть (kind, minikube, свой kubeadm), можно поставить все без kubeadm-части.
Нужны `kubectl`, `helm`, `openssl`, `jq` и CNI с поддержкой NetworkPolicy:

```bash
export KUBECONFIG=~/.kube/config
make deploy-k8s
```

## Проверка

Быстрее всего запустить `make verify`. Скрипт проверяет все три части и в конце пишет `ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ`
или список того, что упало. Ниже то же самое руками.

### Приложение и Gateway API

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl -i http://$NODE_IP:30080/
```

Ожидаемый ответ:

```
HTTP/1.1 200 OK
x-app-version: v1
x-route: default
...
Hello World!
```

Статусы ресурсов:

```bash
kubectl get gatewayclass,gateway -A            # PROGRAMMED должно быть True
kubectl get httproute -A
kubectl -n demo describe httproute hello        # Accepted=True, ResolvedRefs=True
```

Остальные маршруты:

```bash
curl http://$NODE_IP:30080/v2/                          # маршрут по path, отвечает v2
curl -H 'x-canary: true' http://$NODE_IP:30080/         # маршрут по заголовку, отвечает v2

# traffic split 80/20
for i in $(seq 100); do curl -s -H 'Host: canary.demo.local' http://$NODE_IP:30080/; done | sort | uniq -c

# HTTPS (сертификат самоподписанный, поэтому -k)
curl -k --resolve hello.demo.local:30443:$NODE_IP https://hello.demo.local:30443/

# ответ 500, нужен чтобы было что показать в метриках и алертах
curl -i http://$NODE_IP:30080/error
```

### Мониторинг

`make verify` проверяет, что у Prometheus в состоянии `up` цели nginx-exporter, Envoy, Envoy Gateway, Fluentd,
node-exporter, kube-state-metrics, apiserver и etcd, а потом выполняет несколько PromQL-запросов и
показывает результат.

Что собирается:

| Источник | Как подключен | Примеры метрик |
|---|---|---|
| nginx (hello-v1, hello-v2) | sidecar nginx-prometheus-exporter, ServiceMonitor `demo/hello` | `nginx_http_requests_total`, `nginx_connections_active` |
| Envoy | PodMonitor `envoy-gateway-system/envoy-proxy` | `envoy_cluster_upstream_rq_total`, `envoy_cluster_upstream_rq_xx` (2xx/4xx/5xx), `envoy_cluster_upstream_rq_time_bucket` |
| Envoy Gateway | ServiceMonitor `envoy-gateway` | метрики контроллера |
| Fluentd | PodMonitor `logging/fluentd` | `fluentd_output_status_emit_records`, `fluentd_output_status_retry_count` |
| Нода и кластер | стандартные цели kube-prometheus-stack | CPU, RAM, диск, состояние объектов, метрики control-plane |

Для метрик control-plane в конфиге kubeadm controller-manager и scheduler слушают `0.0.0.0`, а etcd отдает
метрики на `:2381`, иначе Prometheus до них не достучится.

Еще есть recording rules и алерты в [`prometheusrule.yaml`](deploy/manifests/monitoring/prometheusrule.yaml):
нет доступных реплик, доля 5xx больше 5%, p95 больше 500 мс, ошибки отправки логов во Fluentd.

Запросы к Prometheus без port-forward, через прокси API-сервера:

```bash
# какие цели в namespace demo и их состояние
kubectl get --raw '/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query?query=up%7Bnamespace%3D%22demo%22%7D' \
  | jq '.data.result[] | {job: .metric.job, pod: .metric.pod, up: .value[1]}'

# сколько запросов обработала каждая версия
kubectl get --raw '/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query?query=sum%20by%20(version)%20(nginx_http_requests_total)' \
  | jq '.data.result'
```

Через браузер. На своей машине добавить в `/etc/hosts`:

```
<NODE_IP> grafana.demo.local prometheus.demo.local logs.demo.local
```

- Prometheus: `http://prometheus.demo.local:30080`, логин и пароль из `make info`. Status -> Targets,
  или запрос `sum by (envoy_response_code_class) (rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/demo/.*"}[1m]))`.
- Grafana: `http://grafana.demo.local:30080`, пользователь `admin`, пароль из `make info`. Дашборд
  "Hello App & Gateway": запросы и коды ответов через Gateway, latency p50/p95/p99, распределение трафика
  между v1 и v2, CPU и память подов, работа Fluentd. Стандартные дашборды kube-prometheus-stack тоже на месте.

### Логирование

`make verify` отправляет запрос с уникальной меткой вида `?probe=probe1759...` и ждет, пока такая запись
появится в OpenSearch.

Что собирается: логи контейнеров из namespace `demo` (access-лог nginx из stdout и error-лог из stderr) и
access-логи Envoy. Каждой записи проставляется `log_type`: `access` или `error`, поля из JSON лежат в `http.*`
(`http.status`, `http.uri`, `http.request_time` и т.д.), метаданные в `kubernetes.*`.
Куда: OpenSearch, индексы `k8s-logs-YYYY.MM.DD`. Конфиг Fluentd: [`fluent.conf`](deploy/manifests/logging/fluent.conf).

Руками:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://$NODE_IP:30080/?probe=check42"
sleep 5
kubectl get --raw '/api/v1/namespaces/logging/services/opensearch:9200/proxy/k8s-logs-*/_search?q=check42' \
  | jq '.hits.hits[]._source | {ts: .["@timestamp"], ns: .kubernetes.namespace_name, pod: .kubernetes.pod_name, type: .log_type, status: .http.status, uri: (.http.uri // .http.path)}'
```

На один запрос должно найтись две записи: от пода `hello-v1-...` (nginx) и от пода `envoy-...` (Gateway).

Через браузер: `http://logs.demo.local:30080` (Basic Auth, пароль из `make info`), Discover, индекс `k8s-logs-*`
создается автоматически. Например, `kubernetes.namespace_name:demo and http.status:500`.

## CI

[`.github/workflows/ci.yaml`](.github/workflows/ci.yaml), запускается на каждый push в `main`:

- `lint`: shellcheck, yamllint, `kubectl kustomize`, kubeconform по схемам Kubernetes и CRD;
- `e2e-kubeadm`: на чистом раннере `ubuntu-24.04` выполняется `make deploy`, `make verify`, затем еще раз
  `make deploy` (проверка идемпотентности) и `make verify`. Результат проверок выводится в Summary запуска.

## Что сделано сверх обязательного

| Что | Как | Как проверить |
|---|---|---|
| Маршрутизация по path и заголовку | правила `/v2` (URLRewrite) и `x-canary: true` в HTTPRoute `hello` | `curl .../v2/`, `curl -H 'x-canary: true' ...` |
| Несколько маршрутов и backend, маршрутизация по hostname | 5 HTTPRoute в трех namespace | `kubectl get httproute -A` |
| Traffic splitting | `hello-canary`, веса 80/20 | цикл curl из раздела проверки, панель в Grafana |
| TLS | listener `https`, сертификат генерируется при развертывании | `curl -k --resolve ...` |
| Разделение ролей | Gateway в `gateway-infra`, маршруты в namespace приложений, `allowedRoutes` по лейблу | `kubectl -n gateway-infra describe gateway public-gw` |
| Basic Auth на Gateway | SecurityPolicy для Prometheus и OpenSearch Dashboards | без пароля 401, с паролем 200 |
| Retry, circuit breaker, rate limit, таймауты | BackendTrafficPolicy, ClientTrafficPolicy, `timeouts` в HTTPRoute | `kubectl -n demo describe backendtrafficpolicy` |
| HTTP-метрики, коды ответов, latency, CPU/RAM | метрики Envoy и nginx-exporter, cAdvisor, recording rules | дашборд в Grafana |
| Алерты | PrometheusRule | Prometheus -> Alerts |
| Свой дашборд | ConfigMap с лейблом `grafana_dashboard=1` | Grafana -> "Hello App & Gateway" |
| Хранение и поиск логов, логи Envoy | OpenSearch и Dashboards | раздел про логирование |
| Мониторинг сбора логов | метрики Fluentd в Prometheus и алерты на них | `fluentd_output_status_*` |
| CI | GitHub Actions: линтеры и полный прогон на kubeadm | вкладка Actions |
| Безопасность | NetworkPolicy (default deny в `demo`, доступ к OpenSearch только у Fluentd и Dashboards), Pod Security Admission `restricted` для `demo`, non-root, read-only root FS, drop ALL capabilities, секреты не хранятся в репозитории | `kubectl get netpol -A`, `kubectl get ns --show-labels` |
| Надежность приложения | 2 реплики v1, PodDisruptionBudget, probes, preStop, limits | `kubectl -n demo get pdb,deploy` |

## Структура репозитория

```
Makefile                      make deploy / verify / info / destroy
versions.env                  версии компонентов
scripts/
  deploy.sh                   полный сценарий (шаги 00-03)
  00-host-prepare.sh          подготовка Ubuntu
  01-cluster.sh               kubeadm init + Calico
  02-platform.sh              секреты, Envoy Gateway, kube-prometheus-stack
  03-apps.sh                  kubectl apply -k deploy/manifests
  verify.sh                   проверка всех компонентов
  info.sh                     адреса и пароли
  destroy.sh                  kubeadm reset
  lib.sh                      общие функции
deploy/
  kubeadm/                    шаблон конфига kubeadm
  calico/                     Installation для tigera-operator
  helm/                       values для Envoy Gateway и kube-prometheus-stack
  manifests/                  Kustomize
    namespaces.yaml
    app/                      nginx v1/v2, Service, PDB, NetworkPolicy, ServiceMonitor
    gateway/                  EnvoyProxy, GatewayClass, Gateway, HTTPRoute, политики
    logging/                  Fluentd, OpenSearch, OpenSearch Dashboards
    monitoring/               PodMonitor/ServiceMonitor, PrometheusRule, дашборд
.github/workflows/ci.yaml     CI
```

## Ограничения

- Кластер из одной ноды. Для нескольких нод нужен `kubeadm join` и балансировщик или MetalLB перед NodePort.
- Наружу Gateway выставлен через NodePort (30080/30443), потому что в kubeadm без облака нет LoadBalancer.
- Постоянных томов нет: в чистом kubeadm нет StorageClass, поэтому Prometheus и OpenSearch хранят данные
  в `emptyDir`, и при пересоздании пода данные пропадают. Для нормальной эксплуатации нужен CSI-драйвер и PVC.
- Сертификат самоподписанный. В реальной установке лучше cert-manager.
- У OpenSearch отключен security-плагин. Снаружи он недоступен (NetworkPolicy), а Dashboards закрыт Basic Auth на Gateway.
- Метрики etcd отдаются по HTTP на `:2381`, controller-manager и scheduler слушают `0.0.0.0` (с аутентификацией).
  Если VM смотрит в интернет, эти порты стоит закрыть файрволом.
- Fluentd запущен от root (только чтение `/var/log`), потому что файлы логов контейнеров принадлежат root.
- Для развертывания нужен интернет: образы и пакеты скачиваются из публичных репозиториев.
