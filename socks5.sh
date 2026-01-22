#!/bin/bash

echo "请输入用户名: "
read -r name

echo "请输入密码: "
read -r passwd

echo "请输入端口号："
read -r port

# 定义接口和配置文件路径
INTERFACE="eth1"
MAIN_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}"
RANGE_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}-range0"
ALIAS_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}:1"
STATE_DIR="/var/lib/socks5"
STATE_FILE="${STATE_DIR}/policy_route.state"
OLD_STATE_FILE="/tmp/socks5_setup.state"
ROUTE_SCRIPT="/usr/local/sbin/socks5-policy-route.sh"
ROUTE_UNIT="/etc/systemd/system/socks5-policy-route.service"

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "错误：找不到网卡 ${INTERFACE}"
    exit 1
fi

if [ ! -f "$MAIN_CONFIG" ]; then
    echo "错误：找不到配置文件 $MAIN_CONFIG"
    exit 1
fi

mkdir -p "$STATE_DIR"

cleanup_state_file() {
    local state_path="$1"

    if [ -f "$state_path" ]; then
        echo "检测到上次运行记录，开始清理旧的策略路由: ${state_path}"
        while read -r old_ip old_dev old_table old_pref old_subnet old_gw; do
            if [ -z "$old_table" ]; then
                continue
            fi
            ip rule del pref "$old_pref" 2>/dev/null
            ip rule del from "$old_ip" table "$old_table" 2>/dev/null
            ip route flush table "$old_table" 2>/dev/null
        done < "$state_path"
        rm -f "$state_path"
    fi
}

cleanup_previous() {
    cleanup_state_file "$STATE_FILE"
    cleanup_state_file "$OLD_STATE_FILE"
}

cleanup_dante_config() {
    if [ -d /etc/danted ] || [ -f /etc/danted/sockd.conf ] || [ -f /etc/init.d/sockd ] || [ -f /lib/systemd/system/sockd.service ]; then
        echo "检测到 Dante 旧配置，开始清理"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop sockd >/dev/null 2>&1
            systemctl disable sockd >/dev/null 2>&1
        fi
        [ -x /etc/init.d/sockd ] && /etc/init.d/sockd stop >/dev/null 2>&1
        rm -f /etc/default/sockd /etc/pam.d/sockd /usr/bin/sockd /etc/init.d/sockd /var/run/sockd.pid
        rm -rf /etc/danted
        if [ -f /lib/systemd/system/sockd.service ]; then
            rm -f /lib/systemd/system/sockd.service
            command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
        fi
        rm -rf /etc/systemd/system/sockd.service.d
    fi
}

cleanup_previous
cleanup_dante_config

# 确保主配置文件中禁用 NetworkManager
if ! grep -q "NM_CONTROLLED=NO" "$MAIN_CONFIG"; then
    echo "NM_CONTROLLED=NO" >> "$MAIN_CONFIG"
    echo "已禁用 NetworkManager 对 ${INTERFACE} 的管理"
fi

# 提取接口 IPv4 地址和前缀
readarray -t IFACE_ADDR_LINES < <(ip -o -4 addr show dev "$INTERFACE" scope global)

