#!/bin/bash

# =============================================================================
# 🚀 DNS 优化工具 v2.0
# =============================================================================
# 描述: 一键将DNS设置为用户自定义的高速稳定DNS
# 适用: 搬瓦工VPS及各种Linux系统
# 作者: 搬瓦工精品网BWH91.COM 
# 更新: $(date +%Y-%m-%d)
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 图标定义
SUCCESS="✅"
ERROR="❌"
WARNING="⚠️"
INFO="ℹ️"
ROCKET="🚀"
GEAR="⚙️"
SHIELD="🛡️"
TEST="🧪"

# 默认DNS配置
DEFAULT_DNS_SERVERS=("8.8.8.8" "8.8.4.4" "1.1.1.1" "1.0.0.1")
DNS_SERVERS=()

# 打印函数
print_header() {
    clear
    echo -e "${PURPLE}=================================================================${NC}"
    echo -e "${WHITE}                    ${ROCKET} DNS 优化工具 v2.0                     ${NC}"
    echo -e "${PURPLE}=================================================================${NC}"
    echo -e "${CYAN}  将DNS设置为您自定义的高速稳定DNS服务器${NC}"
    echo -e "${CYAN}                    搬瓦工精品网BWH91.COM ${NC}"
    echo -e "${CYAN}            如遇问题，进群获取支持 https://t.me/BWH81  ${NC}"
    echo -e "${PURPLE}=================================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}[${GEAR}]${NC} ${WHITE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}[${SUCCESS}]${NC} $1"
}

print_error() {
    echo -e "${RED}[${ERROR}]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[${WARNING}]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[${INFO}]${NC} $1"
}

# 进度条函数
show_progress() {
    local duration=$1
    local message=$2
    echo -ne "${BLUE}[${GEAR}]${NC} $message "
    
    for ((i=0; i<duration; i++)); do
        echo -ne "▓"
        sleep 0.1
    done
    echo -e " ${GREEN}完成${NC}"
}

# 检查权限
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用root权限运行此脚本"
        echo -e "${YELLOW}正确用法: ${WHITE}sudo $0${NC}"
        exit 1
    fi
}

# 检测系统信息
detect_system() {
    print_step "检测系统信息..."
    
    # 获取系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$NAME
        OS_VERSION=$VERSION
    else
        OS_NAME="Unknown"
        OS_VERSION="Unknown"
    fi
    
    print_info "系统: ${CYAN}$OS_NAME $OS_VERSION${NC}"
    
    # 检测网络管理器
    NETWORK_MANAGER="Unknown"
    if systemctl is-active --quiet systemd-resolved; then
        NETWORK_MANAGER="systemd-resolved"
    elif systemctl is-active --quiet NetworkManager; then
        NETWORK_MANAGER="NetworkManager"
    elif command -v resolvconf &> /dev/null; then
        NETWORK_MANAGER="resolvconf"
    else
        NETWORK_MANAGER="traditional"
    fi
    
    print_info "网络管理器: ${CYAN}$NETWORK_MANAGER${NC}"
    echo ""
}

# 显示当前DNS
show_current_dns() {
    print_step "当前DNS配置:"
    echo -e "${YELLOW}┌─────────────────────────────────────┐${NC}"
    if [ -f /etc/resolv.conf ]; then
        while IFS= read -r line; do
            if [[ $line == nameserver* ]]; then
                dns_ip=$(echo $line | awk '{print $2}')
                echo -e "${YELLOW}│${NC} ${WHITE}$line${NC}"
            fi
        done < /etc/resolv.conf
    fi
    echo -e "${YELLOW}└─────────────────────────────────────┘${NC}"
    echo ""
}

