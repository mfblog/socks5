#!/bin/bash

set -e

# ===== 可修改参数 =====
PROXY_HOST="47.243.66.101"
PROXY_PORT="1007"
PROXY_USER="user1"
PROXY_PASS="user1"
CONFIG_FILE="/etc/proxychains.conf"

# 测试参数
TEST_URL="http://ip.sb"
CONNECT_TIMEOUT=8
MAX_TIME=15

log() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1"
}

err() {
    echo "[ERROR] $1" >&2
    exit 1
}

# ===== 检查权限 =====
if [ "$(id -u)" != "0" ]; then
    err "请使用 root 运行此脚本"
fi

# ===== 检查系统 =====
if [ ! -f /etc/centos-release ]; then
    err "当前系统不是 CentOS，脚本终止"
fi

if ! grep -q "CentOS Linux 7" /etc/centos-release && ! grep -q "CentOS.*7" /etc/centos-release; then
    err "当前系统不是 CentOS 7，脚本终止"
fi

log "开始安装 EPEL 源..."
yum install -y epel-release

log "开始安装 proxychains-ng..."
yum install -y proxychains-ng

# ===== 检查配置文件 =====
if [ ! -f "$CONFIG_FILE" ]; then
    err "未找到配置文件: $CONFIG_FILE"
fi

# ===== 备份配置 =====
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CONFIG_FILE" "$BACKUP_FILE"
log "已备份配置文件到: $BACKUP_FILE"

# ===== 修改 chain 模式 =====
log "配置 dynamic_chain..."
sed -i 's/^[[:space:]]*strict_chain/# strict_chain/g' "$CONFIG_FILE"
sed -i 's/^[[:space:]]*random_chain/# random_chain/g' "$CONFIG_FILE"

if grep -q '^[[:space:]]*#\s*dynamic_chain' "$CONFIG_FILE"; then
    sed -i 's/^[[:space:]]*#\s*dynamic_chain/dynamic_chain/g' "$CONFIG_FILE"
elif ! grep -q '^[[:space:]]*dynamic_chain' "$CONFIG_FILE"; then
    sed -i '1i dynamic_chain' "$CONFIG_FILE"
fi

# ===== 开启 proxy_dns =====
log "开启 proxy_dns..."
if grep -q '^[[:space:]]*#\s*proxy_dns' "$CONFIG_FILE"; then
    sed -i 's/^[[:space:]]*#\s*proxy_dns/proxy_dns/g' "$CONFIG_FILE"
elif ! grep -q '^[[:space:]]*proxy_dns' "$CONFIG_FILE"; then
    sed -i '/^dynamic_chain/a proxy_dns' "$CONFIG_FILE"
fi

# ===== 清理旧代理条目 =====
log "清理旧代理条目..."
awk '
BEGIN { in_proxylist=0 }
/^\[ProxyList\]/ { print; in_proxylist=1; next }
{
    if (in_proxylist == 1) {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
            print
        }
    } else {
        print
    }
}
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# ===== 如果没有 [ProxyList]，则追加 =====
if ! grep -q '^\[ProxyList\]' "$CONFIG_FILE"; then
    echo "" >> "$CONFIG_FILE"
    echo "[ProxyList]" >> "$CONFIG_FILE"
fi

# ===== 写入 socks5 代理 =====
log "写入 socks5 代理..."
if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    echo "socks5  $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS" >> "$CONFIG_FILE"
else
    echo "socks5  $PROXY_HOST $PROXY_PORT" >> "$CONFIG_FILE"
fi

log "proxychains4 安装并配置完成"
echo
echo "当前代理配置："
tail -n 20 "$CONFIG_FILE"
echo

# ===== 自动测试 =====
log "开始自动测试代理连通性..."

TEST_OUTPUT=$(
    proxychains4 curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    "$TEST_URL" 2>&1
)
TEST_STATUS=$?

if [ $TEST_STATUS -eq 0 ] && [ -n "$TEST_OUTPUT" ]; then
    log "代理测试成功，出口 IP: $TEST_OUTPUT"
    exit 0
fi

warn "首次测试失败，尝试关闭 proxy_dns 后再测一次..."

cp -a "$CONFIG_FILE" "${CONFIG_FILE}.testbak.$(date +%Y%m%d%H%M%S)"
sed -i 's/^[[:space:]]*proxy_dns/# proxy_dns/g' "$CONFIG_FILE"

TEST_OUTPUT=$(
    proxychains4 curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    "$TEST_URL" 2>&1
)
TEST_STATUS=$?

if [ $TEST_STATUS -eq 0 ] && [ -n "$TEST_OUTPUT" ]; then
    log "代理测试成功（关闭 proxy_dns 后），出口 IP: $TEST_OUTPUT"
    exit 0
fi

err "代理测试失败。请检查代理地址、端口、账号密码是否正确，或更换代理节点。"
