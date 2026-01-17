#!/bin/bash
set -e

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}>>> 开始构建全栈 AI 开发环境 (V3 官方纯净版 - 无Gemini)...${NC}"

# 1. 基础检查
echo -e "${YELLOW}>>> [1/6] 检查基础环境...${NC}"
if ! [ -x "$(command -v git)" ]; then
    sudo apt update && sudo apt install -y curl wget git build-essential unzip zip htop tmux zsh nfs-common python3-venv python3-pip
fi

# 2. 检查 Swap
echo -e "${YELLOW}>>> [2/6] 检查 Swap...${NC}"
if [ $(free -m | awk '/^Swap:/ {print $2}') -eq 0 ]; then
    echo "创建 2GB Swap..."
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo "Swap 已存在，跳过。"
fi

# 3. 检查 Docker (使用官方脚本)
echo -e "${YELLOW}>>> [3/6] 检查 Docker...${NC}"
if ! [ -x "$(command -v docker)" ]; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
else
    echo "Docker 已安装，跳过。"
fi

# 4. 安装 Node.js 与 Claude CLI (官方源)
echo -e "${YELLOW}>>> [4/6] 安装 Node.js 与 AI 工具...${NC}"
export FNM_DIR="$HOME/.local/share/fnm"
# 安装 fnm
curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell

FNM_BIN="$FNM_DIR/fnm"

if [ -f "$FNM_BIN" ]; then
    echo "找到 fnm，开始安装 Node..."
    chmod +x "$FNM_BIN"
    
    # 【关键修复】强制使用 bash 语法，防止 zsh 的 rehash 报错
    eval "`$FNM_BIN env --shell bash`"
    
    # 安装 Node LTS
    $FNM_BIN install --lts
    
    echo "正在安装 Claude CLI (使用官方 registry)..."
    export PATH="$FNM_DIR:$PATH"
    
    # 再次加载环境，确保 npm 可用
    eval "`$FNM_BIN env --shell bash`"
    
    # 安装 Claude
    npm install -g @anthropic-ai/claude-code
else
    echo "错误：fnm 安装失败，未找到二进制文件。"
    exit 1
fi

# 【已移除】Python Gemini SDK 安装步骤

# 5. 配置 Tmux (手机优化版)
echo -e "${YELLOW}>>> [5/6] 配置 Tmux...${NC}"
cat > ~/.tmux.conf <<EOF
set -g mouse on
unbind C-b
set -g prefix C-a
bind C-a send-prefix
set-option -g status-position top
bind | split-window -h
bind - split-window -v
set -g default-terminal "screen-256color"
set -g history-limit 10000
EOF

# 6. 安装 Zsh 和插件 (官方 GitHub 源)
echo -e "${YELLOW}>>> [6/6] 配置 Zsh...${NC}"
rm -rf ~/.oh-my-zsh
# 安装 Oh My Zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# 安装插件 (GitHub)
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

cat > ~/.zshrc <<EOF
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting docker)
source \$ZSH/oh-my-zsh.sh

# FNM 配置
export PATH="\$HOME/.local/share/fnm:\$PATH"
eval "\`fnm env --use-on-cd\`"

alias work="cd ~/projects"
alias c="claude"
EOF

# 切换 Shell
if [ "$SHELL" != "$(which zsh)" ]; then
    sudo chsh -s $(which zsh) $USER
fi

echo -e "${GREEN}>>> 恭喜！官方纯净版环境安装完成！${NC}"
echo -e "${YELLOW}请立即断开 SSH 并重新连接以加载 Zsh 和环境变量。${NC}"
