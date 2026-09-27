#!/bin/bash
set -e

SSH_PORT=119
SSH_DROPIN="/etc/ssh/sshd_config.d/99-custom-ssh-port.conf"

# =========================
# 基础检查
# =========================

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户执行此脚本。"
    echo "示例：sudo bash $0"
    exit 1
fi

echo "=================================================="
echo " Debian SSH + UFW 一键安全配置"
echo "=================================================="
echo
echo "将执行以下操作："
echo "  1. SSH 端口修改为：${SSH_PORT}"
echo "  2. 启用 UFW 防火墙"
echo "  3. 默认放行：${SSH_PORT}/tcp、443/tcp"
echo "  4. 可额外输入需要保留的端口"
echo

# =========================
# 输入额外 TCP 端口
# =========================

while true; do
    echo "请输入额外需要放行的 TCP 端口。"
    echo
    echo "正确示例："
    echo "  80"
    echo "  80,8080,8443"
    echo "  80 8080 8443"
    echo
    echo "如果没有额外 TCP 端口，直接按回车。"
    echo
    read -r -p "额外 TCP 端口: " EXTRA_TCP

    # 空值合法
    if [ -z "$EXTRA_TCP" ]; then
        break
    fi

    # 禁止中文逗号
    if echo "$EXTRA_TCP" | grep -q "，"; then
        echo
        echo "错误：检测到中文逗号。"
        echo "请使用英文逗号，例如：80,8080,8443"
        echo
        continue
    fi

    # 只允许数字、英文逗号和空格
    if ! echo "$EXTRA_TCP" | grep -Eq '^[0-9, ]+$'; then
        echo
        echo "错误：只能输入端口数字，并使用英文逗号或空格分隔。"
        echo "正确示例：80,8080,8443"
        echo
        continue
    fi

    PORT_ERROR=0

    # 将逗号转换为空格
    for PORT in $(echo "$EXTRA_TCP" | tr ',' ' '); do
        if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
            PORT_ERROR=1
            break
        fi

        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            PORT_ERROR=1
            break
        fi
    done

    if [ "$PORT_ERROR" -eq 1 ]; then
        echo
        echo "错误：端口必须是 1-65535 之间的数字。"
        echo
        continue
    fi

    break
done

echo

# =========================
# 输入额外 UDP 端口
# =========================

while true; do
    echo "请输入额外需要放行的 UDP 端口。"
    echo
    echo "例如："
    echo "  53"
    echo "  53,51820"
    echo
    echo "如果没有额外 UDP 端口，直接按回车。"
    echo
    read -r -p "额外 UDP 端口: " EXTRA_UDP

    if [ -z "$EXTRA_UDP" ]; then
        break
    fi

    if echo "$EXTRA_UDP" | grep -q "，"; then
        echo
        echo "错误：检测到中文逗号。"
        echo "请使用英文逗号，例如：53,51820"
        echo
        continue
    fi

    if ! echo "$EXTRA_UDP" | grep -Eq '^[0-9, ]+$'; then
        echo
        echo "错误：只能输入端口数字，并使用英文逗号或空格分隔。"
        echo
        continue
    fi

    PORT_ERROR=0

    for PORT in $(echo "$EXTRA_UDP" | tr ',' ' '); do
        if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
            PORT_ERROR=1
            break
        fi

        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            PORT_ERROR=1
            break
        fi
    done

    if [ "$PORT_ERROR" -eq 1 ]; then
        echo
        echo "错误：端口必须是 1-65535 之间的数字。"
        echo
        continue
    fi

    break
done

echo
echo "=================================================="
echo " 即将应用以下配置"
echo "=================================================="
echo
echo "SSH：${SSH_PORT}/tcp"
echo "HTTPS：443/tcp"

if [ -n "$EXTRA_TCP" ]; then
    echo "额外 TCP：$EXTRA_TCP"
fi

if [ -n "$EXTRA_UDP" ]; then
    echo "额外 UDP：$EXTRA_UDP"
fi

echo
echo "警告：除以上端口外，其他入站端口将被阻止。"
echo

