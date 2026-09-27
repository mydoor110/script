#!/bin/bash

# ============================================================
# Debian SSH + UFW 一键安全配置脚本
#
# 功能：
#   - 交互设置 SSH 端口（默认 119）
#   - 默认开放 SSH 新端口 + 443/tcp
#   - 交互添加额外 TCP / UDP 端口
#   - 自动安装 UFW
#   - 检测已有 UFW 规则，不擅自清空
#   - 自动备份 SSH 配置
#   - 兼容 ssh.service / ssh.socket
#   - sshd -t 验证
#   - 确认新 SSH 端口实际监听后才启用 UFW
#   - 出错时尽可能停止在防火墙启用之前
#
# 推荐执行：
# bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup.sh)
# ============================================================

set -u
set -o pipefail

# ------------------------------------------------------------
# 颜色
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

die() {
    error "$*"
    exit 1
}

pause_enter() {
    echo
    echo -n "按回车继续..."
    IFS= read -r _ </dev/tty
}

# ------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行此脚本。"
fi

if [ ! -r /dev/tty ]; then
    die "没有检测到可用交互终端 /dev/tty。请在 SSH 终端中执行。"
fi

if [ ! -f /etc/debian_version ]; then
    warn "没有检测到标准 Debian 环境。"
    warn "此脚本主要针对 Debian 设计。"
    echo
    echo -n "仍然继续？[y/N]: "
    IFS= read -r CONTINUE </dev/tty

    case "$CONTINUE" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------
# 端口验证
# ------------------------------------------------------------

validate_port() {
    local PORT="$1"

    [[ "$PORT" =~ ^[0-9]+$ ]] || return 1

    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# SSH 端口交互
# ------------------------------------------------------------

read_ssh_port() {

    local PORT

    while true; do

        echo
        echo -e "${BOLD}请输入新的 SSH 端口${NC}"
        echo
        echo "合法范围：1 - 65535"
        echo
        echo "示例："
        echo "  119"
        echo "  2222"
        echo "  10022"
        echo
        echo "直接按回车使用默认端口：119"
        echo
        echo -n "SSH 端口 [119]: "

        IFS= read -r PORT </dev/tty

        if [ -z "$PORT" ]; then
            PORT="119"
        fi

        if ! validate_port "$PORT"; then
            echo
            error "无效端口：$PORT"
            echo "请输入 1 - 65535 之间的整数。"
            continue
        fi

        # 不允许常见保留/服务端口
        case "$PORT" in
            53|80|443)
                echo
                warn "端口 $PORT 通常被其他服务使用。"
                echo
                echo -n "确定将它作为 SSH 端口？[y/N]: "
                IFS= read -r CONFIRM_PORT </dev/tty

                case "$CONFIRM_PORT" in
                    y|Y|yes|YES|Yes)
                        ;;
                    *)
                        continue
                        ;;
                esac
                ;;
        esac

        echo "$PORT"
        return
    done
}

# ------------------------------------------------------------
# 附加端口交互
# ------------------------------------------------------------

read_ports() {

    local TYPE="$1"
    local INPUT
    local NORMALIZED
    local PORT
    local INVALID

    while true; do

        echo
        echo -e "${BOLD}请输入额外需要放行的 ${TYPE} 端口${NC}"
        echo
        echo "支持："
        echo
        echo "  单个端口："
        echo "    8080"
        echo
        echo "  多个端口（英文逗号）："
        echo "    80,8080,8443"
        echo
        echo "  多个端口（空格）："
        echo "    80 8080 8443"
        echo
        echo "  没有额外端口："
        echo "    直接按回车"
        echo
        echo -n "额外 ${TYPE} 端口: "

        IFS= read -r INPUT </dev/tty

        if [ -z "$INPUT" ]; then
            echo ""
            return
        fi

        # 检测中文标点
        if echo "$INPUT" | grep -q '[，、；：]'; then
            echo
            error "检测到中文标点。"
            echo
            echo "请使用英文逗号或空格。"
            echo
            echo "正确：80,8080,8443"
            echo "错误：80，8080，8443"
            continue
        fi

        if ! echo "$INPUT" | grep -Eq '^[0-9,[:space:]]+$'; then
            echo
            error "包含非法字符。"
            echo "只能输入数字、英文逗号和空格。"
            continue
        fi

        NORMALIZED=$(echo "$INPUT" | tr ',' ' ' | xargs)

        if [ -z "$NORMALIZED" ]; then
            echo ""
            return
        fi

        INVALID=0

        for PORT in $NORMALIZED; do

            if ! validate_port "$PORT"; then
                INVALID=1
                break
            fi

        done

        if [ "$INVALID" -eq 1 ]; then
            echo
            error "存在无效端口。"
            echo "合法范围：1 - 65535"
            continue
        fi

        # 去重
        echo "$NORMALIZED" \
            | tr ' ' '\n' \
            | awk '!seen[$0]++' \
            | xargs

        return
    done
}

