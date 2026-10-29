#!/usr/bin/env bash
# install-monitoring.sh — K8s 上部署 Prometheus + DCGM-Exporter，监控 vLLM 的 GPU
set -euo pipefail
cd "$(dirname "$0")"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# 1) kube-prometheus-stack（Prometheus + Grafana + Operator）
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f ./prometheus-stack-values.yaml

# 2) DCGM-Exporter（暴露 GPU 指标，含 ServiceMonitor）
helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
  -n monitoring \
  -f ./dcgm-exporter-values.yaml

echo "==> 完成。"
echo "Grafana:     kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "Prometheus:  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo "导入 GPU 面板：Grafana → + → Import → 输入 ID 12239 或 16620"
