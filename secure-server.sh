#!/bin/bash

# ============================================================
# Debian SSH + UFW 一键安全配置脚本
#
# 功能：
#   1. 交互设置 SSH 端口（默认 119）
#   2. 默认开放 SSH 新端口
#   3. 默认开放 443/tcp
#   4. 交互添加额外 TCP / UDP 端口
#   5. 自动安装 OpenSSH Server / UFW（如缺失）
#   6. 自动备份 SSH 配置
#   7. 检测并处理已有 UFW 规则
#   8. 兼容 ssh.service / ssh.socket
#   9. sshd -t 验证配置
#  10. 检查目标 SSH 端口占用
#  11. 确认新 SSH 端口真正监听后才启用 UFW
#  12. SSH 修改失败自动尝试回滚
#
# 推荐运行：
#
# bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup.sh)
#
# ============================================================

set -u
set -o pipefail

# ============================================================
# 颜色
# ============================================================

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

# ============================================================
# 全局变量
# ============================================================

SSH_PORT=""
EXTRA_TCP=""
EXTRA_UDP=""

BACKUP_DIR=""
SSH_SOCKET_ACTIVE=0
SSH_SERVICE_ACTIVE=0

RESET_UFW=0

MANAGED_SSH_FILE="/etc/ssh/sshd_config.d/00-ssh-port-managed.conf"

SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_OVERRIDE_FILE="${SOCKET_OVERRIDE_DIR}/zzzz-ssh-port-managed.conf"

# ============================================================
# ROOT 检查
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo
    error "请使用 root 权限运行此脚本。"
    echo
    echo "例如："
    echo
    echo "sudo bash <(curl -fsSL https://example.com/setup.sh)"
    echo
    exit 1
fi

# ============================================================
# 必须存在交互终端
# ============================================================

if [ ! -r /dev/tty ]; then
    die "当前环境没有可用的交互终端 /dev/tty。请在 SSH 终端内执行。"
fi

# ============================================================
# Debian 检查
# ============================================================

if [ ! -f /etc/debian_version ]; then

    echo
    warn "没有检测到标准 Debian 系统。"
    warn "本脚本主要针对 Debian 设计。"
    echo
    echo -n "仍然继续？[y/N]: "

    IFS= read -r CONTINUE </dev/tty

    case "$CONTINUE" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            echo "已取消。"
            exit 0
            ;;
    esac
fi

# ============================================================
# 端口验证
# ============================================================

validate_port() {

    local PORT="$1"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        return 1
    fi

    return 0
}

# ============================================================
# SSH 端口输入
# ============================================================

read_ssh_port() {

    local PORT
    local CONFIRM_PORT

    while true; do

        echo
        echo -e "${BOLD}请输入新的 SSH 端口${NC}"
        echo
        echo "合法范围：1 - 65535"
        echo
        echo "示例："
        echo
        echo "  119"
        echo "  2222"
        echo "  10022"
        echo
        echo "直接按回车使用默认端口：119"
        echo
        echo -n "SSH 端口 [119]: "

        IFS= read -r PORT </dev/tty

        # 默认 119
        if [ -z "$PORT" ]; then
            PORT="119"
        fi

        # 去除前后空格
        PORT="$(echo "$PORT" | xargs)"

        if ! validate_port "$PORT"; then

            echo
            error "无效端口：$PORT"
            echo
            echo "端口必须是 1 - 65535 之间的整数。"
            continue
        fi

        # 常见服务端口提醒
        case "$PORT" in
            53|80|443)

                echo
                warn "端口 ${PORT} 通常会被其他网络服务使用。"
                echo
                echo -n "确定使用 ${PORT} 作为 SSH 端口？[y/N]: "

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

        SSH_PORT="$PORT"

        return 0
    done
}

# ============================================================
# 额外端口输入
# ============================================================

