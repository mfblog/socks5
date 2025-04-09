#!/bin/bash
echo "同步网络时间中…"
yum install -y ntpdate
ntpdate -u cn.pool.ntp.org
hwclock -w
mv /etc/localtime /etc/localtime.bak
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
date -R

# 清理现有gost进程
if ps -ef|grep "gost"|egrep -v grep >/dev/null; then
    ps -ef|grep gost|grep -v grep|awk '{print $2}'|xargs kill -9
fi

# 清理旧配置文件
[ -f "/etc/rc.d/init.d/ci_gost" ] && rm -f /etc/rc.d/init.d/ci_gost
[ -f "/tmp/s5" ] && rm -f /tmp/s5
[ -d "/usr/local/gost" ] && rm -rf /usr/local/gost && mkdir -p /usr/local/gost

# 安装依赖
rpm -qa|grep "wget" &> /dev/null || yum -y install wget

# 下载并安装gost
wget --no-check-certificate -P /tmp http://chumo.site/zyysk5/gost.tar.gz
tar -zmxf /tmp/gost.tar.gz -C /usr/local/gost/
chmod +x /usr/local/gost/gost

# 创建用户及指定 UID
useradd -u 1001 aa1111
useradd -u 1002 aa1112
useradd -u 1003 aa1113

# 可选：为每个用户设置初始密码
echo "123456" | passwd --stdin aa1111
echo "123456" | passwd --stdin aa1112
echo "123456" | passwd --stdin aa1113

echo "用户创建完成：aa1111 (1001), aa1112 (1002), aa1113 (1003)"

# 定义三个内网IP（请根据实际情况修改）
ips=( $(ifconfig -a | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:") )

# 创建启动脚本
# 定义用户数组
users=(aa1111 aa1112 aa1113)

# 创建启动脚本文件
echo '#!/bin/bash' > /etc/rc.d/init.d/ci_gost

# 初始化索引
index=0

# 循环 IP 地址（假设你已经定义好了 ips 数组）
for ip in "${ips[@]}"; do
    user=${users[$index]}
    echo "/usr/local/gost/gost -D -L=${user}:${user}@${ip}:2016?timeout=30 &" >> /etc/rc.d/init.d/ci_gost
    echo "<${ip}:2016:${user}:${user}>" >> /tmp/s5

    # 用户轮换
    index=$(( (index + 1) % ${#users[@]} ))
done

# 设置脚本执行权限
chmod +x /etc/rc.d/init.d/ci_gost

# 配置防火墙
yum install -y iptables iptables-services
systemctl stop firewalld 2>/dev/null
systemctl mask firewalld 2>/dev/null
systemctl enable iptables
systemctl start iptables

# 清空现有规则
iptables -F
iptables -t nat -F
iptables -X
iptables -t nat -X

# 设置新规则
# user1 对应 172.19.38.111
iptables -t mangle -A OUTPUT -m owner --uid-owner 1001 -j MARK --set-mark 1001
iptables -t nat -A POSTROUTING -m mark --mark 1001 -j SNAT --to-source 172.19.38.111
iptables -t nat -A PREROUTING -d 172.19.38.111 -p tcp --dport 30010 -j DNAT --to-destination 172.19.38.111:2016
iptables -t nat -A PREROUTING -d 172.19.38.111 -p udp --dport 30010 -j DNAT --to-destination 172.19.38.111:2016

# user2 对应 172.19.38.112
iptables -t mangle -A OUTPUT -m owner --uid-owner 1002 -j MARK --set-mark 1002
iptables -t nat -A POSTROUTING -m mark --mark 1002 -j SNAT --to-source 172.19.38.112
iptables -t nat -A PREROUTING -d 172.19.38.112 -p tcp --dport 30011 -j DNAT --to-destination 172.19.38.112:2016
iptables -t nat -A PREROUTING -d 172.19.38.112 -p udp --dport 30011 -j DNAT --to-destination 172.19.38.112:2016

# user3 对应 172.19.38.113
iptables -t mangle -A OUTPUT -m owner --uid-owner 1003 -j MARK --set-mark 1003
iptables -t nat -A POSTROUTING -m mark --mark 1003 -j SNAT --to-source 172.19.38.113
iptables -t nat -A PREROUTING -d 172.19.38.113 -p tcp --dport 30012 -j DNAT --to-destination 172.19.38.113:2016
iptables -t nat -A PREROUTING -d 172.19.38.113 -p udp --dport 30012 -j DNAT --to-destination 172.19.38.113:2016


iptables -L

# 保存防火墙规则
service iptables save
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -p >/dev/null

# 设置开机启动
echo "/etc/rc.d/init.d/ci_gost" >> /etc/rc.local
chmod +x /etc/rc.local

# 立即启动服务
source /etc/rc.d/init.d/ci_gost

echo "配置完成！代理信息："
cat /tmp/s5
