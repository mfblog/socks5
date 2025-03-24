#!/bin/bash
# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本。"
    exit 1
fi

set -e  # 任何命令出错则退出

echo "创建 2G swap 文件..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "swap 已启用。"

echo "下载安装脚本..."
wget --no-check-certificate -O install.sh https://raw.github.com/Lozy/danted/master/install_centos.sh

echo "调整安装脚本，设置 make 使用单线程..."
sed -i 's/make -j[0-9]*/make -j1/g' install.sh

echo "获取服务器 IP 地址..."
ip=$(ifconfig -a | grep inet | grep -v 127.0.0.1 | grep -v inet6 | awk '{print $2}' | tr -d "addr:")
jxip=$(echo $ip | sed 's/ /:/g')
echo "检测到 IP 地址: $jxip"

echo "等待 6 秒..."
sleep 6

echo "执行安装脚本..."
bash install.sh --ip="$jxip" --port=2016 --user=aa1111 --passwd=aa1111

echo "脚本执行完毕。"