read_extra_ports() {

    local TYPE="$1"
    local INPUT
    local NORMALIZED
    local PORT
    local INVALID
    local RESULT

    while true; do

        echo
        echo -e "${BOLD}请输入额外需要放行的 ${TYPE} 端口${NC}"
        echo
        echo "输入示例："
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

        # 空输入
        if [ -z "$INPUT" ]; then

            if [ "$TYPE" = "TCP" ]; then
                EXTRA_TCP=""
            else
                EXTRA_UDP=""
            fi

            return 0
        fi

        # 防止中文标点
        if echo "$INPUT" | grep -q '[，、；：]'; then

            echo
            error "检测到中文标点。"
            echo
            echo "请使用英文逗号 , 或空格分隔。"
            echo
            echo "正确："
            echo "  80,8080,8443"
            echo
            echo "错误："
            echo "  80，8080，8443"

            continue
        fi

        # 仅允许数字、英文逗号和空白
        if ! echo "$INPUT" | grep -Eq '^[0-9,[:space:]]+$'; then

            echo
            error "输入包含非法字符。"
            echo
            echo "只能输入："
            echo "  数字"
            echo "  英文逗号"
            echo "  空格"

            continue
        fi

        # 英文逗号转换成空格
        NORMALIZED="$(echo "$INPUT" | tr ',' ' ' | xargs)"

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
            echo
            echo "合法端口范围：1 - 65535"

            continue
        fi

        # 去重
        RESULT="$(
            echo "$NORMALIZED" |
            tr ' ' '\n' |
            awk 'NF && !seen[$0]++' |
            xargs
        )"

        if [ "$TYPE" = "TCP" ]; then
            EXTRA_TCP="$RESULT"
        else
            EXTRA_UDP="$RESULT"
        fi

        return 0
    done
}

# ============================================================
# 删除 TCP 中与 SSH / 443 重复的端口
# ============================================================

filter_extra_tcp() {

    local RESULT=""
    local PORT

    for PORT in $EXTRA_TCP; do

        if [ "$PORT" = "$SSH_PORT" ]; then
            continue
        fi

        if [ "$PORT" = "443" ]; then
            continue
        fi

        RESULT="$RESULT $PORT"
    done

    EXTRA_TCP="$(echo "$RESULT" | xargs)"
}

# ============================================================
# 欢迎界面
# ============================================================

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

# ============================================================
# 用户输入
# ============================================================

read_ssh_port
read_extra_ports "TCP"
read_extra_ports "UDP"

filter_extra_tcp

# ============================================================
# 配置预览
# ============================================================

clear

echo "============================================================"
echo "                     配置预览"
echo "============================================================"
echo
echo "SSH："
echo
echo "  ${SSH_PORT}/tcp"
echo
echo "HTTPS："
echo
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
warn "如果使用云服务器，请先在云平台安全组中开放 TCP ${SSH_PORT}。"
echo
echo "例如："
echo
echo "  AWS Security Group"
echo "  AWS Lightsail Firewall"
echo "  阿里云安全组"
echo "  腾讯云安全组"
echo "  Oracle Cloud Security List"
echo
echo "云平台外层防火墙不受本脚本控制。"
echo
echo -n "确认开始配置？请输入 yes：[yes/N] "

IFS= read -r CONFIRM </dev/tty

case "$CONFIRM" in
    y|Y|yes|YES|Yes)
        ;;
    *)
        echo
        echo "已取消。"
        exit 0
        ;;
esac

# ============================================================
# 检查基础命令
# ============================================================

echo
info "检查系统环境..."

for CMD in \
    awk \
    sed \
    grep \
    ss \
    cp \
    mv \
    mkdir \
    date \
    systemctl \
    xargs
do

    if ! command -v "$CMD" >/dev/null 2>&1; then
        die "缺少必要命令：${CMD}"
    fi

done

ok "基础环境正常。"

# ============================================================
# 检查 OpenSSH Server
# ============================================================

info "检查 OpenSSH Server..."

if ! command -v sshd >/dev/null 2>&1; then

    warn "系统没有安装 openssh-server。"
    echo
    echo -n "是否自动安装？[Y/n]: "

    IFS= read -r INSTALL_SSH </dev/tty

    case "$INSTALL_SSH" in
        n|N|no|NO|No)
            die "没有 openssh-server，无法继续。"
            ;;
    esac

    export DEBIAN_FRONTEND=noninteractive

    apt-get update || die "apt update 失败。"

    apt-get install -y openssh-server \
        || die "openssh-server 安装失败。"
fi

ok "OpenSSH Server 可用。"

# ============================================================
# 获取当前 SSH 配置
# ============================================================

CURRENT_SSH_PORTS="$(
    sshd -T 2>/dev/null |
    awk '$1=="port"{print $2}' |
    sort -nu |
    xargs
)"

if [ -n "$CURRENT_SSH_PORTS" ]; then

    info "当前 sshd 配置端口：${CURRENT_SSH_PORTS}"

else

    warn "无法读取当前 sshd Port 配置。"

fi

# ============================================================
# 判断运行模式
# ============================================================

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    SSH_SOCKET_ACTIVE=1
fi

