#!/bin/bash

echo "请输入用户名: "
read name

echo "请输入密码: "
read passwd

echo "请输入端口号："
read port

# 定义接口和配置文件路径
INTERFACE="eth1"
MAIN_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}"
RANGE_CONFIG="/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}-range0"

# 确保主配置文件中禁用 NetworkManager
if ! grep -q "NM_CONTROLLED=NO" "$MAIN_CONFIG"; then
    echo "NM_CONTROLLED=NO" >> "$MAIN_CONFIG"
    echo "已禁用 NetworkManager 对 ${INTERFACE} 的管理"
fi

# 提取 eth1 的 IPv4 地址列表
IP_ADDRESSES=($(ip -4 -o addr show eth1 | awk '{gsub(/\/.*/, "", $4); print $4}'))

# 检查是否至少有两个 IP 地址
if [ ${#IP_ADDRESSES[@]} -lt 2 ]; then
    echo "错误：${INTERFACE} 需要至少两个 IPv4 地址以定义范围"
    exit 1
fi

# 设置起始和结束 IP
IPADDR_START=${IP_ADDRESSES[0]}
IPADDR_END=${IP_ADDRESSES[1]}

# 生成范围配置文件
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

for i in {15..1}
do

        echo  -n  ip添加成功,网络重置中,还需等待 $i 程序继续运行!!!
        echo  -ne "\r\r"        ####echo -e 处理特殊字符  \r 光标移至行首，但不换行
        sleep 1
done


sleep 1

ip=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
jxip=$(echo $ip | sed 's/ /:/g')
echo "$jxip"

sleep 6

bash install.sh --ip="$jxip" --port=$port --user=$name --passwd=$passwd

echo -n "Socks5代理已经安装完成，等待6秒设置策略路由"
sleep 6

SUBNET_GATEWAY=$(ip route show default | awk '/default/ {print $3; exit}')
#SUBNET_GATEWAY="172.19.63.253"
SUBNET_NETWORK=$(ip route | awk '/src/ {split($1, net, "/"); print net[1] "/" net[2]; exit}')
#SUBNET_NETWORK="172.19.0.0/18"

# Get the list of network interfaces
NIC_LIST=(eth0 eth1)
BASE_TABLE=20

for net_name in "${NIC_LIST[@]}"; do
    if [[ "$net_name" != *"lo"* ]]; then
        readarray -t ip_array < <(ip addr show "$net_name" | awk '/inet / && !/127.0.0.1/ {gsub(/\/.*/,"",$2); print $2}')
        for ((i=0; i<${#ip_array[@]}; i++)); do
            ip_list="${ip_array[$i]}"
            # 使用IP地址的最后一位作为路由表编号的一部分
            last_octet=$(echo $ip_list | awk -F. '{print $4}')
            table_num=$((BASE_TABLE + last_octet))
            
            # 清除可能存在的旧规则
            ip rule del from $ip_list table $table_num 2>/dev/null
            ip route flush table $table_num 2>/dev/null
            
            # 添加新的路由规则
            ip route add default via $SUBNET_GATEWAY dev $net_name table $table_num
            ip route add $SUBNET_NETWORK dev $net_name table $table_num
            ip rule add from $ip_list table $table_num
            
            echo "IP: $ip_list 使用路由表: $table_num"
        done
    fi
done

echo -n "策略路由已经添加完成"