if [ ${#IFACE_ADDR_LINES[@]} -eq 0 ]; then
    echo "错误：${INTERFACE} 没有可用的 IPv4 地址"
    exit 1
fi

readarray -t PREFIX_LIST < <(printf '%s\n' "${IFACE_ADDR_LINES[@]}" | awk '{split($4,a,"/"); print a[2]}' | sort -u)
if [ ${#PREFIX_LIST[@]} -ne 1 ]; then
    echo "错误：${INTERFACE} 存在不同前缀，无法自动生成别名配置"
    exit 1
fi
PREFIX="${PREFIX_LIST[0]}"

PRIMARY_IP=$(printf '%s\n' "${IFACE_ADDR_LINES[@]}" | awk '!/secondary/ {split($4,a,"/"); print a[1]; exit}')
if [ -z "$PRIMARY_IP" ]; then
    echo "错误：${INTERFACE} 未找到主 IPv4 地址"
    exit 1
fi

readarray -t SECONDARY_IPS < <(printf '%s\n' "${IFACE_ADDR_LINES[@]}" | awk '/secondary/ {split($4,a,"/"); print a[1]}' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
if [ ${#SECONDARY_IPS[@]} -gt 0 ]; then
    ALIAS_IP="${SECONDARY_IPS[$((${#SECONDARY_IPS[@]} - 1))]}"
else
    readarray -t OTHER_IPS < <(printf '%s\n' "${IFACE_ADDR_LINES[@]}" | awk '{split($4,a,"/"); print a[1]}' | awk -v p="$PRIMARY_IP" '$0!=p' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
    if [ ${#OTHER_IPS[@]} -eq 0 ]; then
        echo "错误：${INTERFACE} 需要至少两个 IPv4 地址以配置别名"
        exit 1
    fi
    ALIAS_IP="${OTHER_IPS[0]}"
fi

# 生成别名配置文件，只保留一个附加 IP
rm -f "$RANGE_CONFIG"
rm -f "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}:"*
cat << EOF > "$ALIAS_CONFIG"
DEVICE="${INTERFACE}:1"
BOOTPROTO=static
IPADDR=${ALIAS_IP}
PREFIX=${PREFIX}
ONBOOT=yes
NM_CONTROLLED=NO
EOF

# 重启网络服务
systemctl restart network

for i in {15..1}
do

        echo  -n  ip添加成功,网络重置中,还需等待 $i 程序继续运行!!!
        echo  -ne "\r\r"        ####echo -e 处理特殊字符  \r 光标移至行首，但不换行
        sleep 1
done


sleep 1

ETH0_PRIMARY=""
if ip link show "eth0" >/dev/null 2>&1; then
    ETH0_PRIMARY=$(ip -o -4 addr show dev "eth0" scope global | awk '!/secondary/ {split($4,a,"/"); print a[1]; exit}')
fi

SOCKS_IPS=()
[ -n "$ETH0_PRIMARY" ] && SOCKS_IPS+=("$ETH0_PRIMARY")
SOCKS_IPS+=("$PRIMARY_IP" "$ALIAS_IP")
jxip=$(printf '%s\n' "${SOCKS_IPS[@]}" | awk '!seen[$0]++' | paste -sd ':' -)
echo "$jxip"

sleep 6

bash install.sh --ip="$jxip" --port=$port --user=$name --passwd=$passwd

echo -n "Socks5代理已经安装完成，等待6秒设置策略路由"
sleep 6

# Get the list of network interfaces
NIC_LIST=(eth0 eth1)
BASE_TABLE=20
BASE_PREF=10000

get_ip_gateway() {
    local ipaddr="$1"
    local netdev="$2"
    local gw

    gw=$(ip route get 1.1.1.1 from "$ipaddr" oif "$netdev" 2>/dev/null | awk '/ via / {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -z "$gw" ]; then
        gw=$(ip route show default dev "$netdev" | awk '/default/ {print $3; exit}')
    fi
    if [ -z "$gw" ]; then
        gw=$(ip route show default | awk '/default/ {print $3; exit}')
    fi

    echo "$gw"
}

write_route_persist() {
    cat <<'EOF' > "$ROUTE_SCRIPT"
#!/bin/bash
STATE_FILE="/var/lib/socks5/policy_route.state"

[ -f "$STATE_FILE" ] || exit 0

while read -r ip_list net_name table_num rule_pref subnet_network subnet_gateway; do
    if [ -z "$table_num" ]; then
        continue
    fi
    ip rule del pref "$rule_pref" 2>/dev/null
    ip rule del from "$ip_list" table "$table_num" 2>/dev/null
    ip route replace default via "$subnet_gateway" dev "$net_name" src "$ip_list" table "$table_num"
    ip route replace "$subnet_network" dev "$net_name" scope link src "$ip_list" table "$table_num"
    ip rule add pref "$rule_pref" from "$ip_list" table "$table_num"
done < "$STATE_FILE"
EOF
    chmod +x "$ROUTE_SCRIPT"

    if [ -n "$(ls -l /sbin/init | grep systemd)" ]; then
        cat <<EOF > "$ROUTE_UNIT"
[Unit]
Description=Restore Socks5 policy routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ROUTE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable socks5-policy-route.service
    else
        if [ -f /etc/rc.d/rc.local ]; then
            grep -q "$ROUTE_SCRIPT" /etc/rc.d/rc.local || echo "$ROUTE_SCRIPT" >> /etc/rc.d/rc.local
            chmod +x /etc/rc.d/rc.local
        fi
    fi
}

> "$STATE_FILE"

for net_name in "${NIC_LIST[@]}"; do
    if ! ip link show "$net_name" >/dev/null 2>&1; then
        continue
    fi
    ip_array=()
    if [ "$net_name" == "eth0" ]; then
        [ -n "$ETH0_PRIMARY" ] && ip_array=("$ETH0_PRIMARY")
    elif [ "$net_name" == "$INTERFACE" ]; then
        ip_array=("$PRIMARY_IP" "$ALIAS_IP")
    else
        readarray -t ip_array < <(ip -o -4 addr show dev "$net_name" scope global | awk '{split($4,a,"/"); print a[1]}' | sort -u)
    fi
    if [ ${#ip_array[@]} -eq 0 ]; then
        continue
    fi

    for ((i=0; i<${#ip_array[@]}; i++)); do
        ip_list="${ip_array[$i]}"
        subnet_network=$(ip -4 route show dev "$net_name" proto kernel scope link | awk -v ip="$ip_list" '$0 ~ ("src " ip) {print $1; exit}')
        if [ -z "$subnet_network" ]; then
            subnet_network=$(ip -4 route show dev "$net_name" scope link | awk '{print $1; exit}')
        fi
        if [ -z "$subnet_network" ]; then
            echo "接口 ${net_name} 未找到直连网段，跳过"
            continue
        fi
        subnet_gateway=$(get_ip_gateway "$ip_list" "$net_name")
        if [ -z "$subnet_gateway" ]; then
            echo "IP ${ip_list} 未找到默认网关，跳过"
            continue
        fi
        # 使用 IP 地址的最后一位作为路由表编号的一部分
        last_octet=$(echo "$ip_list" | awk -F. '{print $4}')
        table_num=$((BASE_TABLE + last_octet))
        rule_pref=$((BASE_PREF + table_num))

        # 清除可能存在的旧规则
        ip rule del from "$ip_list" table "$table_num" 2>/dev/null

        # 添加新的路由规则
        ip route replace default via "$subnet_gateway" dev "$net_name" src "$ip_list" table "$table_num"
        ip route replace "$subnet_network" dev "$net_name" scope link src "$ip_list" table "$table_num"
        ip rule add pref "$rule_pref" from "$ip_list" table "$table_num"

        printf '%s %s %s %s %s %s\n' "$ip_list" "$net_name" "$table_num" "$rule_pref" "$subnet_network" "$subnet_gateway" >> "$STATE_FILE"

        echo "IP: $ip_list 使用路由表: $table_num 网关: $subnet_gateway 网段: $subnet_network"
    done
done

write_route_persist

echo -n "策略路由已经添加完成"