prompt_dns_servers() {
    print_step "输入DNS服务器地址"
    local input
    local default_dns="${DEFAULT_DNS_SERVERS[*]}"
    
    while true; do
        read -r -p "$(echo -e ${YELLOW}请输入要使用的DNS服务器（空格分隔，默认: ${WHITE}$default_dns${YELLOW}）:${NC} )" input
        
        if [[ -z ${input// } ]]; then
            DNS_SERVERS=("${DEFAULT_DNS_SERVERS[@]}")
            print_info "使用默认DNS服务器: ${WHITE}${DNS_SERVERS[*]}${NC}"
            break
        fi
        
        read -a DNS_SERVERS <<< "$input"
        if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
            print_warning "请输入至少一个有效的DNS服务器地址"
            continue
        fi
        
        print_info "已设置自定义DNS服务器: ${WHITE}${DNS_SERVERS[*]}${NC}"
        break
    done
    echo ""
}

write_resolv_conf() {
    local generated_at
    generated_at=$(date)
    
    {
        cat <<EOF
# =================================================================
# 🚀 优化DNS配置 - 由DNS优化工具自动生成
# 生成时间: $generated_at
# =================================================================

# 自定义DNS服务器列表
EOF

        for dns in "${DNS_SERVERS[@]}"; do
            echo "nameserver $dns"
        done

        cat <<'EOF'

# DNS查询优化选项
options timeout:2
options attempts:3
options rotate
options single-request-reopen
EOF
    } | tee /etc/resolv.conf > /dev/null
}

# 主要的DNS更改函数
change_dns() {
    print_header
    detect_system
    show_current_dns
    prompt_dns_servers
    
    # 用户确认
    echo -e "${YELLOW}即将设置以下DNS服务器:${NC}"
    local idx=1
    for dns in "${DNS_SERVERS[@]}"; do
        echo -e "  ${GREEN}${ROCKET} DNS #$idx:${NC} ${WHITE}$dns${NC}"
        ((idx++))
    done
    echo ""
    
    read -p "$(echo -e ${YELLOW}继续操作吗? [Y/n]: ${NC})" -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
        print_warning "操作已取消"
        exit 0
    fi
    
    echo ""
    print_step "开始DNS优化流程..."
    echo ""
    
    # 1. 备份原始配置
    print_step "备份原始DNS配置"
    BACKUP_FILE="/etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/resolv.conf "$BACKUP_FILE"
    show_progress 10 "创建备份文件: $BACKUP_FILE"
    print_success "原始配置已备份"
    echo ""
    
    # 2. 设置新的DNS
    print_step "配置新的DNS服务器"
    write_resolv_conf
    show_progress 15 "写入DNS配置"
    print_success "DNS服务器配置完成"
    echo ""
    
    # 3. 系统特定配置
    print_step "配置系统网络管理器"
    configure_network_manager
    echo ""
    
    # 4. 防止配置被覆盖
    print_step "保护DNS配置"
    chattr +i /etc/resolv.conf 2>/dev/null && print_success "DNS配置已锁定，防止被覆盖" || print_warning "无法锁定配置文件，可能会被系统覆盖"
    echo ""
    
    # 5. 测试DNS
    test_dns_connectivity
    
    # 6. 显示完成信息
    show_completion_info
}

# 配置网络管理器
configure_network_manager() {
    if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
        print_warning "未提供DNS服务器，跳过网络管理器配置"
        return
    fi

    local dns_space dns_comma
    dns_space=$(IFS=' '; echo "${DNS_SERVERS[*]}")
    dns_comma=$(IFS=','; echo "${DNS_SERVERS[*]}")

    case $NETWORK_MANAGER in
        "systemd-resolved")
            print_info "配置 systemd-resolved..."
            mkdir -p /etc/systemd/resolved.conf.d
            
            tee /etc/systemd/resolved.conf.d/dns_servers.conf > /dev/null <<EOF
[Resolve]
DNS=$dns_space
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=no
Cache=yes
DNSStubListener=yes
EOF
            systemctl restart systemd-resolved
            rm -f /etc/resolv.conf
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            print_success "systemd-resolved 配置完成"
            ;;
            
        "NetworkManager")
            print_info "配置 NetworkManager..."
            CONNECTION_NAME=$(nmcli -t -f NAME connection show --active | head -n1)
            
            if [ ! -z "$CONNECTION_NAME" ]; then
                nmcli connection modify "$CONNECTION_NAME" ipv4.dns "$dns_comma"
                nmcli connection modify "$CONNECTION_NAME" ipv4.ignore-auto-dns yes
                nmcli connection down "$CONNECTION_NAME" && nmcli connection up "$CONNECTION_NAME"
                print_success "NetworkManager 配置完成"
            fi
            ;;
            
        "resolvconf")
            print_info "配置 resolvconf..."
            {
                echo "# 自定义DNS服务器"
                for dns in "${DNS_SERVERS[@]}"; do
                    echo "nameserver $dns"
                done
            } | tee /etc/resolvconf/resolv.conf.d/head > /dev/null
            resolvconf -u
            print_success "resolvconf 配置完成"
            ;;
            
        *)
            print_info "使用传统DNS配置方式"
            ;;
    esac
}

