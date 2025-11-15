#!/bin/bash
# 一键安装 CPU 守护脚本 + systemd 服务（交互设置触发时间 & 限流CPU）

set -e

########################################
# 1. 必须用 root 运行
########################################
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 或 sudo 运行这个脚本。"
  exit 1
fi

########################################
# 2. 交互获取用户配置
########################################

# 获取 CPU 核心数
CORES=$(nproc)

echo "====== CPU 守护安装向导 ======"
echo "检测到本机 CPU 核心数：${CORES}"
echo

# 连续高负载多久后开始限流（分钟）
read -p "连续高负载多少『分钟』后开始限流？(默认 5 分钟)：" LIMIT_MIN
if [ -z "$LIMIT_MIN" ]; then
  LIMIT_MIN=5
fi

# 转成秒
MAX_TIME=$((LIMIT_MIN * 60))

# 触发后希望整机限制在多少 % CPU？（按“整机百分比”填）
read -p "触发后希望整机限制在多少『% CPU』？(默认 30，即整机约 30%)：" LIMIT_CPU_PERCENT
if [ -z "$LIMIT_CPU_PERCENT" ]; then
  LIMIT_CPU_PERCENT=30
fi

# 换算成 systemd CPUQuota：100% = 1 核
LIMIT_CPU_QUOTA=$((LIMIT_CPU_PERCENT * CORES))

echo
echo ">>> 配置摘要："
echo "  - 连续高负载时长：${LIMIT_MIN} 分钟（=${MAX_TIME} 秒）"
echo "  - 触发后整机目标占用：约 ${LIMIT_CPU_PERCENT}%"
echo "  - 对应 systemd CPUQuota：${LIMIT_CPU_QUOTA}%（约 ${CORES} 核 × ${LIMIT_CPU_PERCENT}%）"
echo

read -p "确认以上配置？(Y/n)：" CONFIRM
if [ -n "$CONFIRM" ] && [ "$CONFIRM" != "Y" ] && [ "$CONFIRM" != "y" ]; then
  echo "已取消安装。"
  exit 0
fi

########################################
# 3. 安装并启动 atd
########################################
echo "[1/4] 安装 atd..."
apt update -y
apt install -y at

echo "[2/4] 启用 atd..."
systemctl enable --now atd

########################################
# 4. 创建 /usr/local/bin/cpu_guard.sh
########################################
echo "[3/4] 写入 /usr/local/bin/cpu_guard.sh..."

cat >/usr/local/bin/cpu_guard.sh <<EOF
#!/bin/bash

# CPU 守护脚本：连续高负载则限流，24 小时后自动解除

# 超载判断阈值（百分比），比如 95 表示 >95% 算超载
THRESHOLD=95

# 检查间隔（秒）
CHECK_INTERVAL=10

# 连续高负载多少秒后触发（由安装脚本计算）
MAX_TIME=${MAX_TIME}

# 触发后设置的 CPUQuota（百分比，systemd 语义：100% = 1 核）
LIMIT_CPU=${LIMIT_CPU_QUOTA}

# 限流持续时间（秒）——这里 24 小时 = 86400 秒
WINDOW=86400

counter=0

# 先读第一次 /proc/stat 作为基准
# /proc/stat 结构参考：cpu  user nice system idle iowait irq softirq steal guest guest_nice
# 通过两次读数做差，计算这段时间内的 CPU 利用率（这是 top/mpstat 的通用算法之一）
read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
prev_idle=\$((idle + iowait))
prev_nonidle=\$((user + nice + system + irq + softirq + steal))
prev_total=\$((prev_idle + prev_nonidle))

while true; do
    # 等待 CHECK_INTERVAL 秒
    sleep "\$CHECK_INTERVAL"

    # 再次读取当前的 CPU 统计
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    idle_all=\$((idle + iowait))
    nonidle=\$((user + nice + system + irq + softirq + steal))
    total=\$((idle_all + nonidle))

    # 与上一轮做差，得到这段时间的 delta
    totald=\$((total - prev_total))
    idled=\$((idle_all - prev_idle))

    if [ "\$totald" -gt 0 ]; then
        # 当前这段时间的 CPU 使用率 = (totald - idled) / totald * 100
        cpu_usage=\$(( (100 * (totald - idled)) / totald ))
    else
        cpu_usage=0
    fi

    # 更新基准值，为下一轮计算做准备
    prev_total=\$total
    prev_idle=\$idle_all

    # 输出调试日志，方便用 journalctl 查看当前 CPU 和计时状态
    echo "cpu_guard: 当前CPU=\${cpu_usage}% counter=\${counter}s"

    # 判断是否超过阈值
    if [ "\$cpu_usage" -gt "\$THRESHOLD" ]; then
        counter=\$((counter + CHECK_INTERVAL))
    else
        counter=0
    fi

    # 如果累计高负载时间 >= MAX_TIME，触发限流逻辑
    if [ "\$counter" -ge "\$MAX_TIME" ]; then
        echo "cpu_guard: CPU 过高持续 \$MAX_TIME 秒，开始将 system.slice 和 user.slice 限流到 \$LIMIT_CPU%（systemd 配额）"

        # 对 system.slice（系统服务）限流
        systemctl set-property --runtime system.slice CPUQuota=\${LIMIT_CPU}% 2>&1 | sed 's/^/cpu_guard: system.slice 设置结果：/'

        # 对 user.slice（交互式 session / shell 进程）限流
        systemctl set-property --runtime user.slice CPUQuota=\${LIMIT_CPU}% 2>&1 | sed 's/^/cpu_guard: user.slice 设置结果：/'

        # 使用 at 在 24 小时后恢复 CPUQuota（需要 atd 服务）
        echo "systemctl set-property --runtime system.slice CPUQuota=100%; systemctl set-property --runtime user.slice CPUQuota=100%" \
          | at now + 24 hours 2>&1 | sed 's/^/cpu_guard: at 调度结果：/'

        echo "cpu_guard: 已安排在 24 小时后恢复 CPUQuota 到 100%"

        # 重置计时器，避免重复无限触发
        counter=0
    fi
done
EOF

chmod +x /usr/local/bin/cpu_guard.sh

########################################
# 5. 创建 systemd 服务 cpu-guard.service
########################################
echo "[4/4] 写入 /etc/systemd/system/cpu-guard.service..."

cat >/etc/systemd/system/cpu-guard.service <<'EOF'
[Unit]
Description=CPU Guard Auto Throttle Service
After=network.target

[Service]
ExecStart=/usr/local/bin/cpu_guard.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd，并启用服务
systemctl daemon-reload
systemctl enable --now cpu-guard.service

echo
echo "✅ CPU 守护服务已安装并启动。"
echo "👉 查看运行日志：  journalctl -fu cpu-guard.service"
echo "👉 如需停止并禁用： systemctl disable --now cpu-guard.service"
echo
echo "当前配置：连续高负载 ${LIMIT_MIN} 分钟 后，将整机约限制在 ${LIMIT_CPU_PERCENT}%（CPUQuota=${LIMIT_CPU_QUOTA}%。）"