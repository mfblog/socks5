#!/bin/bash

# ==============================================================================
# 安装脚本：自动创建idc流量监控服务 (V3 - 启动健壮性优化)
# ==============================================================================

# 检查是否以root用户身份运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本必须以root用户身份运行。"
  echo "请尝试使用 'sudo ./install.sh' 来执行。"
  exit 1
fi

IDC_SCRIPT_PATH="/usr/local/bin/idc.sh"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/idc.service"

# --- 核心流量监控脚本内容 (已优化send_notification函数) ---
read -r -d '' IDC_SCRIPT_CONTENT << 'EOF'
#!/bin/bash

# --- 用户配置 ---
BOT_TOKEN="8354796331:AAGQOUimRgk6GZryMSVgLQGBjT_EYQRwwtM"
CHAT_ID="2058570154"
THRESHOLD_GB=1024
CHECK_INTERVAL=10 # 【调整】将检测间隔缩短为30秒，以便更快响应

# --- 高级配置 ---
STATE_FILE="/var/run/traffic_monitor.state"
OVERRIDE_FILE="/var/run/traffic_monitor.manual_override"
PID_FILE="/var/run/traffic_monitor.pid"
# --- 配置结束 ---

# ... (此处省略了 clear_pending_updates, 单例锁, 依赖检查等无变动的函数) ...
clear_pending_updates() { echo "正在清空待处理的Telegram消息队列..."; local updates; updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1"); local last_update_id; last_update_id=$(echo "$updates" | jq -r '.result[-1].update_id // 0'); if (( last_update_id > 0 )); then curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=$((last_update_id + 1))" >/dev/null; echo "所有旧消息已成功清除。"; else echo "没有发现需要清除的旧消息。"; fi; }
if [ -e "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" &>/dev/null; then echo "错误：脚本实例已在运行。PID: $(cat "$PID_FILE")"; exit 1; fi; echo $$ > "$PID_FILE"; trap 'rm -f "$PID_FILE"' EXIT;
check_and_install_deps() { local PKG_MANAGER=""; PACKAGES_TO_INSTALL=(); if command -v apt-get &>/dev/null; then PKG_MANAGER="apt-get"; elif command -v dnf &>/dev/null; then PKG_MANAGER="dnf"; elif command -v yum &>/dev/null; then PKG_MANAGER="yum"; else echo "错误: 无法检测到支持的包管理器。" >&2; exit 1; fi; DEPS=("iptables" "bc" "curl" "jq"); for cmd in "${DEPS[@]}"; do if ! command -v "$cmd" &>/dev/null; then PACKAGES_TO_INSTALL+=("$cmd"); fi; done; if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then echo "将要安装的包: ${PACKAGES_TO_INSTALL[*]}"; if [ "$EUID" -ne 0 ]; then echo "错误: 必须以root用户身份运行才能自动安装依赖。" >&2; exit 1; fi; case "$PKG_MANAGER" in "apt-get") apt-get update -y >/dev/null; apt-get install -y "${PACKAGES_TO_INSTALL[@]}";; "dnf" | "yum") "$PKG_MANAGER" install -y "${PACKAGES_TO_INSTALL[@]}";; esac; for pkg in "${PACKAGES_TO_INSTALL[@]}"; do if ! command -v "$pkg" &>/dev/null; then echo "错误: 自动安装包 '$pkg' 失败。" >&2; exit 1; fi; done; echo "依赖项安装成功。"; else echo "所有依赖项 (iptables, bc, curl, jq) 均已满足。"; fi; }
check_and_install_deps; THRESHOLD_BYTES=$(printf "%.0f\n" $(echo "$THRESHOLD_GB * 1024 * 1024 * 1024" | bc -l)); format_bytes() { local bytes=$1; if (( bytes < 1024*1024*1024*1024 )); then printf "%.2f GB\n" $(echo "$bytes / (1024*1024*1024)" | bc -l); else printf "%.2f TB\n" $(echo "$bytes / (1024*1024*1024*1024)" | bc -l); fi; }