# 测试DNS连接
test_dns_connectivity() {
    print_step "测试DNS连接性能"
    echo ""
    
    # 测试DNS解析工具可用性
    if command -v nslookup &> /dev/null; then
        DNS_TOOL="nslookup"
    elif command -v dig &> /dev/null; then
        DNS_TOOL="dig"
    elif command -v host &> /dev/null; then
        DNS_TOOL="host"
    else
        DNS_TOOL="ping"
    fi
    
    print_info "使用 ${CYAN}$DNS_TOOL${NC} 进行DNS测试"
    echo ""
    
    # 测试各个DNS服务器
    if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
        print_warning "未配置DNS服务器，跳过单独测试"
    else
        local idx=1
        for dns in "${DNS_SERVERS[@]}"; do
            test_dns_server "$dns" "DNS #$idx"
            ((idx++))
        done
    fi
    test_general_connectivity
}

# 测试单个DNS服务器
test_dns_server() {
    local dns_ip=$1
    local dns_name=$2
    
    echo -ne "${BLUE}[${TEST}]${NC} 测试 $dns_name ($dns_ip)... "
    
    case $DNS_TOOL in
        "nslookup")
            if timeout 5 nslookup google.com $dns_ip &> /dev/null; then
                echo -e "${GREEN}${SUCCESS} 正常${NC}"
            else
                echo -e "${RED}${ERROR} 失败${NC}"
            fi
            ;;
        "dig")
            if timeout 5 dig @$dns_ip google.com +short &> /dev/null; then
                echo -e "${GREEN}${SUCCESS} 正常${NC}"
            else
                echo -e "${RED}${ERROR} 失败${NC}"
            fi
            ;;
        "host")
            if timeout 5 host google.com $dns_ip &> /dev/null; then
                echo -e "${GREEN}${SUCCESS} 正常${NC}"
            else
                echo -e "${RED}${ERROR} 失败${NC}"
            fi
            ;;
        "ping")
            if timeout 3 ping -c 1 $dns_ip &> /dev/null; then
                echo -e "${GREEN}${SUCCESS} 可达${NC}"
            else
                echo -e "${RED}${ERROR} 不可达${NC}"
            fi
            ;;
    esac
}

# 测试一般连通性
test_general_connectivity() {
    echo -ne "${BLUE}[${TEST}]${NC} 测试域名解析... "
    if timeout 5 ping -c 1 google.com &> /dev/null; then
        echo -e "${GREEN}${SUCCESS} 正常${NC}"
    else
        echo -e "${RED}${ERROR} 失败${NC}"
    fi
    echo ""
}

# 显示完成信息
show_completion_info() {
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${WHITE}                      ${SUCCESS} DNS 优化完成！                      ${NC}"
    echo -e "${GREEN}=================================================================${NC}"
    echo ""
    
    echo -e "${YELLOW}📊 新DNS服务器配置:${NC}"
    if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
        echo -e "  ${WARNING} 未设置DNS服务器"
    else
        local idx=1
        echo -e "${GREEN}┌─────────────────────────────────────────────────────┐${NC}"
        for dns in "${DNS_SERVERS[@]}"; do
            printf "%b\n" "${GREEN}│${NC} ${ROCKET} DNS #$idx:${NC} ${WHITE}$dns${NC} ${GREEN}│${NC}"
            ((idx++))
        done
        echo -e "${GREEN}└─────────────────────────────────────────────────────┘${NC}"
    fi
    echo ""
    
    echo -e "${YELLOW}🔧 优化功能:${NC}"
    echo -e "  ${SUCCESS} 自动备份原始配置"
    echo -e "  ${SUCCESS} 智能适配网络管理器"
    echo -e "  ${SUCCESS} 防止配置被覆盖"
    echo -e "  ${SUCCESS} 优化DNS查询参数"
    echo ""
    
    echo -e "${YELLOW}🔄 恢复原始设置:${NC}"
    echo -e "${WHITE}sudo chattr -i /etc/resolv.conf${NC}"
    echo -e "${WHITE}sudo cp $BACKUP_FILE /etc/resolv.conf${NC}"
    echo ""
    
    echo -e "${YELLOW}📞 技术支持:${NC}"
    echo -e "  如遇问题，进群获取支持 https://t.me/BWH81 "
    echo ""
    
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${WHITE}           🎉 关注搬瓦工传奇频道 https://t.me/BWH82                     ${NC}"
    echo -e "${WHITE}           🎉 加入搬瓦工交流群 https://t.me/BWH81                     ${NC}"
    echo -e "${GREEN}=================================================================${NC}"
}

# 主程序
main() {
    # 检查权限
    check_permissions
    
    # 执行DNS更改
    change_dns
}

# 捕获中断信号
trap 'echo -e "\n${RED}操作被中断${NC}"; exit 1' INT

# 运行主程序
main "$@"
