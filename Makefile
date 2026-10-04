SHELL := /bin/bash
.DEFAULT_GOAL := help

# Все команды идемпотентны: их можно запускать повторно.

.PHONY: help
help: ## Список команд
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2}'

.PHONY: deploy
deploy: ## Полное развертывание с нуля: хост + kubeadm + Calico + все компоненты (нужен sudo)
	sudo bash scripts/deploy.sh

.PHONY: verify
verify: ## Smoke-тесты: Gateway API, Prometheus, Fluentd -> OpenSearch
	bash scripts/verify.sh

.PHONY: info
info: ## Адреса UI, пароли и команды для ручной проверки
	bash scripts/info.sh

.PHONY: host
host: ## Только подготовка хоста (containerd, kubeadm, helm)
	sudo bash scripts/00-host-prepare.sh

.PHONY: cluster
cluster: host ## Только kubeadm-кластер + Calico
	sudo bash scripts/01-cluster.sh

.PHONY: platform
platform: ## Только Envoy Gateway + kube-prometheus-stack (в существующий кластер)
	bash scripts/02-platform.sh

.PHONY: apps
apps: ## Только ресурсы решения через Kustomize (приложение, Gateway API, логи, мониторинг)
	bash scripts/03-apps.sh

.PHONY: deploy-k8s
deploy-k8s: platform apps ## Развернуть в уже существующий кластер (KUBECONFIG), без kubeadm
	bash scripts/info.sh

.PHONY: status
status: ## Состояние подов, Gateway и маршрутов
	kubectl get nodes -o wide
	kubectl get gatewayclass,gateway -A
	kubectl get httproute -A
	kubectl get pods -A -o wide

.PHONY: lint
lint: ## Статические проверки (shellcheck, yamllint, kustomize build)
	shellcheck scripts/*.sh
	yamllint -s .
	kubectl kustomize deploy/manifests > /dev/null && echo "kustomize build: OK"

.PHONY: destroy
destroy: ## Удалить кластер (kubeadm reset)
	sudo bash scripts/destroy.sh