# ------------------------------------------------------------
# 欢迎界面
# ------------------------------------------------------------

clear

echo "============================================================"
echo "              Debian SSH + UFW 安全配置"
echo "============================================================"
echo
echo "本脚本将："
echo
echo "  1. 修改 SSH 监听端口"
echo "  2. 默认开放新的 SSH 端口"
echo "  3. 默认开放 443/tcp"
echo "  4. 可额外开放 TCP / UDP 端口"
echo "  5. 启用 UFW"
echo
echo "在确认 SSH 新端口实际监听之前，不会启用防火墙。"
echo
echo "============================================================"

# ------------------------------------------------------------
# 获取 SSH 端口
# ------------------------------------------------------------

SSH_PORT="$(read_ssh_port | tail -n 1)"

if ! validate_port "$SSH_PORT"; then
    die "SSH 端口读取异常。"
fi

# ------------------------------------------------------------
# 获取其他端口
# ------------------------------------------------------------

EXTRA_TCP="$(read_ports "TCP" | tail -n 1)"
EXTRA_UDP="$(read_ports "UDP" | tail -n 1)"

# ------------------------------------------------------------
# 删除与 SSH/443 重复项
# ------------------------------------------------------------

filter_tcp_ports() {

    local RESULT=""
    local PORT

    for PORT in $EXTRA_TCP; do

        if [ "$PORT" = "$SSH_PORT" ] || [ "$PORT" = "443" ]; then
            continue
        fi

        RESULT="$RESULT $PORT"
    done

    echo "$RESULT" | xargs
}

EXTRA_TCP="$(filter_tcp_ports)"

# ------------------------------------------------------------
# 配置预览
# ------------------------------------------------------------

clear

echo "============================================================"
echo "                      配置预览"
echo "============================================================"
echo
echo "SSH："
echo "  ${SSH_PORT}/tcp"
echo
echo "HTTPS："
echo "  443/tcp"
echo

if [ -n "$EXTRA_TCP" ]; then
    echo "额外 TCP："
    for PORT in $EXTRA_TCP; do
        echo "  ${PORT}/tcp"
    done
else
    echo "额外 TCP：无"
fi

echo

if [ -n "$EXTRA_UDP" ]; then
    echo "额外 UDP："
    for PORT in $EXTRA_UDP; do
        echo "  ${PORT}/udp"
    done
else
    echo "额外 UDP：无"
fi

echo
echo "============================================================"
echo

warn "如果这是云服务器，请先在云厂商安全组中开放："
echo
echo "    TCP ${SSH_PORT}"
echo
echo "否则系统内部配置正确，也可能无法连接。"
echo
echo "AWS / 阿里云 / 腾讯云 / Oracle Cloud 等均可能存在此限制。"
echo

echo -n "确认继续？请输入 yes：[yes/N] "
IFS= read -r CONFIRM </dev/tty

case "$CONFIRM" in
    yes|YES|Yes|y|Y)
        ;;
    *)
        echo
        echo "已取消。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 检查命令
# ------------------------------------------------------------

for CMD in systemctl awk sed grep ss cp mkdir date; do

    if ! command -v "$CMD" >/dev/null 2>&1; then
        die "系统缺少必要命令：$CMD"
    fi

