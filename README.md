# Phase 0 — K8s + vLLM 推理服务平台 + GPU 监控

> 路线图位置：全家桶全链路 **Phase 0（地基）**。先把推理服务平台在 K8s 上跑通，并接上 GPU 监控；后续 Phase 1-4 在其上叠加。

## 目录结构

```
vllm-phase0/
├── README.md
├── install_vllm_uv.sh              # 裸金属/云主机用 uv 装 vLLM（规避 NCCL 冲突）
├── k8s/
│   └── vllm-deployment.yaml        # K8s 单副本 Deployment + Service（裸 vllm serve）
└── monitoring/
    ├── install-monitoring.sh        # Helm 装 Prometheus + DCGM-Exporter
    ├── prometheus-stack-values.yaml  # kube-prometheus-stack 精简配置
    └── dcgm-exporter-values.yaml     # DCGM-Exporter（暴露 GPU 指标 + ServiceMonitor）
```

## 前置条件

- 一个带 GPU 节点的 K8s 集群（AutoDL / 云厂商 / BSCC-A6），已安装 **NVIDIA device plugin**（`nvidia.com/gpu` 资源可见）。
- 已装 `kubectl`、`helm`。
- 裸金属/云主机装 vLLM 时：NVIDIA 驱动（具备 CUDA 12.9 能力）、`uv`。

## A. 裸金属 / 云主机跑 vLLM（uv 方式）

适用 AutoDL、BSCC-A6 计算节点、本地 Linux GPU 主机（非 K8s 场景）。

```bash
bash install_vllm_uv.sh
# 启动（示例）
source .venv/bin/activate
vllm serve Qwen/Qwen2.5-0.5B-Instruct --tensor-parallel-size 1 --port 8000
```

**为什么用 uv 而不是 conda**：conda 装的 PyTorch 会静态链接 NCCL，和 vLLM 自带的 NCCL 冲突；uv 开全新虚拟环境 + `--torch-backend=auto` 用预编译二进制（默认 CUDA 12.9，支持 py3.10-3.13），从源头避开。

## B. K8s 部署（单副本裸 vllm serve）

```bash
kubectl apply -f k8s/vllm-deployment.yaml
# 验证
kubectl -n vllm rollout status deployment/vllm-server
kubectl -n vllm port-forward svc/vllm-server 8000:8000
curl http://localhost:8000/v1/models
```

- 默认模型 `Qwen/Qwen2.5-0.5B-Instruct`（小模型 smoke test，单卡即可）。
- 生产换成 7B/更大：改 `MODEL_NAME` 并上调 `resources.limits.nvidia.com/gpu` 与 `memory`。
- 镜像 `vllm/vllm-openai:latest` 已是官方预编译好、无 NCCL 冲突的运行时，K8s 侧无需再处理安装坑。
- 首次启动会拉模型权重（较慢），可设 `HF_HUB_ENABLE_HF_TRANSFER=1` 加速（需镜像内已装 hf_transfer）。
- 如需模型权重跨重启缓存，可把 `emptyDir` 换成 PVC（已在 README 末尾注释说明）。

## C. GPU 监控（Prometheus + DCGM-Exporter）

```bash
bash monitoring/install-monitoring.sh
```

- `kube-prometheus-stack` 提供 Prometheus + Grafana + Operator。
- `dcgm-exporter` 在 GPU 节点暴露 `/metrics`（指标如 `DCGM_FI_DEV_GPU_UTIL`、`DCGM_FI_DEV_MEM_COPY_UTIL`），并通过 ServiceMonitor 被 Prometheus 自动抓取。
- 验证抓取：`kubectl -n monitoring get servicemonitor` 应能看到 `dcgm-exporter`；Prometheus UI → Status → Targets 里 `dcgm` 为 UP。
- Grafana 看 GPU：Grafana（默认 admin/admin）→ + → Import → 输入社区面板 ID **12239**（NVIDIA DCGM Exporter）或 **16620**（DCGM Exporter Full）→ 选 Prometheus 数据源。
- 关键 PromQL（验证 vLLM 推理时的 GPU 利用率）：
  ```
  DCGM_FI_DEV_GPU_UTIL{job="dcgm-exporter"}
  DCGM_FI_DEV_MEM_COPY_UTIL{job="dcgm-exporter"}
  ```

## 验证清单

- [ ] `curl /v1/models` 返回模型名
- [ ] `curl /v1/chat/completions` 能拿到推理结果（OpenAI 兼容）
- [ ] Prometheus Targets 中 dcgm-exporter = UP
- [ ] Grafana GPU 面板能看到利用率曲线

## 关键坑回顾

1. **NCCL 冲突**：conda PyTorch + vLLM 静态链接 NCCL 冲突 → 用 uv 全新环境 / 官方镜像。
2. **GPU 资源名**：K8s 里是 `nvidia.com/gpu`，依赖 NVIDIA device plugin，没装则 Pod 一直 Pending。
3. **/dev/shm 太小**：vLLM 高频共享内存，容器默认 shm 易爆 → 已挂 `emptyDir(medium:Memory)`。
4. **模型首次拉取慢**：大模型和弱网会拖长 readiness，探针 initialDelay 已留余量。

## 下一步（Phase 1）

推理端点跑通并监控到位后，下一步可上 **Ray Serve LLM** 做多副本自动伸缩，并在同一 OpenAI 端点追加 2 行 `engine_kwargs`（`enable_auto_tool_choice` + `tool_call_parser=hermes`）支持 Agent 工具调用。

## 附：模型权重缓存（可选）

把 `vllm-deployment.yaml` 里的 `dshm` 卷替换成 PVC 即可跨重启复用权重，避免每次冷启重新下载：

```yaml
volumes:
  - name: model-cache
    persistentVolumeClaim:
      claimName: vllm-model-cache
```
并在 `volumeMounts` 中挂载到 `/root/.cache/huggingface`（vLLM 默认缓存目录）。
