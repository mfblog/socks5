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

# 定义三个内网IP（请根据实际情况修改）
ips=( $(ifconfig -a | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:") )

# 创建启动脚本
echo '#!/bin/bash' > /etc/rc.d/init.d/ci_gost
for ip in "${ips[@]}"; do
    echo "/usr/local/gost/gost -D -L=aa1111:aa1111@${ip}:2016?timeout=30 &" >> /etc/rc.d/init.d/ci_gost
    echo "<${ip}:2016:aa1111:aa1111>" >> /tmp/s5
done
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
for ip in "${ips[@]}"; do
    iptables -A INPUT -p tcp --dport 2016 -j ACCEPT
    iptables -A INPUT -p udp --dport 2016 -j ACCEPT
done

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
