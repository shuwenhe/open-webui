#!/bin/bash

# 设置在命令失败时立即退出，并在管道中捕获错误
set -euo pipefail

# --- 配置变量 ---
OPENWEBUI_DIR="/opt/open-webui"
WEBUI_PORT="8080" # Open WebUI 监听的端口
PYTHON_VERSION="3.11" # 脚本将尝试安装和使用的 Python 版本

# --- 检查是否以 root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要 root 权限才能运行。请使用 sudo 执行。"
   exit 1
fi

echo "--- 开始安装 Open WebUI ---"
echo "安装目录: ${OPENWEBUI_DIR}"
echo "监听端口: ${WEBUI_PORT}"
echo "Python 版本: ${PYTHON_VERSION}"
echo ""

# --- 步骤 1: 更新系统并安装必要的系统依赖 ---
echo "[步骤 1/8] 更新系统并安装必要的系统依赖..."
apt update
apt install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-venv git curl build-essential

# --- 安装 Node.js (推荐使用 nvm 管理 Node.js 版本) ---
# 注意：在脚本中直接运行 nvm 安装脚本并 sourcing 是为了让 nvm 在当前脚本会话中可用
echo "[步骤 2/8] 安装 Node.js (通过 nvm)..."
# 下载并运行 nvm 安装脚本
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

# 使 nvm 在当前 shell 会话中可用
# 检查 nvm.sh 路径，它可能在 ~/.nvm/nvm.sh 或其他位置
NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# 如果 nvm 仍然不可用，尝试从 /etc/profile 或 ~/.bashrc 重新加载
if ! command -v nvm &> /dev/null; then
    echo "NVM 未能立即加载，尝试从 ~/.bashrc 或 /etc/profile 加载..."
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    elif [ -f "/etc/profile" ]; then
        source "/etc/profile"
    fi
fi

# 再次检查 nvm 是否可用
if ! command -v nvm &> /dev/null; then
    echo "错误: NVM 未能成功安装或加载。请手动检查 NVM 安装。"
    exit 1
fi

nvm install node # 安装最新 LTS 版本
nvm use node     # 使用最新 LTS 版本
echo "Node.js 安装完成。"

# --- 步骤 3: 克隆 Open WebUI 源代码到临时目录，并移动到安装目录 ---
echo "[步骤 3/8] 克隆 Open WebUI 源代码并移动到安装目录 ${OPENWEBUI_DIR}..."
TEMP_CLONE_DIR=$(mktemp -d)
git clone https://github.com/open-webui/open-webui.git "${TEMP_CLONE_DIR}"
mv "${TEMP_CLONE_DIR}" "${OPENWEBUI_DIR}"
rm -rf "${TEMP_CLONE_DIR}" # 清理临时目录
echo "Open WebUI 源代码已克隆到 ${OPENWEBUI_DIR}。"

# --- 步骤 4: 创建并激活 Python 虚拟环境，安装后端依赖 ---
echo "[步骤 4/8] 创建并激活 Python 虚拟环境，安装后端 Python 依赖..."
cd "${OPENWEBUI_DIR}"
python${PYTHON_VERSION} -m venv venv
# 使用虚拟环境中的 pip
"${OPENWEBUI_DIR}/venv/bin/pip" install -r requirements.txt
echo "后端 Python 依赖安装完成。"

# --- 步骤 5: 构建前端 ---
echo "[步骤 5/8] 构建前端..."
# 确保 npm 在 PATH 中
export PATH="$NVM_DIR/versions/node/$(nvm current)/bin:$PATH"
npm install
npm run build
echo "前端构建完成。"

# --- 步骤 6: 配置为 Systemd 服务 ---
echo "[步骤 6/8] 配置为 Systemd 服务..."

# 创建运行服务的用户和组
if ! id "openwebui" &>/dev/null; then
    groupadd --system openwebui
    useradd --system -g openwebui -d "${OPENWEBUI_DIR}" -s /sbin/nologin openwebui
    echo "创建了用户和组: openwebui"
fi

# 确保安装目录的所有权和权限正确
chown -R openwebui:openwebui "${OPENWEBUI_DIR}"
chmod -R 755 "${OPENWEBUI_DIR}"

# 创建 .env 文件并设置端口
echo "WEBUI_PORT=${WEBUI_PORT}" | tee "${OPENWEBUI_DIR}/.env"
chown openwebui:openwebui "${OPENWEBUI_DIR}/.env"
echo "创建了 .env 文件，设置 WEBUI_PORT=${WEBUI_PORT}。"

# 创建 systemd 服务文件
cat <<EOF | tee /etc/systemd/system/openwebui.service
[Unit]
Description=Open WebUI (pip) Service
After=network.target ollama.service

[Service]
Type=simple
User=openwebui
Group=openwebui
WorkingDirectory=${OPENWEBUI_DIR}
EnvironmentFile=${OPENWEBUI_DIR}/.env
ExecStart=${OPENWEBUI_DIR}/venv/bin/python -m openwebui serve --host 0.0.0.0 --port ${WEBUI_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
echo "Systemd 服务文件 /etc/systemd/system/openwebui.service 已创建。"

# --- 步骤 7: 重新加载 systemd 配置，启用并启动服务 ---
echo "[步骤 7/8] 重新加载 systemd 配置，启用并启动服务..."
systemctl daemon-reload
systemctl enable openwebui.service
systemctl start openwebui.service
echo "Open WebUI 服务已启用并启动。"

# --- 步骤 8: 配置防火墙 (如果 ufw 已启用) ---
echo "[步骤 8/8] 配置防火墙..."
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    echo "UFW 防火墙已启用，允许端口 ${WEBUI_PORT}/tcp..."
    ufw allow "${WEBUI_PORT}/tcp"
    ufw reload
else
    echo "UFW 防火墙未启用或未安装，跳过防火墙配置。"
fi

echo ""
echo "--- Open WebUI 安装完成 ---"
echo "请检查服务状态: sudo systemctl status openwebui.service"
echo "如果服务正常运行，您可以在浏览器中访问: http://$(hostname -I | awk '{print $1}'):${WEBUI_PORT}"
echo "首次访问时，您需要创建管理员用户。"
echo "请确保您的 Ollama 服务已在后台运行并可访问。"
echo "如果遇到问题，请查看服务日志: journalctl -u openwebui.service -f"

