# Triển khai Kubernetes HA Cluster với 3 Master Node và nhiều Worker Node

**Kubernetes:** v1.36.x  
**CNI:** Calico v3.32.2  
**Container Runtime:** containerd v2.3.5  
**runc:** v1.5.0  
**CNI Plugins:** v1.9.1  
  CSI version 4.13.4  
**Hệ điều hành:** Ubuntu 24.04.5 LTS

---

## 1️⃣ Chuẩn bị trước

**Yêu cầu:**
- 3 Master Nodes và >=1 Worker Node
- Có thể SSH với quyền `root` hoặc `sudo`
- Các node kết nối mạng nội bộ với nhau (kết nối bằng IP và FQDN/Hostname)
- Swap đã tắt hoàn toàn
- Đồng bộ thời gian (NTP)
- Trỏ DNS record `tke-k8s` về IP Master-01
- 
```bash
sudo apt update -y && sudo apt upgrade -y
```

```bash
rm -rf /etc/netplan/50*
mv /etc/netplan/99* /etc/netplan/k8s.yaml

sudo systemctl restart systemd-resolved
sudo systemctl enable systemd-resolved
sudo ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf

sudo netplan apply

sudo timedatectl set-timezone Asia/Ho_Chi_Minh

sudo apt install -y chrony

cat <<'EOF' | sudo tee /etc/chrony/chrony.conf
confdir /etc/chrony/conf.d
server 0.asia.pool.ntp.org iburst
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

sudo systemctl restart chrony
sudo systemctl enable chrony

sudo sed -i "2i 127.0.1.1 $HOSTNAME" /etc/hosts
sudo sed -i '3i\\' /etc/hosts

sudo apt update -y && sudo apt upgrade -y
```

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/containerd.conf

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

---

## 2️⃣ Cài containerd và Kubernetes packages trên tất cả các node

**Thực hiện các bước sau trên từng node (Master & Worker).**

### Cài containerd v2.3.5

```bash
wget https://github.com/containerd/containerd/releases/download/v2.3.5/containerd-2.3.5-linux-amd64.tar.gz -P /tmp/

sudo tar -C /usr/local -xzf /tmp/containerd-2.3.5-linux-amd64.tar.gz
```

Cài service cho containerd:

```bash
sudo wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service \
-O /etc/systemd/system/containerd.service

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
```

### Cài runc v1.5.0

```bash
wget https://github.com/opencontainers/runc/releases/download/v1.5.0/runc.amd64 \
-O /tmp/runc

sudo install -m 755 /tmp/runc /usr/local/sbin/runc
```

### Cài CNI Plugins v1.9.1

```bash
wget https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz \
-P /tmp/

sudo mkdir -p /opt/cni/bin

sudo tar -C /opt/cni/bin \
-xzf /tmp/cni-plugins-linux-amd64-v1.9.1.tgz
```

### Cấu hình containerd

```bash
sudo mkdir -p /etc/containerd

containerd config default | sudo tee /etc/containerd/config.toml

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
/etc/containerd/config.toml

sudo systemctl restart containerd
```

### Cài Kubernetes v1.36.x

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg
```

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
| sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

```bash
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
| sudo tee /etc/apt/sources.list.d/kubernetes.list
```

```bash
sudo apt update
```

```bash
sudo apt install -y kubelet kubeadm kubectl
```

```bash
sudo apt-mark hold kubelet kubeadm kubectl
```

Reboot node:

```bash
sudo reboot
```

---

## 3️⃣ Khởi tạo Master node đầu tiên

```bash
# Bạn cần chuẩn bị:
# - Control Plane Endpoint (VD: 10.10.10.11:6443)
# - Pod Network CIDR (VD: 192.168.0.0/16)
# - Service CIDR (VD: 10.96.0.0/12)
# - Danh sách các SAN (DNS hoặc IP)
```

```bash
sudo kubeadm init \
  --pod-network-cidr "<POD_CIDR>" \
  --control-plane-endpoint "<ENDPOINT:PORT>" \
  --apiserver-cert-extra-sans "<SAN1>,<SAN2>,..." \
  --upload-certs
```

> Example:

```bash
kubeadm init \
--pod-network-cidr 192.168.0.0/16 \
--service-cidr 10.96.0.0/12 \
--control-plane-endpoint tke-k8s.tanlv.io.vn:6443 \
--apiserver-cert-extra-sans tke-k8s.k8s.local \
--apiserver-cert-extra-sans tke-k8s.tanlv.io.vn \
--apiserver-cert-extra-sans 10.0.0.30 \
--apiserver-cert-extra-sans master01 \
--apiserver-cert-extra-sans master02 \
--apiserver-cert-extra-sans master03 \
--apiserver-cert-extra-sans 10.0.0.11 \
--apiserver-cert-extra-sans 10.0.0.12 \
--apiserver-cert-extra-sans 10.0.0.13 \
--apiserver-cert-extra-sans 61.14.236.212 \
--upload-certs \
--dry-run
```

Sau khi kiểm tra `--dry-run` thành công, chạy lại command và bỏ:

```bash
--dry-run
```

Cấu hình kubectl:

```bash
mkdir -p $HOME/.kube

sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config

sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## 4️⃣ Cài Calico v3.32.2 làm CNI plugin

```bash
kubectl apply -f \
https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/tigera-operator.yaml
```

Chờ một lúc để Tigera Operator khởi tạo.

```bash
sleep 10
```