if systemctl is-active --quiet ssh.service 2>/dev/null ||
   systemctl is-active --quiet sshd.service 2>/dev/null; then
    SSH_SERVICE_ACTIVE=1
fi

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    info "检测到 SSH 运行模式：ssh.socket"

else

    info "检测到 SSH 运行模式：ssh.service"

fi

# ============================================================
# 检查目标端口当前占用
# ============================================================

info "检查 TCP ${SSH_PORT} 是否已被占用..."

PORT_LISTENER="$(
    ss -ltnpH "sport = :${SSH_PORT}" 2>/dev/null || true
)"

if [ -n "$PORT_LISTENER" ]; then

    echo
    warn "TCP ${SSH_PORT} 当前已经存在监听程序："
    echo
    echo "$PORT_LISTENER"
    echo

    # 如果本来 SSH 就配置在这个端口，允许继续
    CURRENT_CONTAINS_PORT=0

    for PORT in $CURRENT_SSH_PORTS; do

        if [ "$PORT" = "$SSH_PORT" ]; then
            CURRENT_CONTAINS_PORT=1
            break
        fi

    done

    if [ "$CURRENT_CONTAINS_PORT" -eq 0 ]; then

        warn "无法确认该端口属于当前 SSH 服务。"
        echo
        echo "继续可能造成端口冲突。"
        echo
        echo -n "确认该端口可以用于 SSH？[y/N]: "

        IFS= read -r PORT_CONFIRM </dev/tty

        case "$PORT_CONFIRM" in
            y|Y|yes|YES|Yes)
                ;;
            *)
                die "为安全起见已停止执行，请选择其他 SSH 端口。"
                ;;
        esac

    fi

else

    ok "TCP ${SSH_PORT} 当前未被其他程序监听。"

fi

# ============================================================
# 安装 UFW
# ============================================================

info "检查 UFW..."

if ! command -v ufw >/dev/null 2>&1; then

    warn "系统没有安装 UFW，正在安装..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update || die "apt update 失败。"

    apt-get install -y ufw \
        || die "UFW 安装失败。"

fi

ok "UFW 可用。"

# ============================================================
# 检查已有 UFW 规则
# ============================================================

EXISTING_UFW_RULES="$(
    ufw show added 2>/dev/null |
    grep '^ufw ' ||
    true
)"

if [ -n "$EXISTING_UFW_RULES" ]; then

    echo
    warn "检测到服务器已有 UFW 规则："
    echo
    echo "$EXISTING_UFW_RULES"
    echo
    echo "请选择："
    echo
    echo "  1) 保留现有规则，在其基础上添加本次规则"
    echo
    echo "  2) 清空现有 UFW 规则，只保留本次设置的端口"
    echo
    echo "  3) 取消"
    echo

    while true; do

        echo -n "请选择 [1/2/3，默认 1]: "

        IFS= read -r UFW_ACTION </dev/tty

        if [ -z "$UFW_ACTION" ]; then
            UFW_ACTION="1"
        fi

        case "$UFW_ACTION" in

            1)
                RESET_UFW=0
                break
                ;;

            2)
                echo
                warn "清空后，原有 UFW 规则都会删除。"
                echo
                echo -n "确定清空？请输入 RESET：[RESET/N] "

                IFS= read -r RESET_CONFIRM </dev/tty

                if [ "$RESET_CONFIRM" = "RESET" ]; then

                    RESET_UFW=1
                    break

                else

                    echo "已取消清空。"
                    UFW_ACTION="1"
                    RESET_UFW=0
                    break

                fi
                ;;

            3)
                echo
                echo "已取消。"
                exit 0
                ;;

            *)
                error "请输入 1、2 或 3。"
                ;;

        esac

    done

fi

# ============================================================
# 创建备份目录
# ============================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

BACKUP_DIR="/root/ssh-ufw-backup-${TIMESTAMP}"

info "创建配置备份..."

mkdir -p "$BACKUP_DIR" \
    || die "无法创建备份目录。"

# SSH 主配置
if [ -f /etc/ssh/sshd_config ]; then

    cp -a \
        /etc/ssh/sshd_config \
        "$BACKUP_DIR/sshd_config"

fi

# SSH drop-in
if [ -d /etc/ssh/sshd_config.d ]; then

    cp -a \
        /etc/ssh/sshd_config.d \
        "$BACKUP_DIR/sshd_config.d"

    touch "$BACKUP_DIR/had_sshd_config_d"

