#!/usr/bin/env bash
set -euo pipefail

########################################
# CUSTOMER CONFIGURATION (EDIT HERE ONLY)
########################################
# ---- Network ----
NET_IFACE="ens192"
IP_ADDR="40.0.0.14"
CIDR="24"
GATEWAY="40.0.0.1"
DNS_ADDR="40.0.0.250"
DNS_SEARCH="pvq.lab"

# ---- Hostname ----
HOSTNAME_FQDN="master-04.pvq.lab"

# ---- Kubernetes INIT ----
K8S_INIT_CMD="kubeadm init \
--pod-network-cidr 192.168.0.0/16 \
--service-cidr 10.96.0.0/12 \
--control-plane-endpoint master-04.pvq.lab \
--apiserver-cert-extra-sans master-04.pvq.lab \
--apiserver-cert-extra-sans 40.0.0.14 \
--apiserver-cert-extra-sans master-04 \
--apiserver-cert-extra-sans 61.14.236.249"

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
sed -i "2i 127.0.1.1 $HOSTNAME_FQDN" /etc/hosts
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
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

eval "$K8S_INIT_CMD"

sleep 10
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf
echo "[INFO] Waiting for Kubernetes API to be ready..."
for i in {1..60}; do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    echo "[INFO] Kubernetes API is ready"
    break
  fi
  echo "[INFO] API not ready yet ($i/60), retrying..."
  sleep 5
done

echo "[INFO] Applying Calico CNI..."

kubectl apply --validate=false -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml

echo "[INFO] Waiting for Tigera Installation API to be served..."

for i in {1..60}; do
  if kubectl api-resources --api-group=operator.tigera.io \
     | grep -q Installation; then
    echo "[INFO] Tigera Installation API is ready"
    break
  fi
  echo "[INFO] Installation API not ready yet ($i/60)"
  sleep 5
done


kubectl apply --validate=false -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/custom-resources.yaml
sleep 10
echo "[INFO]Run calico done"

kubeadm token create --print-join-command > /root/node-join-cmd
cp /root/node-join-cmd /root/master-join-cmd

CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | grep -E '^[a-f0-9]{64}$')
sed -i "s/\$/ --control-plane --certificate-key $CERT_KEY/" /root/master-join-cmd
mkdir -p /root/cluster-certs/etcd
chmod -R 777 /root/cluster-certs
cp /etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*} /root/cluster-certs/
cp /etc/kubernetes/pki/etcd/ca.* /root/cluster-certs/etcd
cp /root/master-join-cmd /root/node-join-cmd /root/cluster-certs/

nohup python3 -m http.server 8080 --directory /cluster-certs/ &

echo "[INFO] Done at $(date)"
