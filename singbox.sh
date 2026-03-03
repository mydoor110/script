#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sing-box 一键脚本（安装/升级/卸载 + 配置闭环 + 服务管理）
# 官方来源：GitHub Releases (SagerNet/sing-box)
# ============================================================

REPO="SagerNet/sing-box"
BIN_NAME="sing-box"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${BIN_NAME}"

SERVICE_NAME="sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"

STATE_DIR="/var/lib/sing-box"
LOG_DIR="/var/log/sing-box"

RUN_USER="singbox"
RUN_GROUP="singbox"

USE_SUDO=1
DOWNLOAD_TOOL=""

# ------------------ 输出样式 ------------------
c_green="\033[32m"; c_yellow="\033[33m"; c_red="\033[31m"; c_blue="\033[34m"; c_reset="\033[0m"
ok()   { echo -e "${c_green}[OK]${c_reset} $*"; }
info() { echo -e "${c_blue}[信息]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[警告]${c_reset} $*"; }
fail() { echo -e "${c_red}[错误]${c_reset} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

pause() { read -rp "按回车继续..." _; }

sudo_cmd() {
  if [[ $USE_SUDO -eq 1 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      fail "系统没有 sudo。请用 root 执行或安装 sudo。"
    fi
  else
    "$@"
  fi
}

# ------------------ 下载器 ------------------
pick_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_TOOL="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_TOOL="wget"
  else
    fail "需要 curl 或 wget 其中之一"
  fi
}

fetch() {
  local url="$1" out="$2"
  if [[ "$DOWNLOAD_TOOL" == "curl" ]]; then
    curl -fsSL "$url" -o "$out"
  else
    wget -qO "$out" "$url"
  fi
}

# ------------------ 架构识别 ------------------
detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    riscv64) echo "riscv64" ;;
    *) fail "不支持的架构：$m" ;;
  esac
}

# ------------------ GitHub API ------------------
github_api_release_url() {
  local mode="$1" ver="${2:-}"
  case "$mode" in
    latest) echo "https://api.github.com/repos/${REPO}/releases/latest" ;;
    version) ver="${ver#v}"; echo "https://api.github.com/repos/${REPO}/releases/tags/v${ver}" ;;
    beta) echo "https://api.github.com/repos/${REPO}/releases?per_page=20" ;;
    *) fail "内部参数错误：mode=${mode}" ;;
  esac
}

json_get_tag() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tag_name' "$json"
  else
    grep -m1 '"tag_name"' "$json" | sed -E 's/.*"tag_name"\s*:\s*"([^"]+)".*/\1/'
  fi
}

json_find_asset_url() {
  local json="$1" name="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg n "$name" '.assets[] | select(.name==$n) | .browser_download_url' "$json" | head -n1
  else
    awk -v n="\"name\": \"${name}\"" '
      $0 ~ n {found=1}
      found && $0 ~ /"browser_download_url"/ {
        match($0, /"browser_download_url": "([^"]+)"/, a); print a[1]; exit
      }' "$json"
  fi
}

pick_beta_first_release_object() {
  local in="$1" out="$2"
  if command -v jq >/dev/null 2>&1; then
    jq '.[0]' "$in" > "$out"
  else
    awk 'BEGIN{lvl=0;start=0}
      {
        if($0 ~ /^{/ && start==0){start=1}
        if(start==1){
          print
          lvl += gsub(/{/,"{") - gsub(/}/,"}")
          if(lvl==0){exit}
        }
      }' "$in" > "$out" || true
    [[ -s "$out" ]] || fail "解析 beta 版本失败：建议安装 jq 或改用“指定版本/最新稳定”"
  fi
}

# ------------------ systemd service ------------------
write_systemd_service() {
  sudo_cmd mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"

  # 创建运行用户
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    info "创建系统用户：${RUN_USER}"
    sudo_cmd useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi

  sudo_cmd chown -R "${RUN_USER}:${RUN_GROUP}" "$CONF_DIR" "$STATE_DIR" "$LOG_DIR" || true

  info "写入 systemd 服务：${SERVICE_FILE}"
  sudo_cmd tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=2

AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CONF_DIR} ${STATE_DIR} ${LOG_DIR}

StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  sudo_cmd systemctl daemon-reload
}