fi

# ssh.socket drop-in
if [ -d "$SOCKET_OVERRIDE_DIR" ]; then

    cp -a \
        "$SOCKET_OVERRIDE_DIR" \
        "$BACKUP_DIR/ssh.socket.d"

    touch "$BACKUP_DIR/had_ssh_socket_d"

fi

# UFW
ufw status numbered \
    >"$BACKUP_DIR/ufw-status.txt" \
    2>/dev/null || true

ufw show added \
    >"$BACKUP_DIR/ufw-added.txt" \
    2>/dev/null || true

ok "备份完成：${BACKUP_DIR}"

# ============================================================
# SSH 回滚函数
# ============================================================

rollback_ssh() {

    echo
    warn "正在尝试恢复修改前的 SSH 配置..."

    if [ -f "$BACKUP_DIR/sshd_config" ]; then

        cp -a \
            "$BACKUP_DIR/sshd_config" \
            /etc/ssh/sshd_config

    fi

    rm -rf /etc/ssh/sshd_config.d

    if [ -f "$BACKUP_DIR/had_sshd_config_d" ]; then

        cp -a \
            "$BACKUP_DIR/sshd_config.d" \
            /etc/ssh/sshd_config.d

    else

        mkdir -p /etc/ssh/sshd_config.d

    fi

    # 恢复 ssh.socket drop-in
    rm -rf "$SOCKET_OVERRIDE_DIR"

    if [ -f "$BACKUP_DIR/had_ssh_socket_d" ]; then

        cp -a \
            "$BACKUP_DIR/ssh.socket.d" \
            "$SOCKET_OVERRIDE_DIR"

    fi

    systemctl daemon-reload 2>/dev/null || true

    # 尝试恢复 SSH
    if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

        systemctl restart ssh.socket 2>/dev/null || true

    else

        systemctl reload ssh.service 2>/dev/null ||
        systemctl restart ssh.service 2>/dev/null ||
        systemctl restart sshd.service 2>/dev/null ||
        true

    fi

    warn "SSH 配置回滚操作已执行。"
    echo
    echo "备份目录："
    echo
    echo "  ${BACKUP_DIR}"
}

# ============================================================
# 修改 sshd_config
# ============================================================

info "修改 SSH Port 配置..."

if [ ! -f /etc/ssh/sshd_config ]; then

    die "找不到 /etc/ssh/sshd_config"

fi

# ------------------------------------------------------------
# 注释主配置 Match 之前的 Port
# ------------------------------------------------------------

awk '
BEGIN {
    in_match = 0
}

{
    first = tolower($1)

    if (first == "match") {
        in_match = 1
    }

    if (!in_match && first == "port") {

        print "# Disabled by SSH-UFW setup: " $0
        next
    }

    print
}
' /etc/ssh/sshd_config \
> /etc/ssh/sshd_config.tmp

if [ $? -ne 0 ]; then

    rm -f /etc/ssh/sshd_config.tmp
    rollback_ssh
    die "处理 sshd_config 失败。"

fi

mv \
    /etc/ssh/sshd_config.tmp \
    /etc/ssh/sshd_config

# ============================================================
# 修改 sshd_config.d
# ============================================================

mkdir -p /etc/ssh/sshd_config.d

