#!/bin/sh

# 更新软件包列表
echo "更新软件包列表..."
opkg update

# 安装常用软件包
echo "安装常用软件包..."
opkg install vim nano htop curl wget

# 安装网络工具
echo "安装网络工具..."
opkg install iptables-mod-tproxy tcpdump

# 配置开机启动项（示例：启用SSH）
echo "启用SSH服务..."
/etc/init.d/sshd enable
/etc/init.d/sshd start

# 设置时区（示例：北京时间）
echo "设置时区..."
uci set system.@system[0].timezone='CST-8'
uci commit system
/etc/init.d/system reload

# 其他自定义配置
# 在这里添加你的自定义命令或脚本

echo "OpenWRT 安装和配置完成！"

