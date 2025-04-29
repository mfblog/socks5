#!/bin/bash

# 配置参数
INTERFACE="eth1"                  # 主网络接口
MAIN_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}"
RANGE_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}-range0"
BASE_TABLE=20                     # 路由表起始编号
NIC_LIST=("eth0" "$INTERFACE")    # 需要策略路由的接口列表

# 函数：检查IP是否已生效
check_ip_online() {
    local target_ip=$1
    for i in {1..10}; do
        if ip a show dev "$INTERFACE" | grep -qw "$target_ip"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 第一部分：配置多IP范围
echo "▌ 阶段1：配置网络接口多IP范围"
# 禁用NetworkManager控制
if ! grep -q "NM_CONTROLLED=NO" "$MAIN_CONFIG"; then
    echo "NM_CONTROLLED=NO" >> "$MAIN_CONFIG"
    echo "→ 已禁用NetworkManager对 ${INTERFACE} 的管理"
fi

# 获取现有IPv4地址
IP_ADDRESSES=($(ip -4 -o addr show $INTERFACE | awk '{gsub(/\/.*/, "", $4); print $4}'))
if [ ${#IP_ADDRESSES[@]} -lt 2 ]; then
    echo "错误：${INTERFACE} 需要至少两个IPv4地址" >&2
    exit 1
fi

# 生成范围配置
IPADDR_START=${IP_ADDRESSES[0]}
IPADDR_END=${IP_ADDRESSES[1]}
cat << EOF > "$RANGE_CONFIG"
DEVICE="${INTERFACE}-range0"
BOOTPROTO=static
IPADDR_START=${IPADDR_START}
IPADDR_END=${IPADDR_END}
PREFIX=24
CLONENUM_START=1
NM_CONTROLLED=NO
EOF

# 重启网络服务
systemctl restart network
echo "→ 网络服务已重启，等待IP生效..."

# 验证IP配置
if ! check_ip_online "$IPADDR_START"; then
    echo "错误：IP地址 $IPADDR_START 未生效" >&2
    exit 2
fi

# 第二部分：策略路由配置
echo -e "\n▌ 阶段2：配置策略路由"
SUBNET_GATEWAY=$(ip route show default | awk '/default/ {print $3; exit}')
SUBNET_NETWORK=$(ip route | awk '/src/ {split($1, net, "/"); print net[1] "/" net[2]; exit}')

for net_name in "${NIC_LIST[@]}"; do
    [[ "$net_name" == *"lo"* ]] && continue
    
    echo "处理接口：$net_name"
    readarray -t ip_array < <(ip -4 -o addr show $net_name 2>/dev/null | awk '{gsub(/\/.*/, "", $4); print $4}')
    
    [ ${#ip_array[@]} -eq 0 ] && {
        echo "  警告：未找到有效IP，跳过"
        continue
    }

    for ip in "${ip_array[@]}"; do
        last_octet=$(cut -d. -f4 <<< "$ip")
        table_num=$((BASE_TABLE + last_octet))
        
        # 清除旧配置
        ip rule del from "$ip" table $table_num 2>/dev/null
        ip route flush table $table_num 2>/dev/null
        
        # 设置新路由
        echo "  IP: $ip → 路由表: $table_num"
        ip route add default via "$SUBNET_GATEWAY" dev $net_name table $table_num
        ip route add "$SUBNET_NETWORK" dev $net_name table $table_num
        ip rule add from "$ip" table $table_num
    done
done

# 验证输出
echo -e "\n▌ 最终路由规则："
ip rule | grep -vE "local|default"
echo -e "\n▌ 路由表内容："
for table in $(ip rule | awk '/lookup/ {print $NF}' | sort -u); do
    echo "[表 $table]"
    ip route show table $table
done