for FILE in /etc/ssh/sshd_config.d/*.conf; do

    [ -e "$FILE" ] || continue

    if [ "$FILE" = "$MANAGED_SSH_FILE" ]; then
        continue
    fi

    awk '
    BEGIN {
        in_match = 0
    }

    {
        first = tolower($1)

        if (first == "match") {
            in_match = 1
        }

        if (!in_match && first == "port") {

            print "# Disabled by SSH-UFW setup: " $0
            next
        }

        print
    }
    ' "$FILE" >"${FILE}.tmp"

    if [ $? -ne 0 ]; then

        rm -f "${FILE}.tmp"

        rollback_ssh

        die "处理 ${FILE} 失败。"

    fi

    mv "${FILE}.tmp" "$FILE"

done

# ============================================================
# 写入唯一的 SSH Port
# ============================================================

cat >"$MANAGED_SSH_FILE" <<EOF
# ============================================================
# Managed by Debian SSH + UFW setup script
# ============================================================

Port ${SSH_PORT}
EOF

# ============================================================
# sshd 配置语法检查
# ============================================================

info "执行 sshd -t 配置检查..."

if ! sshd -t; then

    error "新的 SSH 配置验证失败。"

    rollback_ssh

    die "已停止执行，UFW 不会因为本次操作被启用。"

fi

ok "sshd -t 验证通过。"

# ============================================================
# 检查最终 sshd Port
# ============================================================

EFFECTIVE_PORTS="$(
    sshd -T 2>/dev/null |
    awk '$1=="port"{print $2}' |
    sort -nu |
    xargs
)"

if [ -z "$EFFECTIVE_PORTS" ]; then

    rollback_ssh

    die "无法读取 sshd 最终有效端口。"

fi

PORT_COUNT="$(
    echo "$EFFECTIVE_PORTS" |
    tr ' ' '\n' |
    awk 'NF' |
    wc -l
)"

if [ "$PORT_COUNT" -ne 1 ] ||
   [ "$EFFECTIVE_PORTS" != "$SSH_PORT" ]; then

    echo
    error "SSH 最终有效 Port 不符合预期。"
    echo
    echo "目标端口："
    echo
    echo "  ${SSH_PORT}"
    echo
    echo "实际检测到："
    echo
    echo "  ${EFFECTIVE_PORTS}"
    echo
    warn "可能存在其他 Include 文件定义了额外 Port。"

    rollback_ssh

    die "为防止意外开放多个 SSH 端口，已停止。"

fi

ok "SSH 最终有效端口确认：${SSH_PORT}"

# ============================================================
# ssh.socket 模式
# ============================================================

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    info "配置 ssh.socket ListenStream..."

    mkdir -p "$SOCKET_OVERRIDE_DIR"

    cat >"$SOCKET_OVERRIDE_FILE" <<EOF
[Socket]

# 清除原有 ListenStream
ListenStream=

# 新 SSH 端口
ListenStream=${SSH_PORT}
EOF

    if ! systemctl daemon-reload; then

        rollback_ssh

        die "systemd daemon-reload 失败。"

    fi

    ok "ssh.socket 已配置为 TCP ${SSH_PORT}。"

fi

# ============================================================
# UFW
# ============================================================

info "配置 UFW..."

# ------------------------------------------------------------
# 是否重置
# ------------------------------------------------------------

if [ "$RESET_UFW" -eq 1 ]; then

    warn "正在重置 UFW..."

    if ! ufw --force reset; then

        rollback_ssh

        die "UFW reset 失败。"

    fi

fi

# ============================================================
# 第一优先级：SSH
#
# 如果保留旧规则，使用 insert 1，
# 防止已有规则排在 SSH allow 前面。
# ============================================================

if [ "$RESET_UFW" -eq 0 ] &&
   [ -n "$EXISTING_UFW_RULES" ]; then

    ufw insert 1 allow "${SSH_PORT}/tcp" comment 'SSH-Managed' \
        || {
            rollback_ssh
            die "无法添加 SSH UFW 规则。"
        }

else

    ufw allow "${SSH_PORT}/tcp" comment 'SSH-Managed' \
        || {
            rollback_ssh
            die "无法添加 SSH UFW 规则。"
        }

fi

# ============================================================
# HTTPS
# ============================================================

ufw allow 443/tcp comment 'HTTPS' \
    || {
        rollback_ssh
        die "无法添加 443/tcp。"
    }

# ============================================================
# 额外 TCP
# ============================================================

if [ -n "$EXTRA_TCP" ]; then

    for PORT in $EXTRA_TCP; do

        ufw allow "${PORT}/tcp" \
            || {
                rollback_ssh
                die "无法添加 ${PORT}/tcp。"
            }

    done

fi

# ============================================================
# 额外 UDP
# ============================================================

if [ -n "$EXTRA_UDP" ]; then

    for PORT in $EXTRA_UDP; do

        ufw allow "${PORT}/udp" \
            || {
                rollback_ssh
                die "无法添加 ${PORT}/udp。"
            }

    done

fi

# ============================================================
# 默认策略
# ============================================================

ufw default deny incoming \
    || {
        rollback_ssh
        die "无法设置默认入站策略。"
    }

ufw default allow outgoing \
    || {
        rollback_ssh
        die "无法设置默认出站策略。"
    }

ok "UFW 规则配置完成。"

# ============================================================
# 应用 SSH 配置
# ============================================================

echo
info "应用新的 SSH 配置..."

# ------------------------------------------------------------
# ssh.socket
# ------------------------------------------------------------

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    if ! systemctl restart ssh.socket; then

        rollback_ssh

        die "ssh.socket 重启失败。"

    fi

# ------------------------------------------------------------
# 普通 ssh.service
# ------------------------------------------------------------

else

    # 优先 reload，尽量不影响现有 SSH 会话
    if systemctl reload ssh.service 2>/dev/null; then

        :

    elif systemctl reload sshd.service 2>/dev/null; then

        :

    elif systemctl restart ssh.service 2>/dev/null; then

        :

    elif systemctl restart sshd.service 2>/dev/null; then

        :

    else

        rollback_ssh

        die "SSH 服务无法重新加载或重启。"

    fi

fi

sleep 2

# ============================================================
# 检查 SSH 新端口实际监听
# ============================================================

info "检查 TCP ${SSH_PORT} 实际监听状态..."

NEW_LISTENER="$(
    ss -ltnpH "sport = :${SSH_PORT}" 2>/dev/null ||
    true
)"

if [ -z "$NEW_LISTENER" ]; then

    echo
    error "TCP ${SSH_PORT} 没有监听。"
    echo
    warn "为防止服务器失联，不会继续启用 UFW。"

    rollback_ssh

    die "SSH 新端口启动失败。"

fi

ok "TCP ${SSH_PORT} 已开始监听。"

echo
echo "$NEW_LISTENER"
echo

# ============================================================
# 再检查 SSH 服务状态
# ============================================================

if [ "$SSH_SOCKET_ACTIVE" -eq 1 ]; then

    if ! systemctl is-active --quiet ssh.socket; then

        rollback_ssh

        die "ssh.socket 当前未正常运行。"

    fi

else

    if ! systemctl is-active --quiet ssh.service 2>/dev/null &&
       ! systemctl is-active --quiet sshd.service 2>/dev/null; then

        rollback_ssh

        die "SSH 服务当前未正常运行。"

    fi

fi

# ============================================================
# 最终 SSH 配置再次检查
# ============================================================

if ! sshd -t; then

    rollback_ssh

    die "最终 sshd 配置检查失败。"

fi

# ============================================================
# 启用 UFW
# ============================================================

echo
info "SSH 新端口检查成功。"
info "准备启用 UFW..."

if ! ufw --force enable; then

    error "UFW 启用失败。"
    echo
    warn "SSH 已修改为 ${SSH_PORT}，但 UFW 没有成功启用。"
    echo
    echo "SSH 配置不会自动回滚，因为新端口已经确认正常监听。"
    exit 1

fi

ok "UFW 已启用。"

# ============================================================
# 最终检查
# ============================================================

sleep 1

UFW_FINAL_STATUS="$(ufw status 2>/dev/null | head -n1 || true)"

if ! echo "$UFW_FINAL_STATUS" | grep -qi "active"; then

    warn "UFW 状态检测异常："
    echo
    echo "$UFW_FINAL_STATUS"

fi

# ============================================================
# 完成界面
# ============================================================

echo
echo "============================================================"
echo -e "${GREEN}${BOLD}                    配置完成${NC}"
echo "============================================================"
echo
echo "SSH 新端口："
echo
echo "  ${SSH_PORT}/tcp"
echo
echo "新的 SSH 登录命令："
echo
echo "  ssh -p ${SSH_PORT} 用户名@服务器IP"
echo
echo "例如："
echo
echo "  ssh -p ${SSH_PORT} root@1.2.3.4"
echo
echo "============================================================"
echo "UFW 当前规则"
echo "============================================================"
echo

ufw status numbered

echo
echo "============================================================"
echo "SSH 当前监听"
echo "============================================================"
echo

ss -ltnpH "sport = :${SSH_PORT}" 2>/dev/null || true

echo
echo "============================================================"
echo "SSH 运行模式"
echo "============================================================"
echo

if systemctl is-active --quiet ssh.socket 2>/dev/null; then

    echo "  ssh.socket"

else

    echo "  ssh.service"

fi

echo
echo "============================================================"
echo "配置备份"
echo "============================================================"
echo
echo "  ${BACKUP_DIR}"
echo
echo "============================================================"
echo

warn "重要：现在不要关闭当前 SSH 会话！"

echo
echo "请重新打开一个 SSH 客户端窗口测试："
echo
echo "  ssh -p ${SSH_PORT} 用户名@服务器IP"
echo
echo "确认新 SSH 窗口可以正常登录后，"
echo "再关闭当前 SSH 会话。"
echo

warn "如果外部无法连接，请优先检查云服务器安全组是否放行 TCP ${SSH_PORT}。"

echo
echo "============================================================"
