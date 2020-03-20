#!/bin/bash

## 解析主机名：
echo " k8s-prct 192.168.211.131 " >> /etc/hosts

## 更新 PATH 变量
echo 'PATH=/opt/k8s/bin:$PATH' >>/root/.bashrc
source /root/.bashrc

## 安装依赖包
yum install -y epel-release
yum install -y chrony conntrack ipvsadm ipset jq iptables curl sysstat libseccomp wget socat git

## 关闭防火墙，清理防火墙规则，设置默认转发策略：
systemctl stop firewalld
systemctl disable firewalld
iptables -F && iptables -X && iptables -F -t nat && iptables -X -t nat
iptables -P FORWARD ACCEPT

## 关闭 swap 分区，否则kubelet 会启动失败(可以设置 kubelet 启动参数 --fail-swap-on 为 false 关闭 swap 检查)：
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab 

## 关闭 SELinux，否则 kubelet 挂载目录时可能报错 `Permission denied`：
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

## 优化内核参数
cat > kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_recycle=0
net.ipv4.neigh.default.gc_thresh1=1024
net.ipv4.neigh.default.gc_thresh1=2048
net.ipv4.neigh.default.gc_thresh1=4096
vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
fs.file-max=52706963
fs.nr_open=52706963
net.ipv6.conf.all.disable_ipv6=1
net.netfilter.nf_conntrack_max=2310720
EOF
cp kubernetes.conf  /etc/sysctl.d/kubernetes.conf
sysctl -p /etc/sysctl.d/kubernetes.conf

+ 关闭 tcp_tw_recycle，否则与 NAT 冲突，可能导致服务不通；

## 设置系统时区
timedatectl set-timezone Asia/Shanghai

## 设置系统时钟同步
systemctl enable chronyd
systemctl start chronyd

# 将当前的 UTC 时间写入硬件时钟
timedatectl set-local-rtc 0

# 重启依赖于系统时间的服务
systemctl restart rsyslog 
systemctl restart crond

## 关闭无关的服务
systemctl stop postfix && systemctl disable postfix

## 创建相关目录：
mkdir -p /opt/k8s/{bin,work} /etc/{kubernetes,etcd}/cert

## 分发集群配置参数脚本 后续使用的环境变量都定义在文件 [environment.sh](manifests/environment.sh) 中，请根据**自己的机器、网络情况**修改。然后拷贝到**所有**节点：
## 先修改manifests/environment.sh
source environment.sh
for node_ip in ${NODE_IPS[@]}
  do
    echo ">>> ${node_ip}"
    scp environment.sh root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
  done

## 升级内核
git clone --branch v1.16.6 --single-branch --depth 1 https://github.com/kubernetes/kubernetes
cd kubernetes
KUBE_GIT_VERSION=v1.16.6 ./build/run.sh make kubelet GOFLAGS="-tags=nokmem"

rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
# 安装完成后检查 /boot/grub2/grub.cfg 中对应内核 menuentry 中是否包含 initrd16 配置，如果没有，再安装一次！
yum --enablerepo=elrepo-kernel install -y kernel-lt

# 设置开机从新内核启动
grub2-set-default 0

##重启机器：
sync
reboot


