#!/bin/bash

# 固定参数（和原脚本保持一致）
SUBNET_GATEWAY="172.19.63.253"
SUBNET_NETWORK="172.19.0.0/18"
NIC_LIST=(eth0 eth1)
BASE_TABLE=20

echo "开始清理策略路由..."

for net_name in "${NIC_LIST[@]}"; do
  if [[ "$net_name" != *"lo"* ]]; then
    readarray -t ip_array < <(ip addr show "$net_name" | awk '/inet / && !/127.0.0.1/ {gsub(/\/.*/,"",$2); print $2}')
    for ip_list in "${ip_array[@]}"; do
      last_octet=$(echo $ip_list | awk -F. '{print $4}')
      table_num=$((BASE_TABLE + last_octet))

      # 删除规则和表
      ip rule del from $ip_list table $table_num 2>/dev/null
      ip route flush table $table_num 2>/dev/null

      echo "已清除 IP: $ip_list 使用的策略路由表: $table_num"
    done
  fi
done

echo "✅ 所有策略路由已清空完成。"
