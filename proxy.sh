#!/bin/bash

set -e

PROXY_HOST="47.243.66.101"
PROXY_PORT="1007"
PROXY_USER="user1"
PROXY_PASS="user1"
CONFIG_FILE="/etc/proxychains.conf"

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

# root检查
[ "$(id -u)" != "0" ] && err "请用root运行"

# 系统检查
[ ! -f /etc/centos-release ] && err "不是CentOS"

log "安装依赖..."
yum install -y epel-release
yum install -y proxychains-ng

[ ! -f "$CONFIG_FILE" ] && err "配置文件不存在"

# 备份
cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

# chain模式
log "设置 dynamic_chain..."
sed -i 's/^strict_chain/# strict_chain/' "$CONFIG_FILE"
sed -i 's/^random_chain/# random_chain/' "$CONFIG_FILE"
sed -i 's/^#\s*dynamic_chain/dynamic_chain/' "$CONFIG_FILE"

# ❗关键修改：关闭所有 DNS 代理
log "关闭 proxy_dns（避免卡死）..."
sed -i 's/^proxy_dns/# proxy_dns/g' "$CONFIG_FILE"
sed -i 's/^proxy_dns_daemon/# proxy_dns_daemon/g' "$CONFIG_FILE"
sed -i 's/^proxy_dns_old/# proxy_dns_old/g' "$CONFIG_FILE"

# 清理代理
log "清理旧代理..."
awk '
BEGIN {flag=0}
/^\[ProxyList\]/ {print; flag=1; next}
{
 if(flag==1){
   if($0 ~ /^[# ]*$/) print
 } else print
}
' "$CONFIG_FILE" > tmp && mv tmp "$CONFIG_FILE"

grep -q "^\[ProxyList\]" "$CONFIG_FILE" || echo "[ProxyList]" >> "$CONFIG_FILE"

# 写入代理
log "写入代理..."
if [ -n "$PROXY_USER" ]; then
    echo "socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS" >> "$CONFIG_FILE"
else
    echo "socks5 $PROXY_HOST $PROXY_PORT" >> "$CONFIG_FILE"
fi

echo
log "当前配置："
tail -n 10 "$CONFIG_FILE"
echo

# 自动测试（带超时，绝不卡死）
log "测试代理..."

if proxychains4 curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    "$TEST_URL" > /tmp/proxy_test 2>/dev/null; then

    IP=$(cat /tmp/proxy_test)
    log "成功，出口IP: $IP"
    exit 0
fi

err "代理不可用（连接失败或超时）"