ensure_default_config() {
  if [[ -f "$CONF_FILE" ]]; then
    ok "已存在配置文件：${CONF_FILE}（不会覆盖）"
    return 0
  fi

  warn "未发现配置文件，将创建占位配置：${CONF_FILE}"
  warn "请编辑为可用配置后再“应用配置并重启”。"
  sudo_cmd mkdir -p "$CONF_DIR"
  sudo_cmd tee "$CONF_FILE" >/dev/null <<'EOF'
{
  "log": { "level": "info" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  sudo_cmd chown "${RUN_USER}:${RUN_GROUP}" "$CONF_FILE" || true
  sudo_cmd chmod 600 "$CONF_FILE" || true
}

# ------------------ 二进制安装/升级 ------------------
download_and_install_binary() {
  local mode="$1" ver="${2:-}"
  local arch tmpdir json json2 tag asset url tarball extracted_bin

  arch="$(detect_arch)"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  json="$tmpdir/release.json"
  info "获取发行信息..."
  fetch "$(github_api_release_url "$mode" "$ver")" "$json"

  if [[ "$mode" == "beta" ]]; then
    json2="$tmpdir/release_one.json"
    pick_beta_first_release_object "$json" "$json2"
    json="$json2"
  fi

  tag="$(json_get_tag "$json")"
  [[ -n "$tag" && "$tag" != "null" ]] || fail "获取版本号失败（建议安装 jq 或稍后重试）"

  asset="sing-box-linux-${arch}.tar.gz"
  url="$(json_find_asset_url "$json" "$asset")"
  [[ -n "$url" && "$url" != "null" ]] || fail "未找到对应架构安装包：${asset}（release：${tag}）"

  info "版本：${tag}"
  info "架构：${arch}"
  info "下载：${asset}"
  tarball="$tmpdir/$asset"
  fetch "$url" "$tarball"

  info "解压..."
  tar -xzf "$tarball" -C "$tmpdir"

  extracted_bin="$(find "$tmpdir" -maxdepth 3 -type f -name "$BIN_NAME" -perm -u+x | head -n1 || true)"
  [[ -n "$extracted_bin" ]] || fail "解压后未找到 ${BIN_NAME} 可执行文件"

  if [[ -f "$BIN_PATH" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    sudo_cmd cp -a "$BIN_PATH" "${BIN_PATH}.bak.${ts}"
    warn "已备份旧版本：${BIN_PATH}.bak.${ts}"
  fi

  sudo_cmd mkdir -p "$INSTALL_DIR"
  sudo_cmd install -m 755 "$extracted_bin" "$BIN_PATH"
  ok "已安装二进制：${BIN_PATH}"
  "$BIN_PATH" version || true
}

# ------------------ 服务管理 ------------------
service_exists() {
  sudo_cmd systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"
}

service_status() {
  echo
  if service_exists; then
    sudo_cmd systemctl status "$SERVICE_NAME" --no-pager || true
  else
    warn "未发现服务：${SERVICE_NAME}"
  fi
  echo
}

service_start() {
  service_exists || fail "未安装服务，请先安装。"
  sudo_cmd systemctl start "$SERVICE_NAME"
  ok "已启动服务"
}

service_stop() {
  service_exists || fail "未安装服务，请先安装。"
  sudo_cmd systemctl stop "$SERVICE_NAME" || true
  ok "已停止服务"
}

service_restart() {
  service_exists || fail "未安装服务，请先安装。"
  sudo_cmd systemctl restart "$SERVICE_NAME"
  ok "已重启服务"
}

service_enable() {
  service_exists || fail "未安装服务，请先安装。"
  sudo_cmd systemctl enable "$SERVICE_NAME" >/dev/null || true
  ok "已设置开机自启"
}

service_disable() {
  service_exists || fail "未安装服务，请先安装。"
  sudo_cmd systemctl disable "$SERVICE_NAME" >/dev/null || true
  ok "已取消开机自启"
}

service_logs_follow() {
  service_exists || fail "未安装服务，请先安装。"
  info "按 Ctrl+C 退出日志查看"
  sudo_cmd journalctl -u "$SERVICE_NAME" -f
}

# ------------------ 配置闭环：编辑/校验/应用 ------------------
pick_editor() {
  if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
    echo "$EDITOR"; return 0
  fi
  for e in nano vim vi; do
    if command -v "$e" >/dev/null 2>&1; then echo "$e"; return 0; fi
  done
  fail "未找到可用编辑器（nano/vim/vi）。请先安装一个或设置 EDITOR 环境变量。"
}

config_edit() {
  sudo_cmd mkdir -p "$CONF_DIR"
  ensure_default_config

  local editor; editor="$(pick_editor)"
  info "使用编辑器：$editor"
  info "正在打开：${CONF_FILE}"
  sudo_cmd "$editor" "$CONF_FILE"
  ok "已退出编辑器"
}

config_check() {
  [[ -x "$BIN_PATH" ]] || fail "未安装二进制：${BIN_PATH}"
  [[ -f "$CONF_FILE" ]] || fail "未发现配置文件：${CONF_FILE}"

  info "校验配置文件：${CONF_FILE}"
  if "$BIN_PATH" check -c "$CONF_FILE"; then
    ok "配置校验通过"
    return 0
  else
    warn "配置校验失败（请根据输出修正配置）"
    return 1
  fi
}

config_apply_restart() {
  config_check || { warn "校验未通过，已取消应用"; return 1; }
  service_exists || { warn "服务尚未安装，将仅校验配置"; return 0; }

  info "应用配置：重启服务使配置生效..."
  sudo_cmd systemctl restart "$SERVICE_NAME"
  if sudo_cmd systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "已重启且服务运行正常"
  else
    warn "重启后服务未运行，请查看日志：journalctl -u ${SERVICE_NAME} -n 200 --no-pager"
  fi
}

# ------------------ 流程：安装/升级/卸载 ------------------
install_or_upgrade_flow() {
  local mode="$1" ver="${2:-}"
  download_and_install_binary "$mode" "$ver"
  write_systemd_service
  ensure_default_config

  service_enable
  info "尝试启动/重启服务..."
  if sudo_cmd systemctl is-active --quiet "$SERVICE_NAME"; then
    sudo_cmd systemctl restart "$SERVICE_NAME"
  else
    sudo_cmd systemctl start "$SERVICE_NAME" || true
  fi

  if sudo_cmd systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务已运行"
  else
    warn "服务未能正常运行，建议：进入“配置管理”->“编辑配置”->“校验并应用”"
  fi
}

uninstall_flow() {
  warn "将卸载 sing-box（停止服务、删除二进制与 systemd 服务）"
  read -rp "确认继续卸载？(y/N)： " yn
  [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }

  if service_exists; then
    info "停止并禁用服务..."
    sudo_cmd systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo_cmd systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    info "删除服务文件：${SERVICE_FILE}"
    sudo_cmd rm -f "$SERVICE_FILE"
    sudo_cmd systemctl daemon-reload
  fi

  if [[ -f "$BIN_PATH" ]]; then
    info "删除二进制：${BIN_PATH}"
    sudo_cmd rm -f "$BIN_PATH"
  fi

  read -rp "是否删除配置/数据目录（${CONF_DIR} ${STATE_DIR} ${LOG_DIR}）？(y/N)： " delconf
  if [[ "${delconf:-N}" =~ ^[Yy]$ ]]; then
    sudo_cmd rm -rf "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
    ok "已删除配置/数据目录"
  else
    info "保留配置/数据目录"
  fi

  read -rp "是否删除系统用户 ${RUN_USER}？(y/N)： " deluser
  if [[ "${deluser:-N}" =~ ^[Yy]$ ]]; then
    if id -u "$RUN_USER" >/dev/null 2>&1; then
      sudo_cmd userdel "$RUN_USER" >/dev/null 2>&1 || true
      ok "已删除用户：${RUN_USER}"
    fi
  else
    info "保留系统用户"
  fi

  ok "卸载完成"
}

# ------------------ 状态展示 ------------------
show_status() {
  echo
  info "当前状态概览："
  if [[ -x "$BIN_PATH" ]]; then
    ok "二进制：${BIN_PATH}"
    "$BIN_PATH" version || true
  else
    warn "未安装二进制：${BIN_PATH}"
  fi

  if service_exists; then
    if sudo_cmd systemctl is-active --quiet "$SERVICE_NAME"; then
      ok "服务：${SERVICE_NAME}（运行中）"
    else
      warn "服务：${SERVICE_NAME}（未运行）"
    fi
  else
    warn "未发现 systemd 服务：${SERVICE_NAME}"
  fi

  if [[ -f "$CONF_FILE" ]]; then
    ok "配置：${CONF_FILE}"
  else
    warn "未发现配置文件：${CONF_FILE}"
  fi
  echo
}

# ------------------ 菜单 ------------------
menu_main() {
  echo "=================================================="
  echo " sing-box 一键脚本（安装/升级/卸载/配置/服务管理）"
  echo "=================================================="
  echo "1) 安装/升级（最新稳定）"
  echo "2) 安装/升级（指定版本）"
  echo "3) 安装/升级（最新 Beta/预发布）"
  echo "4) 配置管理（编辑/校验/应用）"
  echo "5) 服务管理（启动/停止/重启/状态/日志）"
  echo "6) 查看当前状态概览"
  echo "7) 卸载"
  echo "0) 退出"
  echo "--------------------------------------------------"
}

menu_config() {
  echo "---------------- 配置管理 ----------------"
  echo "1) 编辑配置文件"
  echo "2) 校验配置文件"
  echo "3) 校验并应用（自动重启服务）"
  echo "0) 返回上级菜单"
  echo "------------------------------------------"
}

menu_service() {
  echo "---------------- 服务管理 ----------------"
  echo "1) 启动服务"
  echo "2) 停止服务"
  echo "3) 重启服务"
  echo "4) 查看服务状态"
  echo "5) 查看实时日志（Ctrl+C退出）"
  echo "6) 设置开机自启"
  echo "7) 取消开机自启"
  echo "0) 返回上级菜单"
  echo "------------------------------------------"
}

config_menu_loop() {
  while true; do
    menu_config
    read -rp "请选择 [0-3]： " c
    case "$c" in
      1) config_edit; pause ;;
      2) config_check || true; pause ;;
      3) config_apply_restart || true; pause ;;
      0) return 0 ;;
      *) warn "无效选择";;
    esac
  done
}