Sau đó chạy:

```bash
kubectl apply -f \
https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/custom-resources.yaml
```

---

## 5️⃣ Tạo lệnh join và chứng chỉ

Tạo join command cho Worker:

```bash
kubeadm token create --print-join-command > /tmp/node-join-cmd
```

Tạo join command cho Master:

```bash
cp /tmp/node-join-cmd /tmp/master-join-cmd
```

Generate certificate key:

```bash
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null \
| grep -E '^[a-f0-9]{64}$')
```

Thêm thông tin Control Plane vào join command:

```bash
sed -i "s/\$/ --control-plane --certificate-key $CERT_KEY/" \
/tmp/master-join-cmd
```

Chuẩn bị certificate:

```bash
mkdir -p /tmp/cluster-certs/etcd

chmod -R 777 /tmp/cluster-certs

cp /etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*} \
/tmp/cluster-certs/

cp /etc/kubernetes/pki/etcd/ca.* \
/tmp/cluster-certs/etcd

cp /tmp/master-join-cmd \
/tmp/node-join-cmd \
/tmp/cluster-certs/
```

```bash
sudo chown -R ubuntu:ubuntu /tmp/cluster-certs
```

---

## 6️⃣ Thêm các Master node còn lại

**Trên Master Node 2 và Master Node 3:**

Copy certificate từ Master 1:

```bash
scp -r -i id_rsa \
ubuntu@<MASTER1_IP>:/tmp/cluster-certs ~/
```

Tạo thư mục PKI:

```bash
sudo mkdir -p /etc/kubernetes/pki/etcd/
```

Copy Kubernetes certificate:

```bash
sudo cp ~/cluster-certs/*.crt \
~/cluster-certs/*.key \
~/cluster-certs/*.pub \
/etc/kubernetes/pki/
```

Copy etcd CA:

```bash
sudo cp ~/cluster-certs/etcd/ca.* \
/etc/kubernetes/pki/etcd/
```

> Run join command for Master Node:

```bash
cat ~/cluster-certs/master-join-cmd
```

Copy command được hiển thị và chạy bằng `sudo`.

---

## 7️⃣ Thêm các Worker node

**Trên mỗi Worker Node:**

Lấy Worker join command:

```bash
cat /tmp/cluster-certs/node-join-cmd
```

> Run join command for Worker Node.

Sau khi các Master đã join hoàn tất:

**Trỏ lại DNS record `tke-k8s` về IP VIP.**

---

## 8️⃣ Kiểm tra Cluster

Kiểm tra node:

```bash
kubectl get nodes -o wide
```

Kiểm tra toàn bộ Pod:

```bash
kubectl get pods -A
```

Kiểm tra version:

```bash
kubectl version
```

```bash
kubeadm version
```

```bash
kubelet --version
```

```bash
containerd --version
```

```bash
runc --version
```

## 9 Cài INGRESS

deploy metallb:
```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
```

```
vi metallb-config.yaml
```

```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.200-10.0.0.249  # Dải IP được chọn
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec: {}
```

```
kubectl apply -f metallb-config.yaml
```

cai Ingress Controller: dung helm

B1: caif helm
```
sudo snap install helm --classic
```
B2: Setup NGINX ingress by Helm
```
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
```
## KIỂM TRA INGRESS

```
root@master-01:~# kubectl get pods -n ingress-nginx
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-645b679d5c-5vqr6   1/1     Running   0          3m51s
```

```
root@master-01:~# kubectl get ingressclass
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       3m15s
```

```
root@master-01:~# kubectl get svc -n ingress-nginx
NAME                                 TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller             LoadBalancer   10.99.236.43   10.0.0.200    80:32491/TCP,443:31001/TCP   2m36s
ingress-nginx-controller-admission   ClusterIP      10.97.97.188   <none>        443/TCP                      2m36s
```

## 10. Cai CSI

```
helm repo add csi-driver-nfs https://kubernetes-csi.github.io/csi-driver-nfs

helm repo update csi-driver-nfs

helm install csi-driver-nfs \
  csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --version 4.13.4
```

INSTALL NFS CLINET TRÊN CÁC NODE K8S
```
install nfs-common
```

# check

```
kubectl -n kube-system get pod -o wide -l app=csi-nfs-controller

kubectl -n kube-system get pod -o wide -l app=csi-nfs-node
```

```
vi sc-nfs.yaml
```

```
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.0.0.70
  share: /data_k8s
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

```
vi pvc-pod-test.yaml
```

```
aapiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs-csi
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 10Gi
```


```
kubectl apply -f sc-nfs.yaml
kubectl apply -f pvc-pod-test.yaml
```

```
root@master-01:~# kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                 STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-41de37a4-86ec-41c0-99fb-bef2e1db5e2a   5Gi        RWX            Delete           Bound    default/nfs-csi-pvc   nfs-csi-sc     <unset>                          147m
root@master-01:~#
root@master-01:~#
root@master-01:~# kubectl get pvc
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
nfs-csi-pvc   Bound    pvc-41de37a4-86ec-41c0-99fb-bef2e1db5e2a   5Gi        RWX            nfs-csi-sc     <unset>                 147m
root@master-01:~#
root@master-01:~#
root@master-01:~#
root@master-01:~# kubectl get pod
NAME          READY   STATUS    RESTARTS      AGE
nfs-csi-pod   1/1     Running   2 (27m ago)   148m
root@master-01:~#
```
