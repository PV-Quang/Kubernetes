#!/usr/bin/env bash
set -euo pipefail

########################################
# CUSTOMER CONFIGURATION (EDIT HERE ONLY)
########################################
# ---- Network ----
NET_IFACE="ens192"
IP_ADDR="40.0.0.23"
CIDR="24"
GATEWAY="40.0.0.1"
DNS_ADDR="40.0.0.250"
DNS_SEARCH="pvq.lab"

# ---- Hostname ----
HOSTNAME_FQDN="worker-03.pvq.lab"

########################################
# END CUSTOMER CONFIGURATION
########################################

exec > >(tee -a /var/log/k8s.log) 2>&1

echo "[INFO] Start at $(date)"

rm -rf /etc/netplan/*

cat > /etc/netplan/k8s.yaml <<EOF
network:
  version: 2
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${IP_ADDR}/${CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS_ADDR}
        search:
          - ${DNS_SEARCH}
EOF

netplan apply

systemctl enable --now systemd-resolved.service
systemctl restart systemd-resolved.service
ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf

hostnamectl set-hostname "$HOSTNAME_FQDN"
timedatectl set-timezone Asia/Ho_Chi_Minh

echo "[INFO] Waiting for network..."
for i in $(seq 1 30); do
  if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
    echo "[INFO] Network OK"
    break
  fi
  sleep 2
done

echo "[INFO] Waiting for update..."
sleep 20
apt update -y && apt upgrade -y
apt install -y chrony
systemctl enable --now chrony

cat > /etc/chrony/chrony.conf <<'EOF'
confdir /etc/chrony/conf.d
server 0.asia.pool.ntp.org
sourcedir /run/chrony-dhcp
sourcedir /etc/chrony/sources.d
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOF

systemctl restart chrony
systemctl enable chrony
sed -i "2i 127.0.1.1 $HOSTNAME" /etc/hosts
sed -i '3i\\' /etc/hosts

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
echo -e "overlay\nbr_netfilter" | tee /etc/modules-load.d/containerd.conf
modprobe overlay
modprobe br_netfilter
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

wget https://github.com/containerd/containerd/releases/download/v2.1.4/containerd-2.1.4-linux-amd64.tar.gz -P /tmp/
tar -C /usr/local -xzf /tmp/containerd-2.1.4-linux-amd64.tar.gz
wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -O /etc/systemd/system/containerd.service
systemctl daemon-reload
systemctl enable --now containerd
wget https://github.com/opencontainers/runc/releases/download/v1.3.2/runc.amd64 -O /tmp/runc
install -m 755 /tmp/runc /usr/local/sbin/runc
wget https://github.com/containernetworking/plugins/releases/download/v1.8.0/cni-plugins-linux-amd64-v1.8.0.tgz -P /tmp/
mkdir -p /opt/cni/bin
tar -C /opt/cni/bin -xzf /tmp/cni-plugins-linux-amd64-v1.8.0.tgz
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
apt install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

echo "[INFO] Waiting for update..."
sleep 20
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "[INFO] Join node begin..."
sleep 3

mkdir -p /root/k8s
wget -O /root/k8s/node-join-cmd.sh http://master-01:8080/node-join-cmd
chmod +x /root/k8s/node-join-cmd.sh
/root/k8s/node-join-cmd.sh

echo "[INFO] Join node OK"
sleep 10

echo "[INFO] Done at $(date)"