service_menu_loop() {
  while true; do
    menu_service
    read -rp "请选择 [0-7]： " s
    case "$s" in
      1) service_start; pause ;;
      2) service_stop; pause ;;
      3) service_restart; pause ;;
      4) service_status; pause ;;
      5) service_logs_follow; pause ;;
      6) service_enable; pause ;;
      7) service_disable; pause ;;
      0) return 0 ;;
      *) warn "无效选择";;
    esac
  done
}

main() {
  need_cmd uname
  need_cmd tar
  need_cmd sed
  need_cmd grep
  need_cmd awk
  pick_downloader

  # root 检测
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    USE_SUDO=1
  else
    USE_SUDO=0
  fi

  while true; do
    menu_main
    read -rp "请选择操作 [0-7]： " choice
    case "$choice" in
      1) install_or_upgrade_flow "latest"; pause ;;
      2)
        read -rp "请输入版本号（例如 1.13.0）： " v
        [[ -n "${v:-}" ]] || { warn "版本号不能为空"; continue; }
        install_or_upgrade_flow "version" "$v"
        pause
        ;;
      3)
        warn "Beta/预发布可能不稳定，仅建议测试环境使用"
        read -rp "确认继续？(y/N)： " yn
        [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "已取消"; continue; }
        install_or_upgrade_flow "beta"
        pause
        ;;
      4) config_menu_loop ;;
      5) service_menu_loop ;;
      6) show_status; pause ;;
      7) uninstall_flow; pause ;;
      0) exit 0 ;;
      *) warn "无效选择，请重新输入。" ;;
    esac
  done
}

main "$@"