# --- 【V3优化】增强的通知函数，带API响应日志 ---
send_notification() {
    local message="$1"
    echo "正在发送通知..."
    local URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

    # 使用-w http_code来获取HTTP状态码，并将API响应和错误信息都记录下来
    local response
    http_code=$(curl -s -X POST "$URL" \
                    -d chat_id="${CHAT_ID}" \
                    -d text="${message}" \
                    --connect-timeout 10 \
                    --max-time 15 \
                    -w "%{http_code}" \
                    -o >(response=$(cat)))

    echo "Telegram API HTTP Status: ${http_code}"
    echo "Telegram API Response Body: ${response}"

    # 检查HTTP状态码是否为200 (OK)
    if [ "$http_code" -eq 200 ]; then
        echo "通知已成功发送 (HTTP 200)。"
    else
        echo "警告: 发送通知失败。HTTP状态码: ${http_code}"
    fi
}

send_startup_info() {
    echo "正在准备并发送启动信息..."
    local MY_PUBLIC_IP
    MY_PUBLIC_IP=$(curl -s --connect-timeout 5 https://ipinfo.io/ip)
    if [ -z "$MY_PUBLIC_IP" ]; then
        echo "警告: 无法获取公网IP地址，启动信息可能不完整。"
        MY_PUBLIC_IP="获取失败"
    fi
    local total_tx_bytes
    total_tx_bytes=$(cat /proc/net/dev | tail -n +3 | grep -v "lo:" | awk '{sum += $10} END {print sum}')
    local current_traffic
    current_traffic=$(format_bytes "$total_tx_bytes")
    local MESSAGE="🚀 服务启动通知%0A%0A主机: [$(hostname)]%0A公网IP: ${MY_PUBLIC_IP}%0A当前总流量: ${current_traffic}%0A本月阈值: ${THRESHOLD_GB} GB"
    send_notification "$MESSAGE"
}

# ... (此处省略了 reset_all_and_unblock, block_traffic_auto, process_bot_commands 等无变动的函数) ...
reset_all_and_unblock() { echo "正在彻底重置状态并解锁网络..."; while iptables -D OUTPUT -j TRAFFIC_BLOCK 2>/dev/null; do :; done; if iptables -L TRAFFIC_BLOCK &>/dev/null; then iptables -F TRAFFIC_BLOCK; iptables -X TRAFFIC_BLOCK; echo "iptables 规则已移除。"; fi; rm -f "$STATE_FILE" "$OVERRIDE_FILE"; echo "所有状态文件 (自动阻断/手动覆盖) 已被移除。"; }
block_traffic_auto() { if [ -f "$STATE_FILE" ]; then return; fi; echo "流量超限，正在应用防火墙规则..."; iptables -N TRAFFIC_BLOCK; iptables -A TRAFFIC_BLOCK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -A TRAFFIC_BLOCK -o lo -j ACCEPT; iptables -A TRAFFIC_BLOCK -p tcp --dport 22 -j ACCEPT; iptables -A TRAFFIC_BLOCK -p udp --dport 53 -j ACCEPT; iptables -A TRAFFIC_BLOCK -p tcp --dport 53 -j ACCEPT; iptables -A TRAFFIC_BLOCK -p tcp --dport 443 -j ACCEPT; iptables -A TRAFFIC_BLOCK -p tcp -j REJECT --reject-with tcp-reset; iptables -A TRAFFIC_BLOCK -p udp -j DROP; iptables -I OUTPUT 1 -j TRAFFIC_BLOCK; touch "$STATE_FILE"; echo "网络流量已被自动阻断。"; }
process_bot_commands() { local last_update_id=0; local updates; local temp_updates_file; updates=$(curl -s --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${last_update_id}&limit=1&timeout=10"); if ! jq -e '.ok == true and (.result | length > 0)' <<< "$updates" > /dev/null; then return; fi; temp_updates_file=$(mktemp); jq -r '.result[-1] | "\(.update_id) \(.message.chat.id) \(.message.text)"' <<< "$updates" > "$temp_updates_file"; read -r update_id msg_chat_id msg_text < "$temp_updates_file"; rm -f "$temp_updates_file"; if [ -z "$update_id" ]; then return; fi; curl -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=$((update_id + 1))" > /dev/null; if [ "$msg_chat_id" -eq "$CHAT_ID" ] && [[ $msg_text == /unblock* ]]; then local command_ip; command_ip=$(echo "$msg_text" | awk '{print $2}'); local MY_PUBLIC_IP; MY_PUBLIC_IP=$(curl -s https://ipinfo.io/ip); if [[ "$command_ip" == "$MY_PUBLIC_IP" || "$command_ip" == "all" ]]; then if [ -f "$STATE_FILE" ]; then echo "收到有效的手动解锁命令，正在执行解锁..."; reset_all_and_unblock; touch "$OVERRIDE_FILE"; echo "已创建手动覆盖状态，本月内将不再自动阻断。"; send_notification "✅ 手动解锁成功%0A主机: [$(hostname)]%0AIP: ${MY_PUBLIC_IP}%0A网络限制已解除，并将在本月内保持解锁状态。"; else send_notification "ℹ️ 操作提醒%0A主机: [$(hostname)]%0AIP: ${MY_PUBLIC_IP}%0A该主机的网络未被限制，无需解锁。"; fi; fi; fi; }


# --- 主逻辑 ---
echo "流量监控服务启动... PID: $$"
clear_pending_updates
reset_all_and_unblock
send_startup_info
while true; do
    process_bot_commands
    if [ "$(date +%-d)" -eq 1 ] && { [ -f "$STATE_FILE" ] || [ -f "$OVERRIDE_FILE" ]; }; then echo "今天是本月1号，重置所有网络限制和状态..."; reset_all_and_unblock; send_notification "✅ 自动恢复通知%0A主机: [$(hostname)]%0AIP: $(curl -s https://ipinfo.io/ip)%0A今天是本月1号，所有网络限制和手动覆盖状态已自动解除。"; fi
    if [ -f "$STATE_FILE" ] || [ -f "$OVERRIDE_FILE" ]; then if [ -f "$STATE_FILE" ]; then echo "网络当前处于自动阻断状态，等待解锁命令或月初重置。"; fi; if [ -f "$OVERRIDE_FILE" ]; then echo "网络当前处于手动覆盖状态，本月内不再自动检查流量。"; fi; else total_tx_bytes=$(cat /proc/net/dev | tail -n +3 | grep -v "lo:" | awk '{sum += $10} END {print sum}'); if (( total_tx_bytes > THRESHOLD_BYTES )); then PUBLIC_IP=$(curl -s https://ipinfo.io/ip); current_traffic=$(format_bytes $total_tx_bytes); MESSAGE="流量警告：主机 [$(hostname)] 的上行流量已超出阈值！即将阻断网络！%0A%0A阈值: ${THRESHOLD_GB} GB%0A当前总流量: ${current_traffic}%0A公网IP: ${PUBLIC_IP}%0A%0A你可以通过发送 '/unblock ${PUBLIC_IP}' 来手动解锁。%0A网络将在下月1号自动恢复。"; send_notification "$MESSAGE"; block_traffic_auto; else echo "当前上行流量: $(format_bytes $total_tx_bytes) (阈值: ${THRESHOLD_GB} GB)，正常。"; fi; fi
    sleep ${CHECK_INTERVAL}
done
EOF

# --- 【V3优化】systemd服务文件，确保网络完全就绪 ---
read -r -d '' SYSTEMD_SERVICE_CONTENT << EOF
[Unit]
Description=IDC Traffic Monitor Service
# 确保在网络完全联机后再启动服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
# 在启动主脚本前额外等待3秒，作为最后的保险
ExecStartPre=/bin/sleep 3
ExecStart=$IDC_SCRIPT_PATH
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- 开始安装流程 ---
echo "--> 步骤 1/4: 创建流量监控脚本..."
echo "$IDC_SCRIPT_CONTENT" > "$IDC_SCRIPT_PATH"; chmod 755 "$IDC_SCRIPT_PATH"
echo "脚本已成功创建于 $IDC_SCRIPT_PATH"
echo ""
echo "--> 步骤 2/4: 创建 systemd 服务文件..."
echo "$SYSTEMD_SERVICE_CONTENT" > "$SYSTEMD_SERVICE_PATH"
echo "服务文件已成功创建于 $SYSTEMD_SERVICE_PATH"
echo ""
echo "--> 步骤 3/4: 重载 systemd 并设置服务..."
systemctl stop idc.service &> /dev/null
systemctl daemon-reload
systemctl enable idc.service
echo "服务已设置为开机自启。"
echo ""
echo "--> 步骤 4/4: 启动服务..."
systemctl start idc.service
echo "服务已启动。"
echo ""
echo "=========================================="
echo "安装成功！"
echo "您现在可以重启服务器来验证，或者手动重启服务:"
echo "systemctl restart idc.service"
echo "然后通过日志检查启动消息的发送情况:"
echo "journalctl -u idc.service -n 20 --no-pager"
echo "=========================================="
