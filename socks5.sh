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
echo $jxip

sleep 6

bash install.sh --ip="$jxip" --port=$port --user=$name --passwd=$passwd

echo -n Socks5代理已经安装完成，等待6秒设置策略路由
sleep 6

#SUBNET_GATEWAY=$(ip route show default | awk '/default/ {print $3; exit}')
SUBNET_GATEWAY="172.19.63.253"
#SUBNET_NETWORK=$(ip route | awk '/src/ {split($1, net, "/"); print net[1] "/" net[2]; exit}')
SUBNET_NETWORK="172.19.0.0/18"

# Get the list of network interfaces
NIC_LIST=($(ip link show | awk -F': ' '!/^[0-9]: lo/{print $2}'))
s=20
# Loop through each network interface
for net_name in "${NIC_LIST[@]}"; do
    if [[ "$net_name" != *"lo"* ]]; then
        ip_address=$(ip addr show "$net_name" | awk '/inet / && !/127.0.0.1/{gsub(/\/.*/,"",$2); print $2}')
        # Generate a unique route table number based on the network interface index
        route_table=$(( ${#NIC_LIST[@]} - ${!net_name} + 10 ))

        s=$((s+1))
        ip route add default via 172.19.63.253 dev $net_name table $s
        ip route add 172.19.0.0/18 dev $net_name table $s
        ip rule add from $ip_address table $s
    fi
done

echo -n 策略路由已经添加完成