done

# ------------------------------------------------------------
# 检查 OpenSSH
# ------------------------------------------------------------

echo
info "检查 OpenSSH..."

if ! command -v sshd >/dev/null 2>&1; then

    warn "未安装 openssh-server。"

    echo -n "是否自动安装 openssh-server？[Y/n]: "
    IFS= read -r INSTALL_SSH </dev/tty

    case "$INSTALL_SSH" in
        n|N|no|NO)
            die "缺少 openssh-server，无法继续。"
            ;;
    esac

    apt-get update || die "apt update 失败。"
    apt-get install -y openssh-server || die "openssh-server 安装失败。"

fi

ok "OpenSSH 可用。"

# ------------------------------------------------------------
# 安装 UFW
# ------------------------------------------------------------

info "检查 UFW..."

if ! command -v ufw >/dev/null 2>&1; then

    warn "系统没有安装 UFW，正在安装..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update || die "apt update 失败。"
    apt-get install -y ufw || die "UFW 安装失败。"

fi

ok "UFW 可用。"

# ------------------------------------------------------------
# 获取当前 SSH 信息
# ------------------------------------------------------------

CURRENT_SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu | xargs || true)"

info "当前 sshd 配置端口：${CURRENT_SSH_PORTS:-未知}"

# ------------------------------------------------------------
# 检查 UFW 当前状态
# ------------------------------------------------------------

UFW_STATUS="$(ufw status 2>/dev/null | head -n1 || true)"

HAS_UFW_RULES=0

if ufw status 2>/dev/null | grep -Eq 'ALLOW|DENY|REJECT|LIMIT'; then
    HAS_UFW_RULES=1
fi

RESET_UFW=0

if [ "$HAS_UFW_RULES" -eq 1 ]; then

    echo
    warn "检测到现有 UFW 防火墙规则。"
    echo
    ufw status numbered
    echo
    echo "请选择处理方式："
    echo
    echo "  1) 保留现有规则，并添加本次规则（推荐）"
    echo "  2) 清空所有现有 UFW 规则并重新配置"
    echo "  3) 取消"
    echo

    while true; do

        echo -n "请选择 [1/2/3，默认1]: "
        IFS= read -r UFW_ACTION </dev/tty

        [ -z "$UFW_ACTION" ] && UFW_ACTION="1"

        case "$UFW_ACTION" in
            1)
                RESET_UFW=0
                break
                ;;
            2)
                RESET_UFW=1
                break
                ;;
            3)
                echo "已取消。"
                exit 0
                ;;
            *)
                error "请输入 1、2 或 3。"
                ;;
        esac
    done

fi

# ------------------------------------------------------------
# 备份
# ------------------------------------------------------------

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/ssh-ufw-backup-${TIMESTAMP}"

info "创建备份：$BACKUP_DIR"

mkdir -p "$BACKUP_DIR" || die "无法创建备份目录。"

if [ -f /etc/ssh/sshd_config ]; then
    cp -a /etc/ssh/sshd_config "$BACKUP_DIR/"
fi

if [ -d /etc/ssh/sshd_config.d ]; then
    cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/"
fi

if [ -d /etc/systemd/system/ssh.socket.d ]; then
    cp -a /etc/systemd/system/ssh.socket.d \
        "$BACKUP_DIR/ssh.socket.d" 2>/dev/null || true
fi

ufw status numbered >"$BACKUP_DIR/ufw-status.txt" 2>/dev/null || true

ok "备份完成。"

# ------------------------------------------------------------
# 修改 SSH 主配置中的全局 Port
# ------------------------------------------------------------

info "修改 SSH 端口..."

SSHD_CONFIG="/etc/ssh/sshd_config"

if [ ! -f "$SSHD_CONFIG" ]; then
    die "找不到 $SSHD_CONFIG"
fi

# 仅处理 Match 之前的 Port 指令
awk '
BEGIN { in_match=0 }

