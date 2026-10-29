#!/usr/bin/env bash
# install_vllm_uv.sh — 在裸金属 / 云主机上用 uv 安装 vLLM，规避 conda+PyTorch 的 NCCL 冲突
# 适用：AutoDL / BSCC-A6 超算计算节点 / 本地 Linux GPU 主机（非 K8s 场景）
set -euo pipefail

PY_VER="${PY_VER:-3.12}"
VLLM_VERSION="${VLLM_VERSION:-}"   # 留空=装最新

# 0) 确保 uv 存在（不污染系统 Python，uv 自带 managed python）
if ! command -v uv >/dev/null 2>&1; then
  echo "==> 安装 uv ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# 1) 全新虚拟环境（关键：不要用 conda 的 PyTorch，否则 NCCL 静态链接冲突）
uv venv --python "$PY_VER" --seed --managed-python .venv
source .venv/bin/activate

# 2) 安装 vLLM（预编译二进制默认基于 CUDA 12.9，支持 py3.10-3.13）
if [ -n "$VLLM_VERSION" ]; then
  uv pip install "vllm==$VLLM_VERSION" --torch-backend=auto
else
  uv pip install vllm --torch-backend=auto
fi

echo "==> 安装完成。验证："
python -c "import vllm; print('vllm', vllm.__version__)"

# 启动示例（小模型 smoke test，单卡即可）：
#   source .venv/bin/activate
#   vllm serve Qwen/Qwen2.5-0.5B-Instruct --tensor-parallel-size 1 --port 8000