read -r -p "确认继续？请输入 YES： " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "已取消。"
    exit 0
fi

# =========================
# 安装 UFW
# =========================

echo
echo "[1/6] 检查 UFW..."

if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW 未安装，正在安装..."
    apt-get update
    apt-get install -y ufw
fi

# =========================
# 检查 sshd
# =========================

echo
echo "[2/6] 检查 SSH 服务..."

if ! command -v sshd >/dev/null 2>&1; then
    echo "错误：未找到 sshd。"
    echo "请确认已经安装 openssh-server："
    echo
    echo "apt install openssh-server"
    exit 1
fi

# =========================
# 修改 SSH 端口
# =========================

echo
echo "[3/6] 修改 SSH 端口为 ${SSH_PORT}..."

mkdir -p /etc/ssh/sshd_config.d

BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -a /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/" 2>/dev/null || true

cat > "$SSH_DROPIN" <<EOF
# Automatically generated SSH port configuration
Port ${SSH_PORT}
EOF

echo "正在验证 SSH 配置..."

if ! sshd -t; then
    echo
    echo "=================================================="
    echo "错误：SSH 配置验证失败！"
    echo "=================================================="
    echo
    echo "没有继续启动防火墙。"
    echo "SSH 配置备份位于："
    echo "$BACKUP_DIR"
    exit 1
fi

echo "SSH 配置验证通过。"

# =========================
# 配置 UFW
# =========================

echo
echo "[4/6] 配置防火墙..."

# 清空现有 UFW 规则
ufw --force reset

# 默认策略
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow ${SSH_PORT}/tcp comment 'SSH'

# HTTPS
ufw allow 443/tcp comment 'HTTPS'

# 额外 TCP
if [ -n "$EXTRA_TCP" ]; then
    for PORT in $(echo "$EXTRA_TCP" | tr ',' ' '); do

        # 避免重复
        if [ "$PORT" = "$SSH_PORT" ] || [ "$PORT" = "443" ]; then
            continue
        fi

        ufw allow "$PORT/tcp"
    done
fi

# 额外 UDP
if [ -n "$EXTRA_UDP" ]; then
    for PORT in $(echo "$EXTRA_UDP" | tr ',' ' '); do
        ufw allow "$PORT/udp"
    done
fi

# =========================
# 重载 SSH
# =========================

echo
echo "[5/6] 重载 SSH 服务..."

if systemctl reload ssh 2>/dev/null; then
    :
elif systemctl reload sshd 2>/dev/null; then
    :
else
    echo "reload 失败，尝试 restart..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
fi

# 检查119监听
sleep 1

if ! ss -lnt | awk '{print $4}' | grep -Eq ":${SSH_PORT}$"; then
    echo
    echo "=================================================="
    echo "严重警告：没有检测到 SSH 正在监听 ${SSH_PORT}！"
    echo "=================================================="
    echo
    echo "为了防止服务器失联，不启动 UFW。"
    echo
    echo "请检查："
    echo "  ss -lntp | grep ssh"
    echo "  systemctl status ssh"
    echo
    echo "配置备份：$BACKUP_DIR"
    exit 1
fi

echo "检测到 SSH 已监听 ${SSH_PORT}。"

# =========================
# 开启 UFW
# =========================

echo
echo "[6/6] 启用 UFW..."

ufw --force enable

echo
echo "=================================================="
echo " 配置完成"
echo "=================================================="
echo

ufw status numbered

echo
echo "SSH 当前监听："
ss -lntp | grep -E "sshd|:${SSH_PORT}" || true

echo
echo "=================================================="
echo " 新 SSH 连接方式"
echo "=================================================="
echo
echo "ssh -p ${SSH_PORT} 用户名@服务器IP"
echo
echo "例如："
echo "ssh -p ${SSH_PORT} root@1.2.3.4"
echo
echo "重要："
echo "请不要立即关闭当前 SSH 窗口。"
echo "先新开一个终端测试 ${SSH_PORT} 能否正常登录。"
echo
echo "SSH 原配置备份："
echo "$BACKUP_DIR"
echo