{
    if ($0 ~ /^[[:space:]]*Match[[:space:]]/) {
        in_match=1
    }

    if (!in_match &&
        $0 ~ /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/) {
        print "# Disabled by SSH-UFW setup: " $0
        next
    }

    print
}
' "$SSHD_CONFIG" >"${SSHD_CONFIG}.tmp" || die "处理 sshd_config 失败。"

mv "${SSHD_CONFIG}.tmp" "$SSHD_CONFIG"

# ------------------------------------------------------------
# 处理 sshd_config.d
# ------------------------------------------------------------

mkdir -p /etc/ssh/sshd_config.d

MANAGED_FILE="/etc/ssh/sshd_config.d/00-custom-ssh-port.conf"

# 注释其他 drop-in 文件中的全局 Port
for FILE in /etc/ssh/sshd_config.d/*.conf; do

    [ -e "$FILE" ] || continue

    if [ "$FILE" = "$MANAGED_FILE" ]; then
        continue
    fi

    awk '
    BEGIN { in_match=0 }

    {
        if ($0 ~ /^[[:space:]]*Match[[:space:]]/) {
            in_match=1
        }

        if (!in_match &&
            $0 ~ /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/) {
            print "# Disabled by SSH-UFW setup: " $0
            next
        }

        print
    }
    ' "$FILE" >"${FILE}.tmp" || die "处理 $FILE 失败。"

    mv "${FILE}.tmp" "$FILE"

done

cat >"$MANAGED_FILE" <<EOF
# Managed by Debian SSH + UFW setup script
Port ${SSH_PORT}
EOF

# ------------------------------------------------------------
# 验证 SSH 配置
# ------------------------------------------------------------

info "验证 sshd 配置..."

if ! sshd -t; then

    error "sshd 配置验证失败。"
    echo
    warn "UFW 尚未启用或修改，因此不会因为本脚本立即失联。"
    echo
    echo "备份位置："
    echo "  $BACKUP_DIR"
    exit 1

fi

ok "sshd -t 验证通过。"

# ------------------------------------------------------------
# 验证 sshd 最终配置端口
# ------------------------------------------------------------

EFFECTIVE_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu | xargs || true)"

if ! echo "$EFFECTIVE_PORTS" | tr ' ' '\n' | grep -qx "$SSH_PORT"; then

    error "sshd 最终配置中没有发现端口 $SSH_PORT。"
    echo
    echo "当前有效端口："
    echo "  ${EFFECTIVE_PORTS:-未知}"
    exit 1

fi

ok "sshd 最终配置包含 ${SSH_PORT}。"

# ------------------------------------------------------------
# 检查 ssh.socket
# ------------------------------------------------------------

SSH_SOCKET_EXISTS=0
SSH_SOCKET_ACTIVE=0

if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    SSH_SOCKET_EXISTS=1
fi

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    SSH_SOCKET_ACTIVE=1
fi

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    info "检测到 ssh.socket 正在运行。"

    mkdir -p /etc/systemd/system/ssh.socket.d

    cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF

    systemctl daemon-reload || die "systemd daemon-reload 失败。"

    ok "ssh.socket 已配置为监听 ${SSH_PORT}。"

fi

# ------------------------------------------------------------
# 配置 UFW 规则
# 注意：先放规则，但暂不 enable
# ------------------------------------------------------------

info "配置 UFW..."

if [ "$RESET_UFW" -eq 1 ]; then

    warn "正在清空现有 UFW 规则..."
    ufw --force reset || die "UFW reset 失败。"

fi

ufw default deny incoming || die "无法设置 UFW 入站策略。"
ufw default allow outgoing || die "无法设置 UFW 出站策略。"

# SSH
ufw allow "${SSH_PORT}/tcp" comment 'SSH' \
    || die "无法添加 SSH 防火墙规则。"

# HTTPS
ufw allow 443/tcp comment 'HTTPS' \
    || die "无法添加 HTTPS 防火墙规则。"

# TCP
if [ -n "$EXTRA_TCP" ]; then

    for PORT in $EXTRA_TCP; do

        ufw allow "${PORT}/tcp" \
            || die "无法添加 TCP ${PORT} 防火墙规则。"

    done

fi

# UDP
if [ -n "$EXTRA_UDP" ]; then

    for PORT in $EXTRA_UDP; do

        ufw allow "${PORT}/udp" \
            || die "无法添加 UDP ${PORT} 防火墙规则。"

    done

fi

ok "UFW 规则已经写入。"

# ------------------------------------------------------------
# 应用 SSH 配置
# ------------------------------------------------------------

info "应用新的 SSH 配置..."

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    # socket 模式
    systemctl stop ssh.socket || die "停止 ssh.socket 失败。"

    # 停掉旧 service/connection
    systemctl stop ssh.service 2>/dev/null || true

    systemctl start ssh.socket || die "启动 ssh.socket 失败。"

else

    # 普通 ssh.service 模式
    if systemctl restart ssh.service 2>/dev/null; then
        :
    elif systemctl restart sshd.service 2>/dev/null; then
        :
    else
        die "SSH 服务重启失败。"
    fi

fi

sleep 2

# ------------------------------------------------------------
# 确认新端口实际监听
# ------------------------------------------------------------

info "确认 TCP ${SSH_PORT} 是否正在监听..."

if ! ss -lnt | awk '{print $4}' | grep -Eq "(^|:|\])${SSH_PORT}$"; then

    echo
    error "没有检测到 TCP ${SSH_PORT} 正在监听。"
    echo
    warn "为避免把服务器锁死，脚本不会启用 UFW。"
    echo
    echo "当前监听："
    ss -lntp 2>/dev/null | grep -E 'ssh|sshd' || true
    echo
    echo "备份："
    echo "  $BACKUP_DIR"
    exit 1

fi

ok "TCP ${SSH_PORT} 已成功监听。"

# ------------------------------------------------------------
# 再确认 SSH socket/service 状态
# ------------------------------------------------------------

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    if ! systemctl is-active --quiet ssh.socket; then
        die "ssh.socket 当前未正常运行。"
    fi

else

    if ! systemctl is-active --quiet ssh.service 2>/dev/null &&
       ! systemctl is-active --quiet sshd.service 2>/dev/null; then

        die "SSH 服务当前未正常运行。"
    fi

fi

# ------------------------------------------------------------
# 启用 UFW
# ------------------------------------------------------------

echo
warn "SSH 新端口已经确认监听。"
echo
info "准备启用 UFW..."

if ! ufw --force enable; then
    die "UFW 启用失败。"
fi

ok "UFW 已启用。"

# ------------------------------------------------------------
# 最终状态
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "${GREEN}${BOLD}                    配置完成${NC}"
echo "============================================================"
echo
echo "SSH 新端口："
echo
echo "    ${SSH_PORT}"
echo
echo "登录示例："
echo
echo "    ssh -p ${SSH_PORT} root@服务器IP"
echo
echo "或："
echo
echo "    ssh -p ${SSH_PORT} 用户名@服务器IP"
echo
echo "------------------------------------------------------------"
echo "UFW 当前状态"
echo "------------------------------------------------------------"
echo

ufw status numbered

echo
echo "------------------------------------------------------------"
echo "SSH 实际监听"
echo "------------------------------------------------------------"
echo

ss -lntp 2>/dev/null | grep -E ":${SSH_PORT}([^0-9]|$)" || \
ss -lnt 2>/dev/null | grep -E ":${SSH_PORT}([^0-9]|$)" || true

echo
echo "------------------------------------------------------------"
echo "SSH 运行模式"
echo "------------------------------------------------------------"
echo

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    echo "    ssh.socket"
else
    echo "    ssh.service"
fi

echo
echo "------------------------------------------------------------"
echo

warn "不要立即关闭当前 SSH 会话。"

echo
echo "请新开一个 SSH 窗口测试："
echo
echo "    ssh -p ${SSH_PORT} 用户名@服务器IP"
echo
echo "确认新连接正常后，再关闭当前会话。"
echo
echo "配置备份："
echo
echo "    ${BACKUP_DIR}"
echo
echo "============================================================"
