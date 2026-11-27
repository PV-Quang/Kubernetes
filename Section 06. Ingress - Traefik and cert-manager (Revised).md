# Buổi 06 - Helm, MetalLB, Traefik Ingress Controller và cert-manager trên Kubernetes v1.35

## 1. Mục tiêu của buổi học

Ở các buổi trước, học viên đã biết cách triển khai một cụm Kubernetes bằng `kubeadm`, hiểu các workload như Pod, Deployment, DaemonSet, StatefulSet, Job, CronJob; biết Service nội bộ như `ClusterIP`, `NodePort`, `Headless`, `ExternalName`; biết cách sử dụng ConfigMap, Secret, Volume, PVC, StorageClass và CSI NFS.

Buổi này mở khóa một nhóm kiến thức mới: cách triển khai các thành phần mở rộng vào cluster bằng Helm, cách cấp địa chỉ IP truy cập từ bên ngoài cho môi trường bare-metal/on-premise bằng MetalLB, và cách đưa ứng dụng web ra ngoài thông qua Traefik Ingress Controller.

Sau buổi học, học viên cần nắm được:

- Helm là gì và vì sao Helm thường được dùng để cài các thành phần phức tạp trong Kubernetes.
- Các khái niệm cơ bản của Helm: Chart, Repository, Release, Values.
- MetalLB giải quyết vấn đề gì trong môi trường Kubernetes on-premise.
- Vì sao Service type `LoadBalancer` trên on-premise thường bị trạng thái `<pending>` nếu không có thành phần cấp IP.
- Cách cài MetalLB bằng Helm.
- Cách cấu hình `IPAddressPool` và `L2Advertisement` cho MetalLB ở Layer 2 mode.
- Ingress là gì và khác gì so với Service.
- Vì sao chỉ tạo Ingress object là chưa đủ, mà phải có Ingress Controller.
- Cách cài Traefik Ingress Controller bằng Helm.
- Cách publish một ứng dụng web ra ngoài qua HTTP.
- Cách publish một ứng dụng web ra ngoài qua HTTPS bằng TLS Secret.
- Hiểu Ingress NGINX EOL và lý do chọn Traefik.
- Hiểu cert-manager, Issuer, ClusterIssuer, Certificate và tự động cấp/gia hạn TLS Secret.
- Cách kiểm tra, troubleshoot và dọn dẹp tài nguyên sau bài lab.

## 2. Phạm vi kiến thức của buổi học

### 2.1. Kiến thức đã được phép sử dụng từ các buổi trước

Buổi này được phép sử dụng lại các kiến thức đã học:

- Cluster, Node, Control Plane, Worker Node.
- kube-apiserver, kubelet, scheduler, controller-manager, etcd ở mức kiến trúc.
- Namespace.
- Pod.
- Deployment.
- DaemonSet.
- Service `ClusterIP`, `NodePort`.
- DNS nội bộ qua CoreDNS.
- ConfigMap.
- Secret.
- Volume.
- YAML manifest.
- `kubectl apply`, `kubectl get`, `kubectl describe`, `kubectl logs`, `kubectl exec`.

### 2.2. Kiến thức mới được mở khóa trong buổi này

Buổi này mở khóa thêm:

- Helm.
- Helm Chart.
- Helm Repository.
- Helm Release.
- Helm Values.
- `helm install`.
- `helm upgrade --install`.
- `helm list`.
- `helm status`.
- `helm show values`.
- Service type `LoadBalancer` trong ngữ cảnh on-premise.
- MetalLB.
- MetalLB Controller.
- MetalLB Speaker.
- `IPAddressPool`.
- `L2Advertisement`.
- Ingress.
- Ingress Controller.
- IngressClass.
- Traefik Ingress Controller.
- TLS Secret cho Ingress.
- EntryPoint, Middleware (RedirectScheme và rewrite path).
- cert-manager, CRD, Issuer, ClusterIssuer, Certificate, ACME HTTP-01/DNS-01 ở mức cơ bản.

### 2.3. Những nội dung chưa đi sâu trong buổi này

Để giữ đúng tiến trình kiến thức, buổi này chưa đi sâu vào:

- Gateway API.
- ExternalDNS.
- Cloud Controller Manager của AWS, Azure, GCP.
- AWS Load Balancer Controller.
- Azure Application Gateway Ingress Controller.
- GKE Ingress/Gateway.
- Middleware nâng cao, IngressRoute và Gateway API lab chuyên sâu.
- Canary Ingress.
- Sticky session.
- WAF/ModSecurity.
- mTLS.
- Ingress multi-controller phức tạp.
- Production hardening chi tiết.

Các nội dung này nên để các buổi nâng cao sau.

## 3. Mô hình lab của buổi học

### 3.1. Mô hình cluster

Bài lab tiếp tục sử dụng cụm Kubernetes đã triển khai từ Buổi 02.

```text
+-------------------------------+
|        Kubernetes Cluster      |
|        Version: v1.35          |
+-------------------------------+

Control Plane:
  k8s-master-01
  Ubuntu 24.04
  containerd
  kubeadm
  kubelet
  kubectl

Worker Nodes:
  k8s-worker-01
  Ubuntu 24.04
  containerd
  kubelet

  k8s-worker-02
  Ubuntu 24.04
  containerd
  kubelet

CNI:
  Calico

Storage từ buổi trước:
  nfs-server-01
  Ubuntu 24.04
  NFS Server
```

### 3.2. Ví dụ địa chỉ IP trong bài lab

- Node Network: `10.10.10.0/24`.
- Pod CIDR: `192.168.0.0/16`.
- Service CIDR: `10.96.0.0/12`.
- API endpoint: `k8s-api.k8s.local:6443`.

> Lưu ý: Dải IP bên dưới chỉ là ví dụ. Khi triển khai trong lớp học thật, giảng viên cần thay bằng dải IP thực tế của môi trường lab.

```text
k8s-master-01    10.10.10.11
k8s-worker-01    10.10.10.21
k8s-worker-02    10.10.10.22
nfs-server-01    10.10.10.50

MetalLB IP Pool:
  10.10.10.240 - 10.10.10.250
```

Dải IP dành cho MetalLB phải thỏa các điều kiện:

- Cùng Layer 2 network với các node Kubernetes nếu dùng Layer 2 mode.
- Không trùng IP của node.
- Không trùng IP của gateway.
- Không trùng IP của DNS server.
- Không nằm trong dải DHCP đang tự động cấp cho máy khác.
- Nên được reserve riêng cho Kubernetes LoadBalancer Service.

Ví dụ nếu mạng lab là `10.10.10.0/24`, gateway là `10.10.10.254`, các VM dùng IP từ `10.10.10.11` đến `10.10.10.50`, thì có thể dành `10.10.10.240-10.10.10.250` cho MetalLB.

## 4. Bức tranh tổng thể của buổi học

Sau khi hoàn tất bài lab, luồng truy cập ứng dụng sẽ như sau:

```text
Client / Browser
      |
      | HTTP/HTTPS
      v
MetalLB External IP
10.10.10.240
      |
      v
Service type LoadBalancer
traefik
      |
      v
Traefik Ingress Controller Pod
      |
      v
Ingress Rule
host: web.lab.local
path: /
      |
      v
Service ClusterIP của ứng dụng
lesson-06-web-svc
      |
      v
Pod ứng dụng web
lesson-06-web
```

Điểm quan trọng cần hiểu:

- Client không truy cập trực tiếp vào Pod. Địa chỉ MetalLB là địa chỉ truy cập mạng lab, không mặc định là public IP.
- Client cũng không cần biết IP của Pod.
- Client truy cập vào một IP bên ngoài do MetalLB cấp.
- IP đó đang gắn với Service type `LoadBalancer` của Traefik Ingress Controller.
- Traefik Ingress Controller nhận HTTP/HTTPS request.
- Ingress rule quyết định request đó được chuyển đến Service nào.
- Traefik mặc định có thể lấy endpoint của Service và forward thẳng đến Pod IP. Sơ đồ Service → Pod là quan hệ logic; không nhất thiết đi qua ClusterIP/kube-proxy lần nữa. Nếu bật nativeLB, Traefik chuyển qua ClusterIP.

## 5. Vấn đề cần giải quyết: đưa ứng dụng web ra ngoài cluster

Ở Buổi 04, học viên đã biết `NodePort` có thể expose ứng dụng ra ngoài cluster.

Ví dụ:

```text
http://<Node-IP>:30080
```

Cách này đơn giản nhưng có nhiều điểm bất tiện:

- Phải dùng port cao trong dải NodePort, mặc định thường là `30000-32767`.
- Không thân thiện với người dùng cuối.
- Nếu có nhiều ứng dụng web, mỗi ứng dụng cần một NodePort riêng.
- Không xử lý tốt routing theo domain.
- Không xử lý tốt routing theo path.
- Không phải cách tự nhiên để publish nhiều website dùng chung port 80/443.
- Nếu dùng nhiều worker node, client cần biết nên truy cập node nào.
- Nếu node bị down, cần có cơ chế chuyển hướng bên ngoài.

Ingress giúp giải quyết bài toán routing HTTP/HTTPS theo domain và path.

MetalLB giúp giải quyết bài toán cấp IP truy cập từ bên ngoài cho môi trường on-premise/bare-metal.

Helm giúp triển khai các thành phần như MetalLB và Traefik Ingress Controller một cách gọn gàng hơn.

## 6. Helm

## 6.1. Helm là gì?

Helm là package manager cho Kubernetes.

Nếu xem Kubernetes manifest là các file YAML riêng lẻ, thì Helm giúp đóng gói nhiều manifest liên quan thành một gói triển khai gọi là Chart.

Một ứng dụng hoặc một thành phần hạ tầng trong Kubernetes thường không chỉ có một YAML duy nhất. Ví dụ Traefik Ingress Controller có thể bao gồm:

- Namespace.
- ServiceAccount.
- ClusterRole.
- ClusterRoleBinding.
- Role.
- RoleBinding.
- Deployment.
- Service.
- ConfigMap.
- CustomResourceDefinition (ví dụ Middleware).
- IngressClass.
- Các label/annotation liên quan.

Nếu phải quản lý tất cả file YAML này thủ công, việc cài đặt, nâng cấp và gỡ bỏ sẽ rất dễ sai.

Helm giúp gom các tài nguyên đó lại thành một chart, cho phép người vận hành cài đặt bằng một lệnh và tùy chỉnh bằng values.

## 6.2. Các khái niệm cốt lõi của Helm

### Chart

Chart là một gói chứa template Kubernetes manifest.

Một chart có thể đại diện cho:

- Một ứng dụng web.
- Một database.
- Một monitoring stack.
- Một ingress controller.
- Một storage driver.
- Một load balancer implementation.

Ví dụ:

```text
traefik/traefik
metallb/metallb
bitnami/nginx
```

### Repository

Repository là nơi lưu trữ các chart.

Ví dụ repository của Traefik Ingress Controller:

```bash
https://traefik.github.io/charts
```

Ví dụ repository của MetalLB:

```bash
https://metallb.github.io/metallb
```

### Release

Release là một lần cài đặt chart vào cluster.

Một chart có thể được cài nhiều lần với nhiều release name khác nhau.

Ví dụ cùng một chart `nginx`, có thể cài thành:

```text
web-dev
web-staging
web-production
```

Mỗi release có cấu hình, lifecycle và revision riêng.

### Values

Values là dữ liệu đầu vào dùng để tùy chỉnh chart.

Ví dụ khi cài Traefik Ingress Controller, ta có thể tùy chỉnh Service type:

```bash
--set service.type=LoadBalancer
```

Hoặc dùng file values riêng:

```bash
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --values traefik-values.yaml
```

## 6.3. Vì sao cần học Helm ở thời điểm này?

Tới Buổi 06,  đã đủ nền tảng để hiểu:

- Helm thực chất vẫn tạo ra Kubernetes objects.
- Các object đó vẫn là Deployment, Service, ConfigMap, Secret, DaemonSet, ClusterRole...
- Helm không thay thế Kubernetes.
- Helm chỉ giúp quản lý manifest theo dạng package.

Đây là thời điểm phù hợp để đưa Helm vào vì các thành phần như MetalLB và Traefik Ingress Controller có nhiều manifest phức tạp. Nếu cài bằng YAML raw ngay từ đầu,  dễ bị ngợp bởi số lượng object.

## 6.4. Cài Helm trên Ubuntu 24.04

Thực hiện trên máy dùng để quản trị cluster, thường là `k8s-master-01`.

### Cách 1: cài từ Apt repository

```bash
sudo apt-get update
sudo apt-get install -y curl gpg apt-transport-https

curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/helm.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

sudo apt-get update
sudo apt-get install -y helm
```

Kiểm tra:

```bash
helm version
```

Kết quả kỳ vọng:

```text
version.BuildInfo{Version:"v4.x.x", ...}
```

Hoặc:

```text
version.BuildInfo{Version:"v3.x.x", ...}
```

Tùy thời điểm cài đặt, hệ thống có thể dùng Helm v3 hoặc Helm v4. Trong phạm vi bài học này, các lệnh cơ bản như `repo add`, `repo update`, `upgrade --install`, `list`, `status`, `uninstall` có cùng ý nghĩa vận hành.

### Cách 2: cài bằng script chính thức

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
```

Kiểm tra:

```bash
helm version
```

Trong môi trường production, nên kiểm tra kỹ script trước khi chạy và ưu tiên quy trình cài đặt đã được tổ chức phê duyệt.

## 6.5. Các lệnh Helm cơ bản

### Thêm chart repository

```bash
helm repo add <repo-name> <repo-url>
```

Ví dụ:

```bash
helm repo add traefik https://traefik.github.io/charts
```

### Cập nhật danh sách chart

```bash
helm repo update
```

### Tìm chart trong repo

```bash
helm search repo traefik
```

### Xem values mặc định của chart

```bash
helm show values traefik/traefik
```

### Cài đặt hoặc nâng cấp release

```bash
helm upgrade --install <release-name> <chart-name> \
  --namespace <namespace> \
  --create-namespace
```

`upgrade --install` có ý nghĩa:

- Nếu release chưa tồn tại, Helm sẽ cài mới.
- Nếu release đã tồn tại, Helm sẽ nâng cấp release đó.

Đây là cách dùng phổ biến trong thực tế vì chạy lại lệnh nhiều lần vẫn an toàn hơn so với chỉ dùng `helm install`.

### Xem danh sách release

```bash
helm list -A
```

### Xem trạng thái release

```bash
helm status <release-name> -n <namespace>
```

### Gỡ release

```bash
helm uninstall <release-name> -n <namespace>
```

## 7. Service type LoadBalancer trong môi trường on-premise

## 7.1. Nhắc lại Service từ Buổi 04

Ở Buổi 04,  đã học:

- `ClusterIP`: expose Service bên trong cluster.
- `NodePort`: expose Service qua một port trên mỗi node.
- `Headless`: không cấp ClusterIP, thường dùng cho stable DNS identity.
- `ExternalName`: ánh xạ Service sang DNS name bên ngoài.

Buổi này mở khóa thêm `LoadBalancer`, nhưng chỉ trong ngữ cảnh cần thiết để chạy MetalLB và Ingress Controller trên on-premise.

## 7.2. Service type LoadBalancer là gì?

Service type `LoadBalancer` là cách Kubernetes yêu cầu hạ tầng bên ngoài cấp một địa chỉ IP hoặc load balancer để đưa Service ra ngoài cluster.

Trên các cloud như AWS, Azure, GCP, Service type `LoadBalancer` thường cần cloud provider integration. Khi tạo Service type `LoadBalancer`, cloud-controller-manager hoặc cloud-specific controller sẽ tương tác với cloud provider để tạo load balancer tương ứng.

Ví dụ trong cloud:

```text
Kubernetes Service type LoadBalancer
          |
          v
Cloud Controller / Cloud LB Controller
          |
          v
AWS NLB / Azure Load Balancer / GCP Load Balancer
```

Trong môi trường kubeadm on-premise, nếu không có thành phần cấp IP, Service type `LoadBalancer` thường sẽ bị:

```text
EXTERNAL-IP: <pending>
```

Điều này không có nghĩa cluster bị lỗi. Nó chỉ có nghĩa là Kubernetes chưa có thành phần nào đứng ra cấp external IP cho Service.

## 7.3. MetalLB giải quyết vấn đề gì?

MetalLB là một load-balancer implementation cho Kubernetes bare-metal/on-premise.

Trong bài lab này, MetalLB sẽ làm nhiệm vụ:

- Theo dõi các Service type `LoadBalancer`.
- Cấp IP từ một pool đã cấu hình sẵn.
- Quảng bá IP đó ra mạng bên ngoài.
- Cho phép client trong cùng mạng truy cập Service qua IP đó.

Với mô hình lab Layer 2, MetalLB hoạt động theo hướng đơn giản:

```text
Client trong mạng LAN
      |
      | ARP hỏi: Ai đang giữ IP 10.10.10.240?
      v
MetalLB Speaker trên một node trả lời
      |
      v
Traffic đi vào node đó
      |
      v
kube-proxy chuyển traffic đến Service/Pod phù hợp
```

## 7.4. MetalLB gồm những thành phần nào?

### Controller

MetalLB Controller là thành phần quản lý cấp phát IP.

Nhiệm vụ chính:

- Theo dõi Service type `LoadBalancer`.
- Chọn IP từ `IPAddressPool`.
- Gán IP đó vào `.status.loadBalancer.ingress`.
- Quản lý logic cấp phát IP.

Controller thường chạy dạng Deployment.

### Speaker

MetalLB Speaker là thành phần chạy trên node và quảng bá IP ra mạng.

Nhiệm vụ chính:

- Quảng bá IP Service ra bên ngoài.
- Ở Layer 2 mode, Speaker trả lời ARP/NDP.
- Ở BGP mode, Speaker thiết lập BGP session với router.

Trong bài này chỉ dùng Layer 2 mode.

Speaker thường chạy dạng DaemonSet để có mặt trên các node.

## 7.5. Layer 2 mode là gì?

Layer 2 mode là cách triển khai đơn giản nhất của MetalLB.

Đặc điểm:

- Không cần router hỗ trợ BGP.
- Không cần cấu hình dynamic routing.
- Chỉ cần các node và client nằm trong cùng Layer 2 network.
- MetalLB dùng ARP để làm cho một IP trong pool trỏ về một node.
- Tại một thời điểm, một IP thường được một node “đại diện” trả lời.

Phù hợp cho:

- Lab.
- On-premise nhỏ.
- Môi trường không có BGP.
- Môi trường đào tạo.

Hạn chế:

- Không phân tán traffic theo kiểu ECMP như BGP.
- Một node có thể trở thành điểm nhận traffic cho một external IP cụ thể.
- Cần chọn IP pool cẩn thận để tránh trùng IP.
- Phụ thuộc vào cùng Layer 2 network.

## 8. Cài MetalLB bằng Helm

## 8.1. Chuẩn bị namespace cho MetalLB

MetalLB Speaker cần quyền mạng cao hơn bình thường. Vì vậy, namespace `metallb-system` nên được gán Pod Security label ở mức `privileged`.

Tạo namespace:

```bash
kubectl create namespace metallb-system
```

Gán label:

```bash
kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

Kiểm tra namespace:

```bash
kubectl get namespace metallb-system --show-labels
```

Kết quả kỳ vọng có các label:

```text
pod-security.kubernetes.io/enforce=privileged
pod-security.kubernetes.io/audit=privileged
pod-security.kubernetes.io/warn=privileged
```

## 8.2. Thêm Helm repository của MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
```

Kiểm tra chart:

```bash
helm search repo metallb
```

## 8.3. Cài MetalLB

MetalLB sử dụng Layer 2 mode. Với Chart 0.16.2, tắt FRR và FRR-K8s vì bài này không sử dụng BGP.

Tạo file cấu hình:

```bash
cat <<'EOF' > metallb-values.yaml
speaker:
  frr:
    enabled: false
frrk8s:
  enabled: false
EOF
```

Cài MetalLB:

```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version 0.16.2 \
  -f metallb-values.yaml \
  --wait --timeout 5m
```

Giải thích:

```text
helm upgrade --install
```

Cài mới nếu release chưa tồn tại, nâng cấp nếu release đã tồn tại.

```text
metallb
```

Tên release.

```text
metallb/metallb
```

Chart cần cài, nằm trong repo `metallb`.

```text
--namespace metallb-system
```

Cài vào namespace `metallb-system`.

```text
--version 0.16.2
```

Chọn phiên bản Chart.

```text
-f metallb-values.yaml
```

Sử dụng cấu hình Native mode đã khai báo ở trên.

```text
--wait --timeout 5m
```

Yêu cầu Helm chờ đến khi các resource chính sẵn sàng hoặc timeout.

## 8.4. Kiểm tra MetalLB

```bash
kubectl get all -n metallb-system
```

Kết quả kỳ vọng:

```text
NAME                                      READY   STATUS    RESTARTS   AGE
pod/metallb-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
pod/metallb-speaker-xxxxx                 1/1     Running   0          1m
pod/metallb-speaker-yyyyy                 1/1     Running   0          1m
pod/metallb-speaker-zzzzz                 1/1     Running   0          1m

NAME                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
service/metallb-webhook-service ClusterIP ...
```

Kiểm tra release Helm:

```bash
helm list -n metallb-system
```

Xem trạng thái release:

```bash
helm status metallb -n metallb-system
```

## 8.5. Cấu hình IPAddressPool và L2Advertisement

Sau khi cài MetalLB, chỉ cài component thôi là chưa đủ. MetalLB sẽ chưa cấp IP cho Service nếu chưa có cấu hình IP pool.

Tạo file:

```bash
cat <<'EOF' > metallb-l2-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.10.240-10.10.10.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
EOF
```

Apply manifest:

```bash
kubectl apply --dry-run=server -f metallb-l2-pool.yaml
kubectl apply -f metallb-l2-pool.yaml
```

Kiểm tra:

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

## 8.6. Giải thích manifest MetalLB

```yaml
apiVersion: metallb.io/v1beta1
```

Sử dụng API group của MetalLB. Đây không phải API object mặc định của Kubernetes core, mà là Custom Resource Definition do MetalLB cài vào cluster.

```yaml
kind: IPAddressPool
```

Khai báo một pool địa chỉ IP để MetalLB dùng cấp cho Service type `LoadBalancer`.

```yaml
metadata:
  name: lab-pool
  namespace: metallb-system
```

Tạo object tên `lab-pool` trong namespace `metallb-system`.

```yaml
spec:
  addresses:
    - 10.10.10.240-10.10.10.250
```

Dải IP MetalLB được phép cấp. Trong lab này, các Service type `LoadBalancer` có thể nhận một IP trong khoảng `10.10.10.240` đến `10.10.10.250`.

```yaml
kind: L2Advertisement
```

Khai báo cách MetalLB quảng bá IP ra mạng ở Layer 2 mode.

```yaml
spec:
  ipAddressPools:
    - lab-pool
```

Chỉ định rằng các IP trong pool `lab-pool` sẽ được advertise bằng Layer 2.

## 8.7. Test nhanh MetalLB bằng Service LoadBalancer

Trước khi cài Traefik Ingress Controller, có thể test MetalLB bằng một ứng dụng nginx đơn giản.

Tạo namespace:

```bash
kubectl create namespace metallb-test
```

Tạo Deployment:

```bash
kubectl create deployment nginx-test \
  --image=nginx:1.27 \
  --replicas=2 \
  -n metallb-test
```

Chờ Deployment sẵn sàng:

```bash
kubectl rollout status deployment/nginx-test -n metallb-test --timeout=180s
```

Expose bằng Service type `LoadBalancer`:

```bash
kubectl expose deployment nginx-test \
  --port=80 \
  --target-port=80 \
  --type=LoadBalancer \
  -n metallb-test
```

Kiểm tra Service:

```bash
kubectl get svc -n metallb-test
```

Kết quả kỳ vọng:

```text
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)
nginx-test   LoadBalancer   10.96.x.x       10.10.10.240    80:xxxxx/TCP
```

Test từ máy client hoặc từ node (sử dụng `EXTERNAL-IP` hiển thị ở trên):

```bash
curl http://10.10.10.240
```

Kết quả kỳ vọng:

```html
Welcome to nginx!
```

Dọn tài nguyên demo để giải phóng IP cho Traefik:

```bash
kubectl delete namespace metallb-test
```

Nếu `EXTERNAL-IP` vẫn là `<pending>`, cần kiểm tra:

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
kubectl get deployment -n metallb-system
kubectl logs -n metallb-system deploy/metallb-controller
kubectl get pods -n metallb-system -o wide
```

Nếu tên Deployment Controller khác, thay `metallb-controller` bằng tên hiển thị từ lệnh `kubectl get deployment`.

## 9. Ingress

## 9.1. Ingress là gì?

Ingress là Kubernetes API object dùng để quản lý truy cập HTTP và HTTPS từ bên ngoài cluster vào các Service bên trong cluster.

Ingress cho phép định nghĩa các rule theo:

- Hostname.
- Path.
- Backend Service.
- TLS.

Ví dụ:

```text
http://web.lab.local/
      |
      v
Ingress rule host: web.lab.local
      |
      v
Service: lesson-06-web-svc
      |
      v
Pod ứng dụng web
```

Ingress phù hợp cho ứng dụng web vì nó hiểu các khái niệm HTTP/HTTPS như:

- Host header.
- URL path.
- TLS termination.
- Virtual hosting.
- Reverse proxy.

## 9.2. Ingress khác gì Service?

Service chịu trách nhiệm expose một nhóm Pod thông qua một endpoint ổn định.

Ingress chịu trách nhiệm routing HTTP/HTTPS từ bên ngoài vào Service.

So sánh đơn giản:

```text
Service:
  "Ứng dụng này nằm ở đâu trong cluster?"

Ingress:
  "Request HTTP/HTTPS với domain/path này nên đi đến Service nào?"
```

Service hoạt động ở mức L3/L4 nhiều hơn.

Ingress hoạt động ở mức L7 HTTP/HTTPS.

## 9.3. Vì sao chỉ tạo Ingress object là chưa đủ?

Ingress object chỉ là một cấu hình mong muốn.

Để cấu hình đó có tác dụng, cluster phải có một Ingress Controller đang chạy.

Nếu chỉ tạo Ingress mà không có Ingress Controller:

- Không có thành phần nào nhận traffic HTTP/HTTPS từ bên ngoài.
- Không có thành phần nào đọc Ingress rule và cấu hình reverse proxy.
- Ứng dụng sẽ không thật sự được publish ra ngoài.

Vì vậy cần phân biệt:

```text
Ingress:
  API object chứa rule routing.

Ingress Controller:
  Thành phần thực thi rule đó.
```

Trong bài này, Ingress Controller được sử dụng là Traefik Ingress Controller.

## 9.4. Ingress NGINX EOL và lựa chọn Traefik

Dự án cộng đồng **Ingress NGINX (`kubernetes/ingress-nginx`) chính thức retired ngày 24/03/2026**. Sau retirement không còn release bảo trì, bản vá lỗi hay bản vá bảo mật từ dự án. Workload đang sử dụng không tự dừng, nhưng tiếp tục sử dụng lâu dài có rủi ro bảo mật.

Cần phân biệt:

- Ingress NGINX là một implementation của Ingress Controller, không phải bản thân Kubernetes Ingress API.
- `networking.k8s.io/v1` Ingress vẫn được hỗ trợ (API đã frozen; tính năng mới tập trung vào Gateway API).
- NGINX web server (image `nginx`) trong Deployment của bài lab không bị EOL vì sự kiện này. NGINX Ingress Controller của F5 là dự án khác.

| Giải pháp | Hướng sử dụng | Nhận xét cho khóa học |
|---|---|---|
| Traefik Proxy | Ingress, Middleware, Gateway API | Giữ được Ingress chuẩn, dễ triển khai bằng Helm |
| HAProxy Kubernetes Ingress Controller | Ingress, reverse proxy | Phù hợp môi trường cần HAProxy |
| F5 NGINX Ingress Controller | Ingress và các CRD riêng | Khác dự án community ingress-nginx |
| Envoy Gateway | Gateway API | Phù hợp học Gateway API ở phần nâng cao |
| Cilium Gateway API | Gateway API, tích hợp hệ sinh thái Cilium | Không cần thay Calico chỉ để học Ingress |

**Lựa chọn của Buổi 06: Traefik Proxy v3 (Kubernetes Ingress provider)**. Lý do: tương thích manifest Ingress chuẩn, dùng được cùng MetalLB và cert-manager, hỗ trợ HTTP/HTTPS, host/path routing và Middleware. Không cần thay đổi CNI, storage hay mô hình cluster. Các annotation riêng của ingress-nginx không tự tương thích với Traefik native provider; cần chuyển đổi theo chức năng.

Traefik watch Ingress, Service, EndpointSlice và TLS Secret qua Kubernetes API, tạo router/service động và thực thi rule mà không cần chỉnh `nginx.conf`.

Nguồn: https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/ và https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/

## 9.5. Vai trò của IngressClass

`IngressClass` cho Kubernetes biết Ingress object nên được xử lý bởi controller nào.

Ví dụ:

```yaml
spec:
  ingressClassName: traefik
```

Nghĩa là Ingress này sẽ được xử lý bởi Ingress Controller có class `traefik`.

Trong môi trường có nhiều Ingress Controller, `ingressClassName` rất quan trọng để tránh nhầm controller.

Trong bài lab, ta sẽ dùng class:

```text
traefik
```

## 10. Cài Traefik Ingress Controller bằng Helm

## 10.1. Thêm Helm repository

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik --versions
```

Thêm repository Traefik, cập nhật danh sách Chart và tìm các phiên bản có thể cài đặt.

Sử dụng Traefik Helm Chart `43.0.0` (Traefik Proxy `v3.8.0`).

```bash
export TRAEFIK_CHART_VERSION=43.0.0
```

## 10.2. Xem values mặc định

```bash
helm show chart traefik/traefik --version "$TRAEFIK_CHART_VERSION"
helm show values traefik/traefik --version "$TRAEFIK_CHART_VERSION" > traefik-default-values.yaml
```

`helm show chart` hiển thị thông tin Chart; `helm show values` xuất cấu hình mặc định ra file để tham khảo.

Một số khái niệm Traefik:

- EntryPoint: cổng lắng nghe traffic. `web` được Service expose port 80, `websecure` expose port 443.
- Router: xác định request phù hợp với host/path nào.
- Service (khái niệm Traefik): danh sách backend để forward request; khác Kubernetes Service object.
- Middleware: xử lý request/response trước khi forward, ví dụ redirect hoặc rewrite.
- Provider: nguồn cấu hình động, ở đây dùng `kubernetesIngress` và `kubernetesCRD` (Middleware).

## 10.3. Cài Traefik

Kiểm tra IP LoadBalancer đang sử dụng:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

IP `10.10.10.240` cần nằm trong `lab-pool` và chưa được Service khác sử dụng.

Tạo file values:

```bash
cat <<'EOF' > traefik-values.yaml
deployment:
  replicas: 2
service:
  spec:
    type: LoadBalancer
  annotations:
    metallb.io/address-pool: lab-pool
    metallb.io/loadBalancerIPs: "10.10.10.240"
ingressClass:
  enabled: true
  name: traefik
  isDefaultClass: false
providers:
  kubernetesIngress:
    enabled: true
    ingressClass: traefik
    strictPrefixMatching: true
    allowEmptyServices: true
    publishedService:
      enabled: true
  kubernetesCRD:
    enabled: true
    ingressClass: traefik
  kubernetesGateway:
    enabled: false
ingressRoute:
  dashboard:
    enabled: false
accessLog:
  enabled: true
EOF
```

Giải thích:

```yaml
deployment:
  replicas: 2
```

Triển khai hai replica của Traefik.

```yaml
service:
  spec:
    type: LoadBalancer
  annotations:
    metallb.io/address-pool: lab-pool
    metallb.io/loadBalancerIPs: "10.10.10.240"
```

Tạo Service LoadBalancer và yêu cầu MetalLB cấp IP `10.10.10.240` từ `lab-pool`.

```yaml
ingressClass:
  enabled: true
  name: traefik
  isDefaultClass: false
```

Tạo IngressClass `traefik`. Các Ingress sẽ chỉ định class này bằng `ingressClassName: traefik`.

```yaml
providers:
  kubernetesIngress:
    enabled: true
    ingressClass: traefik
    strictPrefixMatching: true
    allowEmptyServices: true
    publishedService:
      enabled: true
```

- `kubernetesIngress`: đọc các Ingress object thuộc class `traefik`.
- `strictPrefixMatching`: match theo từng thành phần path; `/api` không match `/apix`.
- `allowEmptyServices`: trả HTTP 503 khi Service không có backend endpoint sẵn sàng.
- `publishedService`: cập nhật địa chỉ LoadBalancer vào Ingress Status.

```yaml
providers:
  kubernetesCRD:
    enabled: true
    ingressClass: traefik
  kubernetesGateway:
    enabled: false
```

Bật CRD provider để sử dụng Middleware; Middleware cần annotation `kubernetes.io/ingress.class: traefik`. Không sử dụng Gateway API trong buổi này.

```yaml
ingressRoute:
  dashboard:
    enabled: false
accessLog:
  enabled: true
```

Không tạo IngressRoute cho Dashboard; bật Access Log để kiểm tra request HTTP/HTTPS. Không bật redirect toàn cục để thực hành HTTP và HTTPS riêng.

Cài Traefik:

```bash
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --version "$TRAEFIK_CHART_VERSION" \
  -f traefik-values.yaml --wait --timeout 5m
```

Giải thích:

- `traefik traefik/traefik`: tên release và tên Chart.
- `--namespace traefik --create-namespace`: cài vào namespace `traefik`, tự tạo namespace nếu chưa có.
- `--version`: chọn phiên bản Chart.
- `-f`: sử dụng file Values đã tạo.
- `--wait --timeout 5m`: chờ các tài nguyên sẵn sàng, tối đa 5 phút.

## 10.4. Kiểm tra Traefik

```bash
helm list -n traefik
kubectl get deployment,pods,svc -n traefik -o wide
kubectl rollout status deployment/traefik -n traefik --timeout=180s
kubectl get ingressclass
kubectl get crd middlewares.traefik.io
kubectl get endpointslice -n traefik
```

Kết quả kỳ vọng:

```text
Deployment traefik: 2/2 Ready
Service traefik: LoadBalancer, EXTERNAL-IP 10.10.10.240, ports 80/TCP và 443/TCP
IngressClass traefik: traefik.io/ingress-controller
```

```bash
export INGRESS_IP=$(kubectl get svc traefik -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$INGRESS_IP"
```

Nếu IP rỗng, dừng lại và kiểm tra MetalLB. Chưa có Ingress rule, request HTTP đến IP có thể trả 404; đây là bình thường.

```bash
kubectl get deployment traefik -n traefik -o jsonpath='{.spec.template.spec.containers[0].args[*]}' | tr ' ' '\n'
curl --noproxy '*' -sS -o /dev/null -w 'HTTP Status: %{http_code}\n' "http://${INGRESS_IP}/"
curl --noproxy '*' -ksS -o /dev/null -w 'HTTPS Status: %{http_code}\n' "https://${INGRESS_IP}/"
```

Lệnh đầu tiên hiển thị các tham số runtime của Traefik, trong đó cần có `--providers.kubernetesingress.strictPrefixMatching=true`, `--providers.kubernetesingress.allowEmptyServices=true` và `--accesslog=true`.

Hai lệnh curl kiểm tra kết nối đến cổng HTTP và HTTPS. Kết quả kỳ vọng:

```text
HTTP Status: 404
HTTPS Status: 404
```

Chưa có Ingress rule phù hợp nên Traefik trả về 404.

## 10.5. Kiểm tra log controller

```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --all-containers=true --tail=100 --prefix=true
```

Access log ghi nhận request; log controller dùng để tìm lỗi rule, Service hoặc TLS Secret. Kiểm tra tất cả replica khi troubleshoot.

## 11. Lab 01 - Publish ứng dụng web bằng HTTP qua Ingress

## 11.1. Tạo namespace cho bài lab

```bash
kubectl create namespace lesson-06
```

## 11.2. Tạo ConfigMap chứa nội dung web

Từ Buổi 05,  đã biết ConfigMap có thể chứa file cấu hình hoặc nội dung text. Ở đây ta dùng ConfigMap để cung cấp file `index.html` cho nginx.

Tạo file:

```bash
cat <<'EOF' > web-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lesson-06-web-content
  namespace: lesson-06
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>Kubernetes Lesson 06</title>
    </head>
    <body>
      <h1>Hello from Kubernetes Ingress</h1>
      <p>This web application is exposed through Traefik Ingress Controller.</p>
      <p>Protocol: HTTP</p>
    </body>
    </html>
EOF
```

Apply:

```bash
kubectl apply -f web-configmap.yaml
```

## 11.3. Tạo Deployment chạy nginx

Tạo file:

```bash
cat <<'EOF' > web-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lesson-06-web
  namespace: lesson-06
  labels:
    app: lesson-06-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: lesson-06-web
  template:
    metadata:
      labels:
        app: lesson-06-web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: web-content
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: web-content
          configMap:
            name: lesson-06-web-content
EOF
```

Apply:

```bash
kubectl apply -f web-deployment.yaml
```

Kiểm tra Pod:

```bash
kubectl get pods -n lesson-06 -o wide
```

## 11.4. Giải thích Deployment manifest

```yaml
apiVersion: apps/v1
kind: Deployment
```

Tạo Deployment. Kiến thức này đã học ở Buổi 03.

```yaml
metadata:
  name: lesson-06-web
  namespace: lesson-06
```

Deployment được tạo trong namespace `lesson-06`.

```yaml
labels:
  app: lesson-06-web
```

Label dùng để nhận diện workload và liên kết với Service.

```yaml
replicas: 2
```

Chạy 2 Pod nginx để minh họa backend có nhiều replica.

```yaml
selector:
  matchLabels:
    app: lesson-06-web
```

Deployment quản lý các Pod có label `app=lesson-06-web`.

```yaml
template:
  metadata:
    labels:
      app: lesson-06-web
```

Pod được tạo ra cũng có label `app=lesson-06-web`.

```yaml
containers:
  - name: nginx
    image: nginx:1.27
```

Container sử dụng image nginx.

```yaml
ports:
  - containerPort: 80
```

Container nginx lắng nghe port 80.

```yaml
volumeMounts:
  - name: web-content
    mountPath: /usr/share/nginx/html/index.html
    subPath: index.html
```

Mount file `index.html` từ ConfigMap vào đúng vị trí nginx dùng để phục vụ web.

```yaml
volumes:
  - name: web-content
    configMap:
      name: lesson-06-web-content
```

Khai báo volume lấy dữ liệu từ ConfigMap `lesson-06-web-content`.

## 11.5. Tạo Service ClusterIP cho ứng dụng

Ingress không route trực tiếp vào Pod. Ingress route vào Service.

Tạo file:

```bash
cat <<'EOF' > web-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: lesson-06-web-svc
  namespace: lesson-06
spec:
  type: ClusterIP
  selector:
    app: lesson-06-web
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
```

Apply:

```bash
kubectl apply -f web-service.yaml
```

Kiểm tra Service:

```bash
kubectl get svc -n lesson-06
```

Kiểm tra EndpointSlice:

```bash
kubectl get endpointslice -n lesson-06
```

## 11.6. Giải thích Service manifest

```yaml
kind: Service
```

Tạo Service để expose nhóm Pod.

```yaml
metadata:
  name: lesson-06-web-svc
```

Tên Service. Ingress sẽ trỏ đến tên này.

```yaml
type: ClusterIP
```

Service chỉ expose bên trong cluster. Ingress Controller nằm trong cluster nên có thể truy cập Service này.

```yaml
selector:
  app: lesson-06-web
```

Service chọn các Pod có label `app=lesson-06-web`.

```yaml
ports:
  - name: http
    port: 80
    targetPort: 80
```

Service nhận traffic ở port 80 và chuyển đến port 80 của Pod.

## 11.7. Tạo Ingress HTTP

Trong lab này dùng domain giả lập (chỉ DNS/hosts nội bộ; `.local` có thể được xử lý bởi mDNS, dùng `curl --resolve` để test nhất quán):

```text
web.lab.local
```

Tạo file:

```bash
cat <<'EOF' > web-http-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lesson-06-web-http
  namespace: lesson-06
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lesson-06-web-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f web-http-ingress.yaml
```

Kiểm tra Ingress:

```bash
kubectl get ingress -n lesson-06
```

Kết quả kỳ vọng:

```text
NAME                 CLASS   HOSTS           ADDRESS        PORTS
lesson-06-web-http   traefik   web.lab.local   10.10.10.240   80
```

## 11.8. Giải thích Ingress HTTP manifest

Annotation `traefik.ingress.kubernetes.io/router.entrypoints: web` giới hạn router này tại entrypoint HTTP. Với HTTPS dùng `websecure` và `spec.tls`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
```

Tạo Ingress object thuộc API group `networking.k8s.io`.

```yaml
metadata:
  name: lesson-06-web-http
  namespace: lesson-06
```

Ingress nằm cùng namespace với Service backend.

```yaml
spec:
  ingressClassName: traefik
```

Chỉ định Ingress này được xử lý bởi Ingress Controller class `traefik`.

```yaml
rules:
  - host: web.lab.local
```

Rule áp dụng cho HTTP request có Host header là `web.lab.local`.

```yaml
http:
  paths:
    - path: /
      pathType: Prefix
```

Mọi request có path bắt đầu bằng `/` sẽ match rule này.

```yaml
backend:
  service:
    name: lesson-06-web-svc
    port:
      number: 80
```

Request sau khi match rule sẽ được chuyển đến Service `lesson-06-web-svc` port 80.

## 11.9. Cấu hình phân giải tên miền cho lab

Vì `web.lab.local` là domain lab, máy client cần phân giải domain này về IP của Ingress Controller.

Lấy IP của Traefik Ingress Controller:

```bash
kubectl get svc traefik -n traefik
```

Ví dụ:

```text
EXTERNAL-IP = 10.10.10.240
```

### Cách 1: sửa file hosts trên máy client Linux/macOS

```bash
sudo sh -c 'echo "10.10.10.240 web.lab.local" >> /etc/hosts'
```

### Cách 2: sửa file hosts trên Windows

Mở Notepad bằng quyền Administrator và sửa file:

```text
C:\Windows\System32\drivers\etc\hosts
```

Thêm dòng:

```text
10.10.10.240 web.lab.local
```

### Cách 3: dùng curl --resolve không cần sửa hosts

```bash
curl --resolve web.lab.local:80:10.10.10.240 http://web.lab.local/
```

## 11.10. Test HTTP

Từ máy client:

```bash
curl http://web.lab.local/
```

Hoặc:

```bash
curl --resolve web.lab.local:80:10.10.10.240 http://web.lab.local/
```

Kết quả kỳ vọng:

```html
<h1>Hello from Kubernetes Ingress</h1>
<p>This web application is exposed through Traefik Ingress Controller.</p>
<p>Protocol: HTTP</p>
```

Kiểm tra log Ingress Controller:

```bash
kubectl logs -n traefik deploy/traefik --tail=50
```

## 12. Lab 02 - Publish ứng dụng web bằng HTTPS qua Ingress

## 12.1. HTTPS trong Ingress hoạt động như thế nào?

Khi dùng HTTPS với Ingress, TLS thường được terminate tại Ingress Controller.

Luồng traffic:

```text
Client Browser
      |
      | HTTPS
      v
Traefik Ingress Controller
      |
      | HTTP nội bộ trong cluster
      v
Service ClusterIP
      |
      v
Pod ứng dụng
```

Điều này nghĩa là:

- Client kết nối HTTPS đến Ingress Controller.
- Ingress Controller dùng certificate trong Kubernetes Secret để bắt tay TLS.
- Sau đó Ingress Controller chuyển request vào Service backend.
- Traffic từ Ingress Controller đến Pod thường là HTTP nội bộ, trừ khi cấu hình backend HTTPS riêng.

Trong bài này chỉ làm TLS termination tại Ingress Controller.

## 12.2. Tạo self-signed certificate cho domain lab

Trong môi trường production, certificate nên được cấp bởi CA tin cậy như Let's Encrypt hoặc CA nội bộ doanh nghiệp.

Trong lab, ta dùng self-signed certificate.

Tạo certificate:

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout web.lab.local.key \
  -out web.lab.local.crt \
  -subj "/CN=web.lab.local/O=Kubernetes Lab" \
  -addext "subjectAltName=DNS:web.lab.local"
```

Kiểm tra file:

```bash
ls -l web.lab.local.*
```

Kết quả kỳ vọng:

```text
web.lab.local.crt
web.lab.local.key
```

## 12.3. Tạo TLS Secret

Tạo Secret trong namespace `lesson-06`:

```bash
kubectl create secret tls web-lab-local-tls \
  --cert=web.lab.local.crt \
  --key=web.lab.local.key \
  -n lesson-06
```

Kiểm tra Secret:

```bash
kubectl get secret web-lab-local-tls -n lesson-06
```

Xem loại Secret:

```bash
kubectl describe secret web-lab-local-tls -n lesson-06
```

Kết quả sẽ có:

```yaml
type: kubernetes.io/tls
```

## 12.4. Cập nhật nội dung web để hiển thị HTTPS

Cập nhật ConfigMap:

```bash
cat <<'EOF' > web-configmap-https.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lesson-06-web-content
  namespace: lesson-06
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>Kubernetes Lesson 06 HTTPS</title>
    </head>
    <body>
      <h1>Hello from Kubernetes HTTPS Ingress</h1>
      <p>This web application is exposed through Traefik Ingress Controller.</p>
      <p>Protocol: HTTPS</p>
      <p>TLS is terminated at the Ingress Controller.</p>
    </body>
    </html>
EOF
```

Apply:

```bash
kubectl apply -f web-configmap-https.yaml
```

Vì ConfigMap được mount dạng file, đôi khi Pod cần được restart để nội dung cập nhật rõ ràng trong lab.

Restart Deployment:

```bash
kubectl rollout restart deployment lesson-06-web -n lesson-06
kubectl rollout status deployment lesson-06-web -n lesson-06
```

## 12.5. Tạo Ingress HTTPS

Tạo thêm Ingress có TLS với entrypoint websecure, giữ HTTP router riêng.

Tạo file:

```bash
cat <<'EOF' > web-https-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lesson-06-web-https
  namespace: lesson-06
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - web.lab.local
      secretName: web-lab-local-tls
  rules:
    - host: web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lesson-06-web-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f web-https-ingress.yaml
```

Giữ lại Ingress HTTP đã tạo ở Lab 01 để kiểm tra redirect ở mục 12.8. Hai Ingress được phân tách theo entrypoint.

Kiểm tra:

```bash
kubectl get ingress -n lesson-06
```

Kết quả kỳ vọng:

```text
NAME                  CLASS   HOSTS           ADDRESS        PORTS
lesson-06-web-https   traefik   web.lab.local   10.10.10.240   80, 443
lesson-06-web-http    traefik   web.lab.local   10.10.10.240   80
```

## 12.6. Giải thích Ingress HTTPS manifest

```yaml
tls:
  - hosts:
      - web.lab.local
    secretName: web-lab-local-tls
```

Khai báo TLS cho host `web.lab.local`.

```yaml
secretName: web-lab-local-tls
```

Ingress Controller sẽ lấy certificate và private key từ Secret này.

Secret phải:

- Nằm cùng namespace với Ingress.
- Có type `kubernetes.io/tls`.
- Chứa key `tls.crt`.
- Chứa key `tls.key`.

```yaml
rules:
  - host: web.lab.local
```

Host trong `rules` phải khớp với host trong `tls.hosts` để HTTPS hoạt động đúng.

```yaml
backend:
  service:
    name: lesson-06-web-svc
    port:
      number: 80
```

Dù bên ngoài dùng HTTPS, backend Service vẫn dùng port 80. Đây là mô hình TLS termination tại Ingress Controller.

## 12.7. Test HTTPS

Vì certificate là self-signed, client chưa mặc định trust. Ưu tiên kiểm tra đầy đủ TLS bằng chính public certificate của lab (`--cacert`); `-k` chỉ dùng để minh họa bỏ qua xác thực, không dùng cho production.

```bash
curl --noproxy '*' --cacert web.lab.local.crt --resolve "web.lab.local:443:${INGRESS_IP}" -I https://web.lab.local/
```

Kết quả kỳ vọng: HTTP 200 với TLS trust hợp lệ. Có thể minh họa `-k` như sau:

```bash
curl -k https://web.lab.local/
```

Hoặc không cần sửa hosts:

```bash
curl -k --resolve web.lab.local:443:10.10.10.240 https://web.lab.local/
```

Kết quả kỳ vọng:

```html
<h1>Hello from Kubernetes HTTPS Ingress</h1>
<p>This web application is exposed through Traefik Ingress Controller.</p>
<p>Protocol: HTTPS</p>
<p>TLS is terminated at the Ingress Controller.</p>
```

Kiểm tra certificate:

```bash
openssl s_client -connect web.lab.local:443 -servername web.lab.local
```

Hoặc:

```bash
openssl s_client -connect 10.10.10.240:443 -servername web.lab.local
```

## 12.8. Kiểm tra redirect HTTP sang HTTPS

Traefik không tự redirect HTTP sang HTTPS chỉ vì Ingress có `spec.tls`. Bài này giữ HTTP Ingress của Lab 01, HTTPS Ingress của Lab 02, rồi gắn Middleware RedirectScheme chỉ vào HTTP Ingress.

```bash
cat <<'EOF' > web-redirect-middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: lesson-06
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF
kubectl apply -f web-redirect-middleware.yaml
kubectl annotate ingress lesson-06-web-http -n lesson-06 \
  traefik.ingress.kubernetes.io/router.middlewares=lesson-06-redirect-https@kubernetescrd --overwrite
```

Cú pháp tham chiếu Middleware từ Ingress: `<namespace>-<middleware-name>@kubernetescrd`. Không gắn Middleware redirect vào HTTPS router.

```bash
curl -I --resolve web.lab.local:80:$INGRESS_IP http://web.lab.local/
curl --cacert web.lab.local.crt -I --resolve web.lab.local:443:$INGRESS_IP https://web.lab.local/
```

Kết quả kỳ vọng: HTTP trả redirect 301 với Location HTTPS; HTTPS trả 200. Không giả định status 308 như ingress-nginx.

Tắt redirect và kiểm tra lại HTTP:

```bash
kubectl annotate ingress lesson-06-web-http -n lesson-06 \
  traefik.ingress.kubernetes.io/router.middlewares-
curl -I --resolve web.lab.local:80:$INGRESS_IP http://web.lab.local/
```

Bật lại Middleware bằng lệnh annotate ở trên. Lưu ý `kubectl apply` file HTTP gốc có thể thay đổi cấu hình khai báo; lưu annotation vào manifest nếu muốn duy trì redirect.

## 13. Lab 03 - Publish hai ứng dụng web bằng cùng một IP Ingress

## 13.1. Mục tiêu

Lab này giúp học viên thấy giá trị thật sự của Ingress:

- Nhiều ứng dụng web.
- Dùng chung một external IP.
- Phân biệt bằng hostname.
- Vẫn dùng port chuẩn 80/443.

Ví dụ:

```text
app1.lab.local -> lesson-06-app1-svc
app2.lab.local -> lesson-06-app2-svc
```

Cả hai domain cùng trỏ về:

```text
10.10.10.240
```

## 13.2. Tạo ứng dụng app1

```bash
cat <<'EOF' > app1.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app1-content
  namespace: lesson-06
data:
  index.html: |
    <h1>Application 1</h1>
    <p>This is app1 served through Kubernetes Ingress.</p>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
  namespace: lesson-06
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: content
          configMap:
            name: app1-content
---
apiVersion: v1
kind: Service
metadata:
  name: app1-svc
  namespace: lesson-06
spec:
  type: ClusterIP
  selector:
    app: app1
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
```

Apply:

```bash
kubectl apply -f app1.yaml
```

## 13.3. Tạo ứng dụng app2

```bash
cat <<'EOF' > app2.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app2-content
  namespace: lesson-06
data:
  index.html: |
    <h1>Application 2</h1>
    <p>This is app2 served through Kubernetes Ingress.</p>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
  namespace: lesson-06
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: content
          configMap:
            name: app2-content
---
apiVersion: v1
kind: Service
metadata:
  name: app2-svc
  namespace: lesson-06
spec:
  type: ClusterIP
  selector:
    app: app2
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
```

Apply:

```bash
kubectl apply -f app2.yaml
```

## 13.4. Tạo Ingress host-based routing

```bash
cat <<'EOF' > multi-host-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-host-ingress
  namespace: lesson-06
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: app1.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app1-svc
                port:
                  number: 80
    - host: app2.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app2-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f multi-host-ingress.yaml
```

Kiểm tra:

```bash
kubectl get ingress -n lesson-06
```

## 13.5. Cấu hình hosts

Nếu dùng `/etc/hosts`:

```bash
sudo sh -c 'echo "10.10.10.240 app1.lab.local app2.lab.local" >> /etc/hosts'
```

Hoặc test bằng `curl --resolve`:

```bash
curl --resolve app1.lab.local:80:10.10.10.240 http://app1.lab.local/
curl --resolve app2.lab.local:80:10.10.10.240 http://app2.lab.local/
```

Kết quả kỳ vọng:

```text
Application 1
```

và:

```text
Application 2
```

## 13.6. Ý nghĩa của lab này

Cùng một IP `10.10.10.240`, cùng port 80, nhưng Ingress Controller route đến các backend khác nhau dựa trên HTTP Host header.

```text
Host: app1.lab.local
  -> app1-svc

Host: app2.lab.local
  -> app2-svc
```

Đây là lý do Ingress rất phù hợp để publish nhiều ứng dụng web trong cùng một cluster.

---

## Lab 04 - Tự động cấp và gia hạn TLS Certificate bằng cert-manager

### CM.1. Vì sao cần cert-manager?

Ở Lab 02, chúng ta tạo private key và certificate bằng OpenSSL, sau đó tạo TLS Secret thủ công. Khi số lượng website tăng lên, quản trị viên phải theo dõi ngày hết hạn, cấp lại certificate và cập nhật Secret cho từng website.

cert-manager là một controller mở rộng Kubernetes, tự động cấp và gia hạn certificate theo trạng thái mong muốn đã khai báo. cert-manager không phải Ingress Controller, không cấp IP và không nhận traffic web.

```text
Luồng truy cập ứng dụng (data plane):
Client --> MetalLB IP --> Traefik --> backend Pod
                              |
                              +--> đọc TLS Secret

Luồng quản lý chứng chỉ (control plane):
Certificate / Ingress annotation
            |
            v
cert-manager --> Issuer / ClusterIssuer --> CA
            |
            v
TLS Secret (tls.crt, tls.key)
            |
            v
Traefik tự cập nhật certificate khi Secret thay đổi
```

| Thành phần | Trách nhiệm |
|---|---|
| MetalLB | Cấp và quảng bá IP cho Service LoadBalancer |
| Traefik | Routing HTTP/HTTPS, TLS termination, Middleware |
| cert-manager | Cấp, theo dõi và gia hạn certificate |
| CA | Ký certificate theo cơ chế xác thực của CA |
| DNS | Phân giải hostname về địa chỉ truy cập |

Không bật ACME certificate resolver riêng của Traefik trong lab này: cert-manager là thành phần quản lý certificate duy nhất cho các chứng chỉ tự động.

### CM.2. Các resource và component chính

| Resource | Phạm vi | Vai trò |
|---|---|---|
| Issuer | Namespace | Mô tả nguồn cấp certificate trong cùng namespace |
| ClusterIssuer | Toàn cluster | Nguồn cấp certificate cho nhiều namespace |
| Certificate | Namespace | Khai báo SAN, issuer, Secret, thời hạn mong muốn |
| CertificateRequest | Namespace | Yêu cầu ký certificate do cert-manager tạo |
| Order | Namespace | Đơn đặt certificate ACME, chỉ xuất hiện với ACME |
| Challenge | Namespace | Quá trình xác thực domain ACME |
| TLS Secret | Namespace | Chứa certificate và private key mà Traefik đọc |

cert-manager gồm controller, webhook (kiểm tra/default API request) và cainjector (inject CA bundle cho các thành phần cần xác thực TLS). Các CRD mở rộng Kubernetes API với những object mới; không cần sửa kubeadm.

`Certificate` và `Issuer` khác nhau: Issuer là nơi cấp; Certificate là yêu cầu cụ thể cho một hoặc nhiều DNS name. Có thể tạo Certificate trực tiếp hoặc dùng annotation trên Ingress để ingress-shim tự sinh Certificate.

### CM.3. Cài cert-manager bằng Helm

#### CM.3.1. Thêm Helm Repository

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm search repo jetstack/cert-manager --versions
```

Các lệnh trên thêm repository, cập nhật danh sách Chart và hiển thị các phiên bản cert-manager.

#### CM.3.2. Cài cert-manager

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.3 \
  --set crds.enabled=true --wait --timeout 5m
```

Giải thích:

- `cert-manager jetstack/cert-manager`: tên release và Chart.
- `--namespace cert-manager --create-namespace`: tạo namespace và cài cert-manager vào đó.
- `--version v1.21.3`: chọn phiên bản Chart.
- `--set crds.enabled=true`: cài các CRD của cert-manager vào Kubernetes API.
- `--wait --timeout 5m`: chờ các thành phần sẵn sàng.

Kết quả kỳ vọng:

```text
NAME: cert-manager
NAMESPACE: cert-manager
STATUS: deployed
```

#### CM.3.3. Kiểm tra các thành phần

```bash
kubectl get deployment,pod -n cert-manager
```

Kết quả kỳ vọng (rút gọn):

```text
NAME                                    READY   UP-TO-DATE   AVAILABLE
deployment.apps/cert-manager            1/1     1            1
deployment.apps/cert-manager-cainjector  1/1     1            1
deployment.apps/cert-manager-webhook     1/1     1            1
```

Kiểm tra các resource API được bổ sung:

```bash
kubectl api-resources --api-group=cert-manager.io
kubectl api-resources --api-group=acme.cert-manager.io
```

Kết quả kỳ vọng (rút gọn):

```text
NAME                   APIVERSION                NAMESPACED   KIND
certificates           cert-manager.io/v1        true         Certificate
certificaterequests    cert-manager.io/v1        true         CertificateRequest
clusterissuers         cert-manager.io/v1        false        ClusterIssuer
issuers                cert-manager.io/v1        true         Issuer
challenges             acme.cert-manager.io/v1   true         Challenge
orders                 acme.cert-manager.io/v1   true         Order
```

### CM.4. Các phương thức cấp certificate

| Phương thức | Yêu cầu | Phù hợp với |
|---|---|---|
| SelfSigned Issuer | Không cần external CA | Demo self-signed hoặc bootstrap CA |
| CA Issuer | CA certificate và private key | Lab/internal PKI |
| ACME HTTP-01 | Domain hợp lệ, public DNS, CA truy cập port 80 | Website public |
| ACME DNS-01 | Public authoritative DNS và quyền cập nhật TXT | Domain public hợp lệ, wildcard, website chỉ truy cập nội bộ |

Domain `*.lab.local` của giáo trình chỉ là tên giả lập nội bộ, không thể xin certificate publicly trusted từ Let's Encrypt. Vì vậy lab bắt buộc dùng CA nội bộ được bootstrap bởi SelfSigned Issuer. Không yêu cầu mở firewall, mua domain hay dùng API token DNS. DNS-01 vẫn cần domain hợp lệ được kiểm soát; không phải cách cấp Let's Encrypt cho `.local`.

### CM.5. Tạo CA nội bộ cho lab (bắt buộc)

Mô hình CA nội bộ:

```text
[SelfSigned Issuer: lab-selfsigned]
                 |
                 v
[Root CA Certificate: lab-root-ca]
                 |
                 v
[TLS Secret: lab-root-ca-tls]
                 |
                 v
[CA Issuer: lab-ca]
                 |
       +---------+----------+
       v                    v
[cert.lab.local]      [shim.lab.local]
Certificate trực tiếp  Ingress-shim
       |                    |
       v                    v
[cert-web-tls]        [cert-shim-tls]
       +---------+----------+
                 v
           [Traefik HTTPS]
```

#### CM.5.1. Tạo namespace và Root CA

Tạo namespace `cert-manager-demo`. Không chia sẻ private key của CA.

```bash
kubectl create namespace cert-manager-demo
cat <<'EOF_CA' > 01-lab-ca.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: lab-selfsigned
  namespace: cert-manager-demo
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: lab-root-ca
  namespace: cert-manager-demo
spec:
  isCA: true
  commonName: Kubernetes Lab Root CA
  secretName: lab-root-ca-tls
  duration: 8760h
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Never
  issuerRef:
    name: lab-selfsigned
    kind: Issuer
    group: cert-manager.io
EOF_CA
```

Giải thích manifest:

- `selfSigned: {}`: cấp certificate tự ký để khởi tạo CA.
- `isCA: true`: certificate có thể ký certificate khác.
- `secretName`: Secret lưu Root CA certificate và private key.
- `duration: 8760h`, `renewBefore: 720h`: thời hạn 365 ngày và gia hạn trước 30 ngày.
- `issuerRef`: sử dụng Issuer `lab-selfsigned`.
- `rotationPolicy: Never`: giữ private key của Root CA khi cấp lại certificate.

Triển khai và kiểm tra: `--dry-run=server` kiểm tra manifest qua API Server mà không tạo resource; `apply` tạo resource và `wait` chờ trạng thái `Ready=True`.

```bash
kubectl apply --dry-run=server -f 01-lab-ca.yaml
kubectl apply -f 01-lab-ca.yaml
kubectl wait --for=condition=Ready issuer/lab-selfsigned -n cert-manager-demo --timeout=120s
kubectl wait --for=condition=Ready certificate/lab-root-ca -n cert-manager-demo --timeout=180s
```

Kết quả kỳ vọng:

```text
issuer.cert-manager.io/lab-selfsigned condition met
certificate.cert-manager.io/lab-root-ca condition met
```

#### CM.5.2. Tạo CA Issuer

CA Issuer sử dụng Root CA certificate và private key trong Secret để ký certificate ứng dụng.

```bash
cat <<'EOF_ISSUER' > 02-lab-issuer.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: lab-ca
  namespace: cert-manager-demo
spec:
  ca:
    secretName: lab-root-ca-tls
EOF_ISSUER
```

`spec.ca.secretName` tham chiếu Secret `lab-root-ca-tls` trong cùng namespace.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f 02-lab-issuer.yaml
kubectl apply -f 02-lab-issuer.yaml
kubectl wait --for=condition=Ready issuer/lab-ca -n cert-manager-demo --timeout=120s
kubectl get issuer,certificate -n cert-manager-demo
```

Kết quả kỳ vọng:

```text
NAME                                    READY
issuer.cert-manager.io/lab-ca           True
issuer.cert-manager.io/lab-selfsigned   True

NAME                                    READY   SECRET
certificate.cert-manager.io/lab-root-ca True    lab-root-ca-tls
```

CA Issuer không tự quản lý việc phân phối trust đến client hoặc xoay vòng toàn bộ CA/leaf certificate khi root thay đổi. Đây chỉ là mô hình PKI tối giản dành cho lab; không sử dụng root CA của lab cho production.

### CM.6. Tạo ứng dụng và Certificate tự động

#### CM.6.1. Tạo Deployment và Service

Dùng kiến thức Deployment/Service từ Buổi 03 và 04:

```bash
cat <<'EOF_APP' > 03-cert-web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-web
  namespace: cert-manager-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cert-web
  template:
    metadata:
      labels:
        app: cert-web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: cert-web-svc
  namespace: cert-manager-demo
spec:
  type: ClusterIP
  selector:
    app: cert-web
  ports:
    - port: 80
      targetPort: 80
EOF_APP
```

Deployment chạy hai nginx Pod. Service `cert-web-svc` chọn các Pod có label `app: cert-web` và chuyển traffic đến port 80.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f 03-cert-web.yaml
kubectl apply -f 03-cert-web.yaml
kubectl rollout status deployment/cert-web -n cert-manager-demo --timeout=180s
```

Kết quả kỳ vọng:

```text
deployment "cert-web" successfully rolled out
```

#### CM.6.2. Tạo Certificate

Tạo Certificate với SAN `cert.lab.local`. Thời hạn 2160h (90 ngày), yêu cầu gia hạn trước 720h (30 ngày); thời hạn thực tế tùy issuer.

```bash
cat <<'EOF_CERT' > 04-cert-web-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cert-web
  namespace: cert-manager-demo
spec:
  secretName: cert-web-tls
  dnsNames:
    - cert.lab.local
  duration: 2160h
  renewBefore: 720h
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: lab-ca
    kind: Issuer
    group: cert-manager.io
EOF_CERT
```

Giải thích manifest:

- `secretName: cert-web-tls`: tên TLS Secret được tạo tự động.
- `dnsNames`: SAN cần có trong certificate.
- `duration`, `renewBefore`: thời hạn mong muốn và thời gian gia hạn trước khi hết hạn.
- `rotationPolicy: Always`: tạo private key mới khi cấp lại certificate.
- `issuerRef`: yêu cầu CA Issuer `lab-ca` ký certificate.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f 04-cert-web-certificate.yaml
kubectl apply -f 04-cert-web-certificate.yaml
kubectl wait --for=condition=Ready certificate/cert-web -n cert-manager-demo --timeout=180s
kubectl get certificate,certificaterequest -n cert-manager-demo
kubectl describe certificate cert-web -n cert-manager-demo
kubectl describe secret cert-web-tls -n cert-manager-demo
```

Kết quả kỳ vọng:

```text
NAME            READY   SECRET
cert-web        True    cert-web-tls
lab-root-ca     True    lab-root-ca-tls
```

`kubectl describe secret` hiển thị type `kubernetes.io/tls` cùng các key `tls.crt`, `tls.key` và `ca.crt`. Không cần tạo TLS Secret thủ công.

### CM.7. Tạo Ingress HTTPS và kiểm tra trust

#### CM.7.1. Tạo Ingress

```bash
cat <<'EOF_INGRESS' > 05-cert-web-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cert-web
  namespace: cert-manager-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - cert.lab.local
      secretName: cert-web-tls
  rules:
    - host: cert.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
EOF_INGRESS
```

`ingressClassName` chọn Traefik, `websecure` nhận HTTPS, `tls.secretName` tham chiếu certificate đã cấp; `rules` định tuyến đến Service `cert-web-svc`.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f 05-cert-web-ingress.yaml
kubectl apply -f 05-cert-web-ingress.yaml
export INGRESS_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Kiểm tra Ingress:

```bash
kubectl get ingress -n cert-manager-demo
```

Kết quả kỳ vọng:

```text
NAME       CLASS     HOSTS            ADDRESS        PORTS
cert-web   traefik   cert.lab.local   10.10.10.240   80, 443
```

#### CM.7.2. Export Root CA Certificate và kiểm tra HTTPS

Chỉ export public certificate, không lấy private key:

```bash
kubectl get secret lab-root-ca-tls -n cert-manager-demo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > lab-root-ca.crt
openssl x509 -in lab-root-ca.crt -noout -subject -issuer -dates -ext basicConstraints
```

Kết quả kỳ vọng (rút gọn):

```text
subject=CN = Kubernetes Lab Root CA
issuer=CN = Kubernetes Lab Root CA
X509v3 Basic Constraints: critical
    CA:TRUE
```

Dùng `--cacert` để client tin cậy Root CA và `--resolve` để truy cập VIP mà không cần sửa DNS:

```bash
curl --noproxy '*' --cacert lab-root-ca.crt \
  --resolve "cert.lab.local:443:${INGRESS_IP}" -I https://cert.lab.local/
```

Kết quả kỳ vọng:

```text
HTTP/2 200
```

TLS được xác thực bằng Root CA, không cần `-k`.

```bash
openssl s_client -connect "$INGRESS_IP:443" -servername cert.lab.local \
  -CAfile lab-root-ca.crt -verify_hostname cert.lab.local -verify_return_error </dev/null
```

Kết quả kỳ vọng: `Verify return code: 0 (ok)`. Nếu browser chưa trust root CA vẫn có thể cảnh báo; dùng `--cacert` để không thay đổi trust store hệ điều hành. Chỉ import public CA certificate vào máy lab nếu giảng viên cho phép.

Leaf certificate có thể không có Common Name vì dùng SAN (`dnsNames`) để xác thực hostname; `subject=` trống không phải lỗi.

### CM.8. Certificate tự sinh từ Ingress (ingress-shim)

Ngoài cách tạo Certificate trực tiếp, ta có thể để ingress-shim tạo Certificate thông qua annotation `cert-manager.io/issuer` hoặc `cert-manager.io/cluster-issuer`. Dùng hostname/Secret khác để không có hai Certificate cùng quản lý một Secret.

```bash
cat <<'EOF_SHIM' > 06-cert-shim-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cert-shim
  namespace: cert-manager-demo
  annotations:
    cert-manager.io/issuer: lab-ca
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - shim.lab.local
      secretName: cert-shim-tls
  rules:
    - host: shim.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
EOF_SHIM
```

Giải thích manifest:

- `cert-manager.io/issuer: lab-ca`: yêu cầu ingress-shim tạo Certificate sử dụng CA Issuer.
- `tls.hosts`: danh sách DNS name cần cấp certificate.
- `tls.secretName: cert-shim-tls`: tên Certificate được sinh và TLS Secret mà Traefik sử dụng.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f 06-cert-shim-ingress.yaml
kubectl apply -f 06-cert-shim-ingress.yaml
kubectl wait --for=create certificate/cert-shim-tls -n cert-manager-demo --timeout=60s
kubectl wait --for=condition=Ready certificate/cert-shim-tls -n cert-manager-demo --timeout=180s
kubectl get certificate -n cert-manager-demo
```

Kết quả kỳ vọng:

```text
NAME            READY   SECRET
cert-shim-tls   True    cert-shim-tls
cert-web        True    cert-web-tls
lab-root-ca     True    lab-root-ca-tls
```

Kiểm tra HTTPS:

```bash
curl --noproxy '*' --cacert lab-root-ca.crt \
  --resolve "shim.lab.local:443:${INGRESS_IP}" -I https://shim.lab.local/
```

Kết quả kỳ vọng: `HTTP/2 200`.

Ingress-shim tự tạo Certificate từ `tls.hosts` và `tls.secretName`. Certificate vẫn được cert-manager quản lý như cách khai báo trực tiếp.

### CM.9. Kiểm tra lifecycle và Renewal Time

```bash
kubectl get certificate -n cert-manager-demo \
  -o custom-columns='NAME:.metadata.name,ISSUER:.spec.issuerRef.name,NOT-BEFORE:.status.notBefore,NOT-AFTER:.status.notAfter,RENEWAL:.status.renewalTime,REVISION:.status.revision'
```

Kết quả kỳ vọng (ví dụ minh họa):

```text
NAME            ISSUER          NOT-BEFORE              NOT-AFTER               RENEWAL                 REVISION
cert-web        lab-ca          2026-01-01T00:00:00Z    2026-04-01T00:00:00Z    2026-03-02T00:00:00Z    1
```

| Field | Ý nghĩa |
|---|---|
| notBefore | Thời điểm certificate bắt đầu có hiệu lực |
| notAfter | Thời điểm hết hạn |
| renewalTime | Thời điểm cert-manager dự kiến gia hạn |
| revision | Phiên bản phát hành của Certificate |

cert-manager theo dõi thời gian gia hạn, tạo CertificateRequest mới và cập nhật TLS Secret. Traefik theo dõi Secret để tự động sử dụng certificate mới mà không cần restart.

#### CM.9.1. Cài cmctl và kiểm tra API

Cài công cụ `cmctl` để kiểm tra API và chủ động cấp lại certificate. Sử dụng binary Linux amd64 cho Ubuntu 24.04 amd64.

```bash
curl -fsSL -o cmctl https://github.com/cert-manager/cmctl/releases/download/v2.6.2/cmctl_linux_amd64
sudo install -m 0755 cmctl /usr/local/bin/cmctl
cmctl version
cmctl check api --wait=60s
```

Kết quả kỳ vọng (rút gọn):

```text
Client Version: ... GitVersion:"v2.6.2" ...
Server Version: ... Detected:"v1.21.3" ...
The cert-manager API is ready
```

#### CM.9.2. Ghi nhận certificate trước renewal

Đọc Revision, Serial, thời hạn và fingerprint của certificate cùng hash của public key để đối chiếu sau khi cấp lại.

```bash
kubectl get certificate cert-web -n cert-manager-demo \
  -o custom-columns='NAME:.metadata.name,REVISION:.status.revision'
kubectl get secret cert-web-tls -n cert-manager-demo -o jsonpath='{.data.tls\.crt}' |
  base64 -d > cert-web-before.crt
openssl x509 -in cert-web-before.crt -noout -serial -dates -fingerprint -sha256
openssl x509 -in cert-web-before.crt -pubkey -noout |
  openssl pkey -pubin -outform DER | openssl dgst -sha256
kubectl get pods -n traefik -o wide
```

#### CM.9.3. Kích hoạt cấp lại certificate

Chỉ chạy với certificate ứng dụng lab `cert-web`, không chạy với Root CA hoặc certificate production đang phục vụ. Không xóa TLS Secret để ép renewal.

```bash
cmctl renew cert-web -n cert-manager-demo
```

Kết quả kỳ vọng:

```text
Manually triggered issuance of Certificate cert-manager-demo/cert-web
```

Theo dõi CertificateRequest mới:

```bash
watch -n 2 kubectl get certificate,certificaterequest -n cert-manager-demo
```

Dừng watch bằng Ctrl+C khi CertificateRequest mới `cert-web-2` đã Ready. Kiểm tra Revision bằng lệnh bên dưới (1 → 2 nếu cấp lại lần đầu). `Ready=True` đơn lẻ chưa chứng minh cấp lại đã hoàn thành, vì certificate cũ có thể vẫn hợp lệ. Không dùng `kubectl get certificate,certificaterequest -w` vì watch chỉ hỗ trợ một resource type trong lệnh này.

```bash
kubectl get certificate cert-web -n cert-manager-demo \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.revision'
kubectl get certificaterequest -n cert-manager-demo
kubectl get secret cert-web-tls -n cert-manager-demo -o jsonpath='{.data.tls\.crt}' |
  base64 -d > cert-web-after.crt
for file in cert-web-before.crt cert-web-after.crt; do
  echo "========== $file =========="
  openssl x509 -in "$file" -noout -serial -dates -fingerprint -sha256
  openssl x509 -in "$file" -pubkey -noout |
    openssl pkey -pubin -outform DER | openssl dgst -sha256
done
```

Kết quả kỳ vọng:

```text
NAME       READY   REVISION
cert-web   True    2
```

Serial, certificate fingerprint và public key hash đều thay đổi so với trước khi cấp lại.

#### CM.9.4. Xác nhận Traefik nạp certificate mới

```bash
openssl x509 -in cert-web-after.crt -noout -fingerprint -sha256
openssl s_client -connect "${INGRESS_IP}:443" -servername cert.lab.local \
  -CAfile lab-root-ca.crt -verify_hostname cert.lab.local -verify_return_error </dev/null 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256
curl --noproxy '*' --cacert lab-root-ca.crt --resolve "cert.lab.local:443:${INGRESS_IP}" -I https://cert.lab.local/
kubectl get pods -n traefik -o wide
```

| Kiểm tra | Kết quả kỳ vọng |
|---|---|
| Revision | 1 → 2 |
| CertificateRequest mới | cert-web-2 Ready=True |
| Serial, certificate fingerprint | Thay đổi |
| Public key hash | Thay đổi (rotationPolicy: Always) |
| TLS Secret name | Vẫn cert-web-tls |
| Fingerprint Secret mới và Traefik | Trùng khớp |
| HTTPS với Root CA | HTTP/2 200 |
| Traefik Pod / restart | Giữ nguyên / 0 |

Nếu Traefik chưa phục vụ fingerprint mới ngay, kiểm tra lại sau khi cấu hình động được cập nhật. Lệnh `cmctl renew` kích hoạt cấp lại chủ động; thông thường cert-manager tự cấp lại khi đến `renewalTime`.

### CM.10. Lab mở rộng (Optional) - Let's Encrypt HTTP-01, DNS-01 và Wildcard

#### CM.10.1. Điều kiện và mô hình

| Nội dung | HTTP-01 | DNS-01 |
|---|---|---|
| Phương thức xác thực | HTTP challenge trên TCP/80 | TXT `_acme-challenge` trên public DNS |
| Public domain do giảng viên quản lý | Có | Có |
| Public inbound TCP/80 | Có | Không cần |
| DNS API token | Không | Có (Cloudflare trong bài này) |
| Wildcard | Không | Có |


`example.com` dưới đây là domain minh họa, không phải domain mà học viên có quyền sử dụng. Thay bằng domain thật được phép quản lý. Không sử dụng `.local` với Let's Encrypt. Với lab 1 master + 2 worker, dùng chung một Traefik IngressClass `traefik` và VIP `10.10.10.240`. Nếu không có public domain, bỏ qua CM.10; CM.5–CM.9 vẫn thực hành đầy đủ.

**Mô hình HTTP-01:**

```text
[cert-manager] -- ACME request --> [Let's Encrypt]
      |                                   |
      | Tạo solver                        | HTTP :80
      v                                   v
[Solver Pod]                       [Public IP / NAT]
      ^                                   |
      |                                   v
[Solver Service] <-------------- [Traefik / VIP]
                       Solver Ingress
```

Let's Encrypt phân giải public DNS và gọi `/.well-known/acme-challenge/...` qua TCP/80. cert-manager tạo Solver Ingress, Service và Pod để trả lời Challenge. Sau khi xác thực, cert-manager lưu certificate vào TLS Secret; Traefik sử dụng Secret để phục vụ HTTPS.

**Mô hình DNS-01:**

```text
[cert-manager] -- ACME request --> [Let's Encrypt]
      |                                   |
      | Cloudflare API                    | DNS TXT lookup
      v                                   v
[Cloudflare DNS: _acme-challenge TXT] <----+

Sau khi xác thực thành công:
[cert-manager] --> [TLS Secret] --> [Traefik HTTPS]
```

cert-manager tạo TXT record thông qua DNS API. Let's Encrypt kiểm tra TXT trên authoritative DNS; không cần mở inbound port 80 cho ứng dụng DNS-01. Việc cấp certificate không tự tạo A record hoặc giới hạn quyền truy cập ứng dụng.

**Mô hình Wildcard:**

```text
[DNS-01 / Let's Encrypt]
           |
           v
[Certificate: *.lab.example.com]
           |
           v
[TLS Secret: wildcard-staging-tls]
           |
           v
        [Traefik]
       /         \
      v           v
    app1         app2
```

Hai hostname `app1.lab.example.com` và `app2.lab.example.com` sử dụng chung một TLS Secret. Wildcard chỉ cấp được bằng DNS-01.

Bài thực hành sử dụng một ACME endpoint của Let’s Encrypt (Staging) để tránh tiêu tốn hạn mức cấp certificate thật. Certificate Staging không được trình duyệt tin cậy mặc định; `curl -k` chỉ dùng để quan sát HTTPS routing. Mỗi ClusterIssuer sử dụng một ACME Account Secret riêng.

#### CM.10.2. Chuẩn bị ứng dụng và biến môi trường

Thực hiện từ thư mục đã chứa `03-cert-web.yaml` của CM.6:

```bash
export ACME_NS=cert-manager-acme-demo
# Replace these two values with your own domain and email.
export DOMAIN=example.com
export ACME_EMAIL=admin@example.com
export PUBLIC_HOST="web.${DOMAIN}"
export INTERNAL_HOST="internal.${DOMAIN}"
export WILDCARD_BASE="lab.${DOMAIN}"
export INGRESS_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Thay hai giá trị `DOMAIN` và `ACME_EMAIL` trong block lệnh trên bằng thông tin thật trước khi chạy. Ba biến hostname được tính tự động từ `DOMAIN`. Không tiếp tục nếu domain vẫn là `example.com` hoặc VIP rỗng.

```bash
kubectl create namespace "$ACME_NS"
sed "s/namespace: cert-manager-demo/namespace: ${ACME_NS}/g" 03-cert-web.yaml > acme-web-app.yaml
kubectl apply --dry-run=server -f acme-web-app.yaml
kubectl apply -f acme-web-app.yaml
kubectl rollout status deployment/cert-web -n "$ACME_NS" --timeout=180s
```

Lệnh `sed` sao chép manifest ứng dụng ở CM.6 sang namespace ACME. Kết quả kỳ vọng: `deployment "cert-web" successfully rolled out`.

#### CM.10.3. HTTP-01 – Public DNS và ClusterIssuer Staging

Tạo A record cho `web.example.com` (thay domain) trên Cloudflare, trỏ đến public IP của lab, chế độ DNS only. Cấu hình NAT TCP/80 và TCP/443 đến Traefik VIP `10.10.10.240` nếu sử dụng public IP qua gateway. Kiểm tra từ mạng ngoài lab và từ cluster:

```bash
dig @1.1.1.1 "$PUBLIC_HOST" A +short
dig @1.1.1.1 "$PUBLIC_HOST" AAAA +short
curl --noproxy '*' -I --connect-timeout 5 "http://${PUBLIC_HOST}/"
```

Chưa có router thì 404 là bình thường. Không để AAAA sai đích hoặc bật redirect toàn cục trước khi cấp certificate. Kiểm tra đường public TCP/80; nếu cluster có split DNS thì kiểm tra cả DNS self-check của cert-manager.

```bash
cat <<EOF_HTTP_ISSUER > acme-http01-staging-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-http01-staging
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: lab-http01-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
            serviceType: ClusterIP
EOF_HTTP_ISSUER
```

`server` là ACME endpoint, `privateKeySecretRef` lưu ACME account key; `solvers.http01.ingress` sử dụng IngressClass `traefik` và Service `ClusterIP` cho solver.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-http01-staging-issuer.yaml
kubectl apply -f acme-http01-staging-issuer.yaml
kubectl wait --for=condition=Ready clusterissuer/lab-http01-staging --timeout=180s
kubectl get secret lab-http01-staging-account-key -n cert-manager
```

Kết quả kỳ vọng:

```text
clusterissuer.cert-manager.io/lab-http01-staging condition met
```

Secret `lab-http01-staging-account-key` được tạo trong namespace `cert-manager`.

#### CM.10.4. HTTP-01 – Ingress và cấp Staging Certificate

```bash
cat <<EOF_HTTP > acme-http01-staging.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cert-http01
  namespace: ${ACME_NS}
  annotations:
    cert-manager.io/cluster-issuer: lab-http01-staging
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${PUBLIC_HOST}
      secretName: http01-staging-tls
  rules:
    - host: ${PUBLIC_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
EOF_HTTP
```

Annotation `cert-manager.io/cluster-issuer` yêu cầu ingress-shim cấp Certificate bằng HTTP-01. `tls.secretName` là Secret chứa certificate được cấp.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-http01-staging.yaml
kubectl apply -f acme-http01-staging.yaml
```

Quan sát trong terminal khác (Ctrl+C để dừng):

```bash
watch -n 2 kubectl get certificate,certificaterequest,order,challenge -n "$ACME_NS"
```

```bash
kubectl get ingress,svc,pod -n "$ACME_NS"
kubectl wait --for=create certificate/http01-staging-tls -n "$ACME_NS" --timeout=60s
kubectl wait --for=condition=Ready certificate/http01-staging-tls -n "$ACME_NS" --timeout=600s
kubectl describe certificate http01-staging-tls -n "$ACME_NS"
curl --noproxy '*' -k --resolve "${PUBLIC_HOST}:443:${INGRESS_IP}" -I "https://${PUBLIC_HOST}/"
```

Kết quả kỳ vọng (rút gọn):

```text
certificate.cert-manager.io/http01-staging-tls condition met
HTTP/2 200
```

Solver có tên bắt đầu bằng `cm-acme-http-solver-` và được dọn sau xác thực. `Ready=True`, Order `valid` và HTTP 200 là kết quả mong đợi. `-k` chỉ dùng kiểm tra routing với Staging, không xác nhận CA trust.

#### CM.10.5. DNS-01 – Cloudflare API Token

Trong Cloudflare Dashboard, vào phần API Tokens, tạo token giới hạn đúng zone của lab:

| Permission | Access |
|---|---|
| Zone → DNS | Edit |
| Zone → Zone | Read |
| Zone Resources | Include đúng domain được quản lý |

Không sử dụng Global API Key. Không lưu token vào Git, log hoặc manifest plaintext. Với cấu hình cert-manager mặc định, Secret cho ClusterIssuer nằm trong namespace `cert-manager` (cluster resource namespace).

```bash
# Enter the token without echoing or storing it in shell history.
read -rsp 'Cloudflare API Token: ' CF_TOKEN; echo
printf '%s' "$CF_TOKEN" | kubectl create secret generic lab-cloudflare-api-token \
  -n cert-manager --from-file=api-token=/dev/stdin
unset CF_TOKEN
kubectl describe secret lab-cloudflare-api-token -n cert-manager
```

Kết quả kỳ vọng: Secret type `Opaque`, có key `api-token`. Lệnh `describe` chỉ hiển thị kích thước dữ liệu, không hiển thị token.

#### CM.10.6. DNS-01 – ClusterIssuer Staging

```bash
cat <<EOF_DNS_ISSUER > acme-dns01-staging-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-dns01-staging
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: lab-dns01-staging-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: lab-cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - ${DOMAIN}
EOF_DNS_ISSUER
```

`dns01.cloudflare.apiTokenSecretRef` tham chiếu API Token Secret; `selector.dnsZones` giới hạn solver cho domain được cấu hình.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-dns01-staging-issuer.yaml
kubectl apply -f acme-dns01-staging-issuer.yaml
kubectl wait --for=condition=Ready clusterissuer/lab-dns01-staging --timeout=180s
kubectl get clusterissuer
```

Kết quả kỳ vọng:

```text
NAME                 READY
lab-dns01-staging    True
lab-http01-staging   True
```

`Ready=True` của ClusterIssuer cho biết ACME Account sẵn sàng; việc cấp certificate mới xác nhận solver và credential hoạt động.

#### CM.10.7. DNS-01 – Ingress và Staging Certificate

Không cần tạo public A record cho `internal.example.com`. Có thể tạo record internal DNS trỏ tới VIP, hoặc dùng `curl --resolve` như bên dưới.

```bash
cat <<EOF_DNS > acme-dns01-staging.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cert-dns01
  namespace: ${ACME_NS}
  annotations:
    cert-manager.io/cluster-issuer: lab-dns01-staging
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${INTERNAL_HOST}
      secretName: dns01-staging-tls
  rules:
    - host: ${INTERNAL_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
EOF_DNS
```

Ingress dùng DNS-01 ClusterIssuer và TLS Secret riêng. Traefik vẫn định tuyến HTTPS đến Service như bài HTTP-01.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-dns01-staging.yaml
kubectl apply -f acme-dns01-staging.yaml
```

```bash
watch -n 2 kubectl get certificate,certificaterequest,order,challenge -n "$ACME_NS"
```

Khi Challenge đang xử lý, quan sát từ terminal khác:

```bash
dig @1.1.1.1 "_acme-challenge.${INTERNAL_HOST}" TXT +short
kubectl describe challenge -n "$ACME_NS"
```

TXT được tạo tự động và có thể đã bị dọn khi lệnh chạy. Không có HTTP solver Pod là bình thường.

```bash
kubectl wait --for=create certificate/dns01-staging-tls -n "$ACME_NS" --timeout=60s
kubectl wait --for=condition=Ready certificate/dns01-staging-tls -n "$ACME_NS" --timeout=600s
curl --noproxy '*' -k --resolve "${INTERNAL_HOST}:443:${INGRESS_IP}" -I "https://${INTERNAL_HOST}/"
```

Kết quả kỳ vọng:

```text
certificate.cert-manager.io/dns01-staging-tls condition met
HTTP/2 200
```

#### CM.10.8. Kiểm tra Certificate và TLS Secret

```bash
kubectl get certificate -n "$ACME_NS"
kubectl get order -n "$ACME_NS"
for secret in http01-staging-tls dns01-staging-tls; do
  echo "========== $secret =========="
  kubectl get secret "$secret" -n "$ACME_NS" -o jsonpath='{.data.tls\.crt}' |
    base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
done
```

Kết quả kỳ vọng (rút gọn):

```text
NAME                  READY   SECRET
http01-staging-tls    True    http01-staging-tls
dns01-staging-tls     True    dns01-staging-tls
```

Các Order có `STATE=valid`. SAN của certificate phải tương ứng với `PUBLIC_HOST` và `INTERNAL_HOST`.

#### CM.10.9. Wildcard Certificate với DNS-01 Staging

Wildcard `*.lab.example.com` match `app1.lab.example.com`, `app2.lab.example.com` nhưng không match `lab.example.com` hoặc `dev.app1.lab.example.com`. Nếu cần cả apex, khai báo thêm SAN riêng. 

```bash
cat <<EOF_WILDCARD > acme-wildcard-staging.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-staging
  namespace: ${ACME_NS}
spec:
  secretName: wildcard-staging-tls
  issuerRef:
    name: lab-dns01-staging
    kind: ClusterIssuer
    group: cert-manager.io
  dnsNames:
    - "*.${WILDCARD_BASE}"
EOF_WILDCARD
```

`dnsNames: "*.${WILDCARD_BASE}"` yêu cầu wildcard certificate và `issuerRef` chọn DNS-01 ClusterIssuer. Secret `wildcard-staging-tls` chứa certificate dùng chung.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-wildcard-staging.yaml
kubectl apply -f acme-wildcard-staging.yaml
kubectl wait --for=condition=Ready certificate/wildcard-staging -n "$ACME_NS" --timeout=600s
kubectl get secret wildcard-staging-tls -n "$ACME_NS" -o jsonpath='{.data.tls\.crt}' |
  base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Kết quả kỳ vọng (với domain minh họa):

```text
certificate.cert-manager.io/wildcard-staging condition met
X509v3 Subject Alternative Name:
    DNS:*.lab.example.com
```

Tạo Ingress sử dụng Wildcard Certificate:

```bash
cat <<EOF_WILDCARD_INGRESS > acme-wildcard-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wildcard-demo
  namespace: ${ACME_NS}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app1.${WILDCARD_BASE}
        - app2.${WILDCARD_BASE}
      secretName: wildcard-staging-tls
  rules:
    - host: app1.${WILDCARD_BASE}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
    - host: app2.${WILDCARD_BASE}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cert-web-svc
                port:
                  number: 80
EOF_WILDCARD_INGRESS
```

Hai host trong `rules` sử dụng cùng TLS Secret được chỉ định tại `tls.secretName`.

Triển khai và kiểm tra:

```bash
kubectl apply --dry-run=server -f acme-wildcard-ingress.yaml
kubectl apply -f acme-wildcard-ingress.yaml
```

Ingress dùng chung Secret cùng namespace, không thêm annotation issuer vì Certificate đã được khai báo trực tiếp.

```bash
kubectl get secret wildcard-staging-tls -n "$ACME_NS" -o jsonpath='{.data.tls\.crt}' |
  base64 -d | openssl x509 -noout -fingerprint -sha256
for host in "app1.${WILDCARD_BASE}" "app2.${WILDCARD_BASE}"; do
  curl --noproxy '*' -k --resolve "${host}:443:${INGRESS_IP}" -I "https://${host}/"
  openssl s_client -connect "${INGRESS_IP}:443" -servername "$host" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 -ext subjectAltName -checkhost "$host"
done
```

Kết quả kỳ vọng (rút gọn):

```text
HTTP/2 200
Hostname app1.lab.example.com does match certificate
HTTP/2 200
Hostname app2.lab.example.com does match certificate
```

Fingerprint của certificate trong Secret và hai hostname phải giống nhau. `-k` chỉ kiểm tra routing với certificate Staging.

Nguồn: https://cert-manager.io/docs/configuration/acme/http01/ và https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/.

### CM.11. Troubleshooting cert-manager

| Hiện tượng | Kiểm tra trước tiên |
|---|---|
| Issuer NotReady | `kubectl describe issuer` hoặc `kubectl describe clusterissuer` |
| Certificate Ready=False | `kubectl describe certificate`, CertificateRequest và events |
| HTTP-01 pending | Public DNS, port 80, solver ingress class, self-check, NAT/firewall |
| DNS-01 pending | TXT record, DNS propagation, quyền DNS API, solver credentials |
| Certificate Ready=True nhưng HTTPS sai certificate | IngressClass, entrypoint, `tls.secretName`, namespace, SNI, Traefik log |
| Certificate đúng nhưng client không trust | CA chain, staging CA, client trust store, SAN/expiry |

```bash
kubectl get certificate,certificaterequest,issuer -n cert-manager-demo
kubectl get clusterissuer
kubectl get order,challenge -n cert-manager-demo
kubectl get events -n cert-manager-demo --sort-by=.lastTimestamp
kubectl logs -n cert-manager deploy/cert-manager --tail=100
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=100 --prefix=true
```

Khi dùng CA nội bộ, không có ACME Order/Challenge là bình thường. `Certificate Ready=True` xác nhận certificate đã được cấp, không bảo đảm DNS, network hay Ingress hoạt động. Cần test HTTPS end-to-end.

### CM.12. Dọn tài nguyên Lab 04

Sau khi đã ghi nhận kết quả lab, chỉ xóa namespace demo do bài này tạo:

```bash
kubectl delete namespace cert-manager-demo
rm -f lab-root-ca.crt cert-web-before.crt cert-web-after.crt
```

Nếu đã thực hiện CM.10, kiểm tra `kubectl get certificate -A` và chắc chắn namespace, issuer, account Secret, token dưới đây chỉ thuộc lab. Xóa namespace trước issuer, tránh làm gián đoạn Challenge đang xử lý. Chỉ chạy khi không có workload khác dùng các issuer/Secret này.

```bash
kubectl delete namespace cert-manager-acme-demo --ignore-not-found=true --wait=true
kubectl delete clusterissuer lab-http01-staging lab-dns01-staging --ignore-not-found=true
kubectl delete secret -n cert-manager \
  lab-http01-staging-account-key \
  lab-dns01-staging-account-key \
  lab-cloudflare-api-token --ignore-not-found=true
```

Xóa DNS record của bài ACME và thu hồi API Token nếu không còn sử dụng. Giữ cert-manager cho các buổi tiếp theo.

---

## Phần bổ sung chuyên sâu - Ingress HTTPS/TLS, pathType và path-based routing

Phần này bổ sung thêm cho Buổi 06 để học viên hiểu kỹ hơn ba nhóm vấn đề thường gặp khi đưa ứng dụng web ra ngoài Kubernetes:

- Ingress dùng HTTPS, SSL/TLS và TLS Secret.
- Routing theo `path` với `pathType: Exact`, `Prefix`, `ImplementationSpecific`.
- Demo nhiều backend dùng chung một domain/IP nhưng tách traffic theo đường dẫn như `/`, `/api`, `/admin`.

Nội dung này nên được dạy sau khi học viên đã hoàn tất các phần:

- Cài Helm.
- Cài MetalLB.
- Cài Traefik Ingress Controller.
- Tạo được Ingress HTTP cơ bản.
- Biết Service `ClusterIP` dùng để đứng trước Pod backend.

### A. Hiểu đúng về HTTPS, SSL và TLS trong Ingress

Trong thực tế, nhiều người vẫn nói “cài SSL cho website”, “SSL certificate”, hoặc “Ingress SSL”. Về mặt kỹ thuật hiện đại, giao thức đang dùng là TLS, không còn là SSL cũ.

Trong Kubernetes Ingress, trường cấu hình chính thức là:

```yaml
spec:
  tls:
```

Vì vậy khi làm lab hoặc triển khai thực tế, nên hiểu như sau:

```text
Cách gọi phổ biến:
  SSL certificate
  SSL for website
  HTTPS SSL

Ý nghĩa kỹ thuật hiện đại:
  TLS certificate
  HTTPS sử dụng TLS
  TLS termination tại Ingress Controller
```

Trong bài này, ta vẫn có thể nói “SSL/TLS” để học viên dễ liên hệ với cách gọi ngoài thực tế, nhưng khi đọc YAML thì cần nhớ Kubernetes dùng khái niệm `tls`.

### B. HTTPS qua Ingress hoạt động như thế nào?

Khi một client truy cập:

```text
https://web.lab.local/
```

Luồng xử lý trong mô hình lab là:

```text
Client / Browser
      |
      | HTTPS TCP/443
      | TLS handshake
      v
MetalLB External IP
10.10.10.240
      |
      v
Service LoadBalancer
traefik
      |
      v
Traefik Ingress Controller
      |
      | Đọc TLS Secret
      | Terminate TLS tại đây
      |
      | HTTP nội bộ
      v
Service ClusterIP backend
      |
      v
Pod ứng dụng
```

Điểm quan trọng:

- Certificate không nằm trong Pod ứng dụng.
- Certificate nằm trong Kubernetes Secret.
- Secret phải nằm cùng namespace với Ingress object.
- Traefik Ingress Controller đọc Secret đó để phục vụ HTTPS.
- Client nói chuyện HTTPS với Ingress Controller.
- Ingress Controller có thể nói chuyện HTTP với backend Service.
- Đây gọi là TLS termination tại Ingress Controller.

Mô hình này rất phổ biến vì:

- Ứng dụng backend không cần tự quản lý certificate.
- Việc gia hạn/thay certificate được gom ở tầng Ingress.
- Nhiều ứng dụng web có thể dùng chung Ingress Controller.
- Dễ áp dụng policy redirect HTTP sang HTTPS.

### C. TLS Secret trong Kubernetes

TLS Secret là Secret có type:

```yaml
type: kubernetes.io/tls
```

Bên trong Secret có hai key dữ liệu bắt buộc:

```text
tls.crt
tls.key
```

Trong đó:

- `tls.crt`: certificate public.
- `tls.key`: private key tương ứng với certificate.

Tạo TLS Secret bằng `kubectl`:

```bash
kubectl create secret tls web-lab-local-tls \
  --cert=web.lab.local.crt \
  --key=web.lab.local.key \
  -n lesson-06
```

Kiểm tra:

```bash
kubectl get secret web-lab-local-tls -n lesson-06
kubectl describe secret web-lab-local-tls -n lesson-06
```

Kết quả cần thấy:

```yaml
type: kubernetes.io/tls
```

Lưu ý quan trọng:

```text
Ingress namespace: lesson-06
TLS Secret namespace: lesson-06
```

Nếu Ingress ở namespace `lesson-06` nhưng Secret lại nằm ở namespace `default`, Traefik sẽ không dùng được Secret đó.

### D. Certificate phải khớp domain

Khi tạo certificate cho HTTPS, certificate phải chứa domain mà client truy cập.

Ví dụ client truy cập:

```text
https://web.lab.local/
```

Certificate nên có SAN:

```text
DNS:web.lab.local
```

Trong lab, tạo self-signed certificate:

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout web.lab.local.key \
  -out web.lab.local.crt \
  -subj "/CN=web.lab.local/O=Kubernetes Lab" \
  -addext "subjectAltName=DNS:web.lab.local"
```

Kiểm tra certificate:

```bash
openssl x509 -in web.lab.local.crt -noout -text | grep -A2 "Subject Alternative Name"
```

Kết quả kỳ vọng:

```text
DNS:web.lab.local
```

Nếu certificate không có SAN đúng domain, browser hoặc `curl` sẽ báo lỗi certificate name mismatch.

### E. Ingress HTTPS manifest đầy đủ

Ví dụ Ingress HTTPS cơ bản:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lesson-06-web-https
  namespace: lesson-06
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - web.lab.local
      secretName: web-lab-local-tls
  rules:
    - host: web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: lesson-06-web-svc
                port:
                  number: 80
```

Giải thích nhanh:

```yaml
ingressClassName: traefik
```

Ingress này được xử lý bởi Traefik Ingress Controller.

```yaml
tls:
  - hosts:
      - web.lab.local
    secretName: web-lab-local-tls
```

Khi client truy cập HTTPS tới `web.lab.local`, Ingress Controller dùng Secret `web-lab-local-tls` để terminate TLS.

```yaml
rules:
  - host: web.lab.local
```

Rule routing áp dụng cho request có HTTP Host header là `web.lab.local`.

```yaml
path: /
pathType: Prefix
```

Mọi path bắt đầu từ `/` đều đi vào backend này, trừ khi có rule khác cụ thể hơn.

```yaml
service:
  name: lesson-06-web-svc
  port:
    number: 80
```

Sau khi terminate HTTPS, Ingress chuyển request vào Service `lesson-06-web-svc` port 80.

### F. HTTP redirect sang HTTPS

Có hai cách với Traefik:

- Redirect theo router: Middleware `RedirectScheme` gắn vào Ingress HTTP (Lab 02, mục 12.8).
- Redirect toàn cục tại EntryPoint `web` sang `websecure`: dùng cấu hình Helm tương ứng với chart đã chọn; tác động mọi HTTP router và cần đánh giá ACME challenge trước khi áp dụng.

Trong lab chỉ dùng phương án đầu để app1/app2 và path demo vẫn chạy HTTP. TLS và redirect là hai cấu hình khác nhau. Nếu không có router HTTP, truy cập port 80 có thể nhận 404 thay vì redirect. Khi HTTPS dùng TLS Secret, Traefik vẫn cần router `websecure`.

```bash
kubectl get middleware -n lesson-06
kubectl describe ingress lesson-06-web-http -n lesson-06
curl -I --resolve web.lab.local:80:$INGRESS_IP http://web.lab.local/
curl --cacert web.lab.local.crt -I --resolve web.lab.local:443:$INGRESS_IP https://web.lab.local/
```

Kết quả kỳ vọng: Location HTTPS trên HTTP router có redirect; HTTPS 200.

### G. Nhiều domain dùng nhiều certificate

Một Ingress có thể khai báo nhiều host và nhiều TLS Secret.

Ví dụ:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-tls-ingress
  namespace: lesson-06
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app1.lab.local
      secretName: app1-lab-local-tls
    - hosts:
        - app2.lab.local
      secretName: app2-lab-local-tls
  rules:
    - host: app1.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app1-svc
                port:
                  number: 80
    - host: app2.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app2-svc
                port:
                  number: 80
```

Khi client truy cập HTTPS, TLS handshake dùng SNI để báo cho server biết domain client muốn truy cập. Ingress Controller dựa vào domain đó để chọn certificate phù hợp.

Mô hình:

```text
https://app1.lab.local
  -> dùng Secret app1-lab-local-tls
  -> route app1-svc

https://app2.lab.local
  -> dùng Secret app2-lab-local-tls
  -> route app2-svc
```

### H. Một certificate dùng cho nhiều domain

Có thể dùng một certificate chứa nhiều SAN:

```text
DNS:app1.lab.local
DNS:app2.lab.local
DNS:web.lab.local
```

Hoặc wildcard certificate:

```text
DNS:*.lab.local
```

Khi đó nhiều host có thể dùng chung một TLS Secret.

Ví dụ:

```yaml
tls:
  - hosts:
      - app1.lab.local
      - app2.lab.local
      - web.lab.local
    secretName: wildcard-lab-local-tls
```

Lưu ý:

- Wildcard `*.lab.local` chỉ match một cấp như `app1.lab.local`.
- Wildcard này không match `api.dev.lab.local` vì đó là nhiều hơn một DNS label phía trước `lab.local`.

### I. Path routing trong Ingress

Ingress không chỉ route theo domain, mà còn route theo URL path.

Ví dụ một domain duy nhất:

```text
https://portal.lab.local/
https://portal.lab.local/api
https://portal.lab.local/admin
```

Có thể route đến ba Service khác nhau:

```text
/       -> frontend-svc
/api    -> api-svc
/admin  -> admin-svc
```

Luồng:

```text
Client
  |
  | GET /api/v1/users
  | Host: portal.lab.local
  v
Traefik Ingress Controller
  |
  | rule host = portal.lab.local
  | path = /api
  v
api-svc
  |
  v
Pod API
```

Điểm cần nhớ:

- Ingress route theo HTTP Host header và URL path.
- Backend của Ingress vẫn là Service.
- Ingress không route trực tiếp vào Pod.
- Các path cụ thể hơn thường được ưu tiên hơn path tổng quát `/`.

### J. Ba loại pathType trong Kubernetes Ingress

Từ Kubernetes `networking.k8s.io/v1`, mỗi path bắt buộc phải có `pathType`.

Có ba loại chính:

```text
Exact
Prefix
ImplementationSpecific
```

#### J.1. pathType Exact

`Exact` match chính xác toàn bộ path, có phân biệt chữ hoa/chữ thường.

Ví dụ:

```yaml
path: /healthz
pathType: Exact
```

Match:

```text
/healthz
```

Không match:

```text
/healthz/
/healthz/live
/Healthz
```

Dùng khi:

- Health endpoint cụ thể.
- Callback endpoint cần đúng path.
- Route đặc biệt không muốn match các subpath phía sau.

#### J.2. pathType Prefix

`Prefix` match theo từng phần tử path, phân tách bởi dấu `/`.

Ví dụ:

```yaml
path: /api
pathType: Prefix
```

Match:

```text
/api
/api/
/api/v1
/api/v1/users
```

Không nên hiểu nhầm là string prefix thuần túy.

Theo ý nghĩa Kubernetes Ingress, `/api` không nên match:

```text
/apix
/api-v2
```

Vì `/api` là một path element riêng, còn `/apix` là element khác.

Dùng khi:

- Muốn route một nhóm URL vào cùng backend.
- Ví dụ `/api`, `/admin`, `/static`, `/media`.
- Ứng dụng backend tự hiểu subpath phía sau.

#### J.3. pathType ImplementationSpecific

`ImplementationSpecific` nghĩa là cách match phụ thuộc Ingress Controller. Traefik hỗ trợ annotation `traefik.ingress.kubernetes.io/router.pathmatcher` để lựa chọn matcher như `Path`, `PathPrefix`, `PathRegexp` tùy phiên bản.

Không nên dùng `ImplementationSpecific` nếu `Exact` hoặc `Prefix` đủ đáp ứng. Với bài rewrite ở mục O, dùng `Prefix` cho routing và Middleware cho rewrite; không cần regex trong Ingress path. Điều này phân biệt rõ routing và biến đổi URI.

### K. Thứ tự ưu tiên khi nhiều path cùng match

Theo Kubernetes Ingress API, path dài hơn được ưu tiên; nếu độ dài bằng nhau, `Exact` được ưu tiên hơn `Prefix`. Tuy nhiên Traefik mặc định tính router priority theo độ dài rule, không đảm bảo tự chọn Exact trước Prefix trong mọi trường hợp. Vì vậy demo N tách hai Ingress và đặt priority rõ ràng bằng annotation `traefik.ingress.kubernetes.io/router.priority`. Với demo L, các path không trùng độ dài có thể quan sát kết quả mặc định; thứ tự YAML không quyết định router priority.

Ví dụ:

```yaml
paths:
  - path: /api/v1
    pathType: Prefix
    backend: api-v1-svc

  - path: /api
    pathType: Prefix
    backend: api-svc

  - path: /
    pathType: Prefix
    backend: frontend-svc
```

Request:

```text
/api/v1/users
```

Sẽ đi vào:

```text
api-v1-svc
```

Không đi vào:

```text
api-svc
frontend-svc
```

Vì `/api/v1` cụ thể hơn `/api`, và `/api` cụ thể hơn `/`.

Ví dụ `Exact` và `Prefix` cùng tồn tại:

```yaml
paths:
  - path: /healthz
    pathType: Exact
    backend: health-svc

  - path: /healthz
    pathType: Prefix
    backend: api-svc
```

Request:

```text
/healthz
```

Đi vào:

```text
health-svc
```

Request:

```text
/healthz/live
```

Đi vào:

```text
api-svc
```

### L. Demo bổ sung 01 - Path routing bằng Prefix

#### L.1. Mục tiêu

Triển khai ba backend:

```text
frontend
api
admin
```

Dùng một domain:

```text
path.lab.local
```

Dùng một IP Ingress:

```text
10.10.10.240
```

Route theo path:

```text
http://path.lab.local/              -> frontend-svc
http://path.lab.local/api           -> api-svc
http://path.lab.local/api/v1/users  -> api-svc
http://path.lab.local/admin         -> admin-svc
http://path.lab.local/admin/users   -> admin-svc
```

#### L.2. Tạo namespace

```bash
kubectl create namespace ingress-path-demo
```

#### L.3. Tạo ba ứng dụng demo

Dùng image `hashicorp/http-echo` để backend trả về nội dung text đơn giản.

Tạo file:

```bash
cat <<'EOF' > path-demo-apps.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ingress-path-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:5678"
            - "-text=frontend service - root path"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: ingress-path-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:5678"
            - "-text=api service - /api prefix"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: api
  ports:
    - name: http
      port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admin
  namespace: ingress-path-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: admin
  template:
    metadata:
      labels:
        app: admin
    spec:
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:5678"
            - "-text=admin service - /admin prefix"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: admin-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: admin
  ports:
    - name: http
      port: 80
      targetPort: 5678
EOF
```

Apply:

```bash
kubectl apply -f path-demo-apps.yaml
```

Kiểm tra:

```bash
kubectl get pods -n ingress-path-demo -o wide
kubectl get svc -n ingress-path-demo
kubectl get endpointslice -n ingress-path-demo
```

#### L.4. Tạo Ingress path Prefix

Tạo file:

```bash
cat <<'EOF' > path-prefix-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-prefix-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: path.lab.local
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-svc
                port:
                  number: 80
          - path: /admin
            pathType: Prefix
            backend:
              service:
                name: admin-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f path-prefix-ingress.yaml
```

Kiểm tra:

```bash
kubectl get ingress -n ingress-path-demo
kubectl describe ingress path-prefix-ingress -n ingress-path-demo
```

#### L.5. Test bằng curl --resolve

Lấy IP Ingress:

```bash
export INGRESS_IP=$(kubectl get svc traefik \
  -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo $INGRESS_IP
```

Test root path:

```bash
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/
```

Kết quả kỳ vọng:

```text
frontend service - root path
```

Test `/api`:

```bash
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/api
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/api/
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/api/v1/users
```

Kết quả kỳ vọng:

```text
api service - /api prefix
```

Test `/admin`:

```bash
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/admin
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/admin/users
```

Kết quả kỳ vọng:

```text
admin service - /admin prefix
```

Test path không match `/api` theo path element:

```bash
curl -i --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/apix
```

Trong cách hiểu chuẩn của Kubernetes `Prefix`, `/apix` không phải là subpath của `/api`. Nếu không có rule nào cụ thể hơn, request sẽ rơi về rule `/` và đi vào frontend.

Kết quả kỳ vọng:

```text
frontend service - root path
```

#### L.6. Vì sao có thể viết path `/` ở cuối để dễ đọc?

Trong YAML trên, ta đặt:

```yaml
- path: /api
- path: /admin
- path: /
```

Mục đích là để người học dễ đọc từ rule cụ thể đến rule tổng quát.

Thứ tự khai báo chỉ để dễ đọc; Traefik lựa chọn theo rule và priority, không theo vị trí trong YAML.

### M. Demo bổ sung 02 - Kết hợp HTTPS + path Prefix

#### M.1. Mục tiêu

Dùng lại ba backend ở Demo bổ sung 01, nhưng publish bằng HTTPS:

```text
https://path.lab.local/
https://path.lab.local/api
https://path.lab.local/admin
```

TLS terminate tại Traefik Ingress Controller.

#### M.2. Tạo certificate cho path.lab.local

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout path.lab.local.key \
  -out path.lab.local.crt \
  -subj "/CN=path.lab.local/O=Kubernetes Lab" \
  -addext "subjectAltName=DNS:path.lab.local"
```

Tạo TLS Secret:

```bash
kubectl create secret tls path-lab-local-tls \
  --cert=path.lab.local.crt \
  --key=path.lab.local.key \
  -n ingress-path-demo
```

Kiểm tra:

```bash
kubectl get secret path-lab-local-tls -n ingress-path-demo
kubectl get secret path-lab-local-tls -n ingress-path-demo -o jsonpath='{.type}'; echo
```

Kết quả:

```text
kubernetes.io/tls
```

#### M.3. Cập nhật Ingress có TLS

Tạo file:

```bash
cat <<'EOF' > path-prefix-https-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-prefix-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - path.lab.local
      secretName: path-lab-local-tls
  rules:
    - host: path.lab.local
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-svc
                port:
                  number: 80
          - path: /admin
            pathType: Prefix
            backend:
              service:
                name: admin-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f path-prefix-https-ingress.yaml
```

Kiểm tra:

```bash
kubectl get ingress -n ingress-path-demo
kubectl describe ingress path-prefix-ingress -n ingress-path-demo
```

#### M.4. Test HTTPS

Test root path:

```bash
curl --cacert path.lab.local.crt --resolve path.lab.local:443:$INGRESS_IP https://path.lab.local/
```

Test API path:

```bash
curl --cacert path.lab.local.crt --resolve path.lab.local:443:$INGRESS_IP https://path.lab.local/api
curl --cacert path.lab.local.crt --resolve path.lab.local:443:$INGRESS_IP https://path.lab.local/api/v1/users
```

Test admin path:

```bash
curl --cacert path.lab.local.crt --resolve path.lab.local:443:$INGRESS_IP https://path.lab.local/admin
curl --cacert path.lab.local.crt --resolve path.lab.local:443:$INGRESS_IP https://path.lab.local/admin/users
```

Kiểm tra HTTP sau khi Ingress được chuyển sang `websecure`:

```bash
curl -I --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/api
```

Kết quả kỳ vọng: 404 nếu không còn HTTP router phù hợp. Nếu muốn redirect, tạo thêm HTTP Ingress và Middleware tương tự mục 12.8.


Kiểm tra certificate đang được trả ra:

```bash
openssl s_client -connect $INGRESS_IP:443 -servername path.lab.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Kết quả cần thấy certificate có subject tương ứng với `path.lab.local`.

### N. Demo bổ sung 03 - Exact so với Prefix

#### N.1. Mục tiêu

Chứng minh:

- `/healthz` với `Exact` chỉ match đúng `/healthz`.
- `/healthz/live` không match `Exact`.
- Nếu có thêm `/healthz` với `Prefix`, thì `/healthz/live` có thể đi vào backend Prefix.
- Khi request đúng `/healthz`, `Exact` được ưu tiên hơn `Prefix`.

#### N.2. Tạo hai backend

Tạo file:

```bash
cat <<'EOF' > exact-prefix-apps.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: health-exact
  namespace: ingress-path-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: health-exact
  template:
    metadata:
      labels:
        app: health-exact
    spec:
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:5678"
            - "-text=EXACT backend: /healthz only"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: health-exact-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: health-exact
  ports:
    - name: http
      port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: health-prefix
  namespace: ingress-path-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: health-prefix
  template:
    metadata:
      labels:
        app: health-prefix
    spec:
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:5678"
            - "-text=PREFIX backend: /healthz and subpaths"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: health-prefix-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: health-prefix
  ports:
    - name: http
      port: 80
      targetPort: 5678
EOF
```

Apply:

```bash
kubectl apply -f exact-prefix-apps.yaml
```
#### N.3. Tạo Ingress Exact và Prefix

Tách thành hai Ingress để cấu hình priority độc lập; priority 200 cao hơn 100.

```bash
cat <<'EOF' > exact-prefix-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: exact-health-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
    traefik.ingress.kubernetes.io/router.priority: "200"
spec:
  ingressClassName: traefik
  rules:
    - host: exact.lab.local
      http:
        paths:
          - path: /healthz
            pathType: Exact
            backend:
              service:
                name: health-exact-svc
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prefix-health-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
    traefik.ingress.kubernetes.io/router.priority: "100"
spec:
  ingressClassName: traefik
  rules:
    - host: exact.lab.local
      http:
        paths:
          - path: /healthz
            pathType: Prefix
            backend:
              service:
                name: health-prefix-svc
                port:
                  number: 80
EOF
kubectl apply -f exact-prefix-ingress.yaml
kubectl describe ingress exact-health-ingress -n ingress-path-demo
kubectl describe ingress prefix-health-ingress -n ingress-path-demo
```


#### N.4. Test Exact và Prefix

Request đúng `/healthz`:

```bash
curl --resolve exact.lab.local:80:$INGRESS_IP http://exact.lab.local/healthz
```

Kết quả kỳ vọng:

```text
EXACT backend: /healthz only
```

Request subpath `/healthz/live`:

```bash
curl --resolve exact.lab.local:80:$INGRESS_IP http://exact.lab.local/healthz/live
```

Kết quả kỳ vọng:

```text
PREFIX backend: /healthz and subpaths
```

Request sai chữ hoa/thường:

```bash
curl -i --resolve exact.lab.local:80:$INGRESS_IP http://exact.lab.local/Healthz
```

Kết quả kỳ vọng: HTTP 404 vì `Exact` và `Prefix` đều case-sensitive. Kiểm tra thêm `/healthzx`:

```bash
curl -i --resolve exact.lab.local:80:$INGRESS_IP http://exact.lab.local/healthzx
```

Kết quả: HTTP 404 với `strictPrefixMatching: true`.

### O. Demo bổ sung 04 - Rewrite path với Traefik

#### O.1. Khi nào cần rewrite path?

Không phải ứng dụng nào cũng biết mình đang được expose dưới subpath.

Ví dụ bên ngoài muốn expose:

```text
https://rewrite.lab.local/backend/api/users
```

Nhưng backend app thật ra chỉ hiểu:

```text
/api/users
```

Lúc này ta cần rewrite:

```text
/backend/api/users -> /api/users
```

Với Traefik, dùng Middleware `ReplacePathRegex` để thay prefix `/backend` bằng `/`. `StripPrefix` cũng phù hợp cho nhiều ứng dụng chạy ở subpath; ở đây chọn `ReplacePathRegex` để minh họa rõ việc trả về `/` khi request đúng `/backend`.

Rewrite là tính năng của controller, không phải hành vi mặc định của Ingress API.

#### O.2. Tạo backend echo request URI bằng nginx

Backend này trả về URI mà nó nhận được sau khi đi qua Ingress. Nhờ vậy học viên thấy được rewrite có tác dụng hay không.

Tạo file:

```bash
cat <<'EOF' > rewrite-echo-app.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rewrite-echo-nginx-conf
  namespace: ingress-path-demo
data:
  default.conf: |
    server {
      listen 80;

      location / {
        default_type text/plain;
        return 200 "backend received uri=$request_uri\nhost=$host\n";
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rewrite-echo
  namespace: ingress-path-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rewrite-echo
  template:
    metadata:
      labels:
        app: rewrite-echo
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: nginx-conf
          configMap:
            name: rewrite-echo-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: rewrite-echo-svc
  namespace: ingress-path-demo
spec:
  type: ClusterIP
  selector:
    app: rewrite-echo
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
```

Apply:

```bash
kubectl apply -f rewrite-echo-app.yaml
```

Kiểm tra:

```bash
kubectl get pods -n ingress-path-demo -l app=rewrite-echo
kubectl get svc rewrite-echo-svc -n ingress-path-demo
```

#### O.3. Tạo Middleware và Ingress rewrite

```bash
cat <<'EOF' > rewrite-ingress.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-backend
  namespace: ingress-path-demo
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  replacePathRegex:
    regex: '^/backend(/|$)(.*)'
    replacement: '/${2}'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rewrite-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
    traefik.ingress.kubernetes.io/router.middlewares: ingress-path-demo-strip-backend@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: rewrite.lab.local
      http:
        paths:
          - path: /backend
            pathType: Prefix
            backend:
              service:
                name: rewrite-echo-svc
                port:
                  number: 80
EOF
kubectl apply -f rewrite-ingress.yaml
kubectl get middleware -n ingress-path-demo
```

Kết quả kỳ vọng: `/backend` → `/`, `/backend/api/users` → `/api/users`; query string được giữ nguyên; `/backendx` không match (404).

#### O.4. Test rewrite

Test request vào `/backend`:

```bash
curl --resolve rewrite.lab.local:80:$INGRESS_IP http://rewrite.lab.local/backend
```

Kết quả kỳ vọng backend nhận URI:

```text
backend received uri=/
```

Test request vào `/backend/api/users`:

```bash
curl --resolve rewrite.lab.local:80:$INGRESS_IP http://rewrite.lab.local/backend/api/users
```

Kết quả kỳ vọng backend nhận URI:

```text
backend received uri=/api/users
```

Test query string:

```bash
curl --resolve rewrite.lab.local:80:$INGRESS_IP "http://rewrite.lab.local/backend/api/users?id=100"
```

Kết quả kỳ vọng backend nhận URI gần như:

```text
backend received uri=/api/users?id=100
```

#### O.5. Giải thích regex `/backend(/|$)(.*)`

Path:

```text
/backend(/|$)(.*)
```

Có thể hiểu:

```text
/backend
```

Là prefix bên ngoài muốn public.

```text
(/|$)
```

Sau `/backend` có thể là dấu `/` hoặc kết thúc chuỗi.

```text
(.*)
```

Phần còn lại của path, được lưu vào capture group số 2.

Middleware:

```yaml
replacement: '/${2}'
```


Nghĩa là phần path gửi vào backend sẽ thành:

```text
/<capture group 2>
```

Ví dụ:

```text
Request ngoài: /backend/api/users
Capture $2:    api/users
Rewrite thành: /api/users
```

### P. Demo bổ sung 05 - HTTPS + rewrite path

Có thể kết hợp TLS với rewrite.

Tạo certificate:

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout rewrite.lab.local.key \
  -out rewrite.lab.local.crt \
  -subj "/CN=rewrite.lab.local/O=Kubernetes Lab" \
  -addext "subjectAltName=DNS:rewrite.lab.local"
```

Tạo Secret:

```bash
kubectl create secret tls rewrite-lab-local-tls \
  --cert=rewrite.lab.local.crt \
  --key=rewrite.lab.local.key \
  -n ingress-path-demo
```

Tạo Ingress HTTPS + rewrite:

```bash
cat <<'EOF' > rewrite-https-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rewrite-ingress
  namespace: ingress-path-demo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: ingress-path-demo-strip-backend@kubernetescrd

spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - rewrite.lab.local
      secretName: rewrite-lab-local-tls
  rules:
    - host: rewrite.lab.local
      http:
        paths:
          - path: /backend
            pathType: Prefix
            backend:
              service:
                name: rewrite-echo-svc
                port:
                  number: 80
EOF
```

Apply:

```bash
kubectl apply -f rewrite-https-ingress.yaml
```

Test:

```bash
curl --cacert rewrite.lab.local.crt --resolve rewrite.lab.local:443:$INGRESS_IP https://rewrite.lab.local/backend/api/users
```

Kết quả kỳ vọng:

```text
backend received uri=/api/users
```

Kiểm tra HTTP sau khi Ingress được chuyển sang `websecure`:

```bash
curl -I --resolve rewrite.lab.local:80:$INGRESS_IP http://rewrite.lab.local/backend/api/users
```

Kết quả kỳ vọng: 404 nếu không có HTTP router. Để redirect, tạo thêm HTTP Ingress với Middleware RedirectScheme như mục 12.8.


### Q. Bảng tổng hợp các trường hợp Ingress path

| Nhu cầu | path | pathType | Backend | Ghi chú |
|---|---:|---|---|---|
| Website chính | `/` | `Prefix` | `frontend-svc` | Match toàn bộ nếu không có path cụ thể hơn |
| API service | `/api` | `Prefix` | `api-svc` | Match `/api`, `/api/v1`, `/api/users` |
| Admin portal | `/admin` | `Prefix` | `admin-svc` | Match `/admin`, `/admin/users` |
| Health check chính xác | `/healthz` | `Exact` | `health-svc` | Không match `/healthz/live` |
| Static assets | `/static` | `Prefix` | `static-svc` | Dùng cho file CSS/JS/image |
| Media upload | `/media` | `Prefix` | `media-svc` | Dùng cho user-uploaded content |
| Rewrite | `/backend` | `Prefix` | `rewrite-echo-svc` | Middleware ReplacePathRegex |
| Catch-all | `/` | `Prefix` | `frontend-svc` | Nên đặt sau các route cụ thể khi viết manifest |

### R. Troubleshooting riêng cho HTTPS và path routing

#### R.1. HTTPS báo certificate không tin cậy

Nếu dùng self-signed certificate trong lab, browser báo không tin cậy là bình thường.

Dùng curl:

```bash
curl -k https://web.lab.local/
```

Hoặc:

```bash
curl -k --resolve web.lab.local:443:$INGRESS_IP https://web.lab.local/
```

Trong production, cần dùng certificate được cấp bởi CA tin cậy hoặc CA nội bộ đã được client trust.

#### R.2. HTTPS trả về certificate không đúng domain

Kiểm tra SNI:

```bash
openssl s_client -connect $INGRESS_IP:443 -servername web.lab.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

Nếu không dùng `-servername`, server có thể trả default certificate, làm kết quả kiểm tra bị sai.

Kiểm tra Secret:

```bash
kubectl describe secret web-lab-local-tls -n lesson-06
```

Kiểm tra Ingress:

```bash
kubectl describe ingress lesson-06-web-https -n lesson-06
```

Các lỗi thường gặp:

- Secret sai namespace.
- Secret sai type.
- Secret thiếu `tls.crt` hoặc `tls.key`.
- Certificate không có SAN đúng domain.
- Host trong `tls.hosts` khác host trong `rules`.
- Client truy cập bằng IP thay vì domain.

#### R.3. HTTP không redirect sang HTTPS

Kiểm tra HTTP router có tồn tại và có gắn Middleware RedirectScheme đúng namespace hay không:

```bash
kubectl get ingress,middleware -n lesson-06
kubectl describe ingress lesson-06-web-http -n lesson-06
kubectl describe middleware redirect-https -n lesson-06
```

Không có redirect tự động chỉ vì có TLS. Kiểm tra Location từ `curl -I` và log Traefik.

#### R.4. Path `/api` được nhưng `/api/v1/users` không được

Kiểm tra `pathType`:

```yaml
pathType: Prefix
```

Nếu dùng `Exact`, `/api/v1/users` sẽ không match `/api`.

Kiểm tra backend app có tự xử lý subpath đó không. Ingress route đúng chưa chắc app trả về 200. Có thể Ingress đã chuyển request vào đúng backend, nhưng app trả 404 vì app không có route tương ứng.

#### R.5. Request vào `/api` nhưng backend nhận path `/api`

Đây là hành vi bình thường nếu không rewrite.

Ví dụ:

```text
Client gọi: /api/users
Backend nhận: /api/users
```

Nếu backend chỉ muốn nhận:

```text
/users
```

Tạo Middleware `StripPrefix` hoặc `ReplacePathRegex`, sau đó tham chiếu qua annotation `traefik.ingress.kubernetes.io/router.middlewares` như mục O.


#### R.6. Ingress trả 404

404 thường là request không match host/path.

Kiểm tra:

```bash
kubectl describe ingress -n ingress-path-demo
```

Test đúng Host header:

```bash
curl -H "Host: path.lab.local" http://$INGRESS_IP/api
```

Hoặc dùng `--resolve`:

```bash
curl --resolve path.lab.local:80:$INGRESS_IP http://path.lab.local/api
```

Nếu gọi trực tiếp bằng IP:

```bash
curl http://$INGRESS_IP/api
```

Có thể bị 404 vì thiếu Host header đúng.

#### R.7. Ingress trả 503

Với allowEmptyServices=true, 503 có thể là router đã match nhưng không có endpoint sẵn sàng; lỗi kết nối backend cũng có thể trả 502/504.

Kiểm tra:

```bash
kubectl get svc -n ingress-path-demo
kubectl get endpointslice -n ingress-path-demo
kubectl get pods -n ingress-path-demo --show-labels
```

Các lỗi hay gặp:

- Service selector không khớp label Pod.
- Pod chưa Running.
- Pod không Ready.
- targetPort sai.
- Container không listen port đã khai báo.

#### R.8. Rewrite chạy không như kỳ vọng

```bash
kubectl get middleware -n ingress-path-demo
kubectl describe middleware strip-backend -n ingress-path-demo
kubectl describe ingress rewrite-ingress -n ingress-path-demo
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=100 --prefix=true
```

Kiểm tra tên Middleware, namespace, CRD, regex, replacement và entrypoint. Dùng backend echo URI để xác minh path thực nhận. Traefik không sinh cấu hình `nginx.conf`; không dùng `nginx -T` để troubleshoot controller.


### S. Bài tập thực hành thêm cho học viên

#### S.1. Bài tập 1 - Tạo portal có ba path

Yêu cầu:

- Domain: `student.lab.local`
- `/` đi vào `home-svc`
- `/api` đi vào `api-svc`
- `/admin` đi vào `admin-svc`
- Có HTTPS bằng self-signed certificate.
- Test được bằng `curl --resolve`.

#### S.2. Bài tập 2 - Exact health check

Yêu cầu:

- Domain: `student-health.lab.local`
- `/healthz` dùng `Exact`, trả về `OK`.
- `/healthz/live` dùng `Prefix`, trả về `LIVE`.
- Chứng minh `/Healthz` không match `/healthz`.

#### S.3. Bài tập 3 - Rewrite path

Yêu cầu:

- Domain: `student-rewrite.lab.local`
- Public path: `/service/api/users`
- Backend nhận path: `/api/users`
- Dùng Middleware `StripPrefix` hoặc `ReplacePathRegex`.
- Dùng HTTPS.
- Chứng minh bằng backend echo URI.

### T. Dọn dẹp tài nguyên phần bổ sung

Xóa toàn bộ namespace demo:

```bash
kubectl delete namespace ingress-path-demo
```

Xóa file certificate local nếu muốn:

```bash
rm -f path.lab.local.crt path.lab.local.key
rm -f rewrite.lab.local.crt rewrite.lab.local.key
```

Nếu đã thêm hosts trên client, xóa các dòng tương ứng:

```text
path.lab.local
exact.lab.local
rewrite.lab.local
```

### U. Ghi nhớ nhanh cho phần bổ sung

- HTTPS trong Ingress thường là TLS termination tại Ingress Controller.
- Kubernetes dùng trường `spec.tls`, không dùng tên trường `ssl`.
- TLS Secret phải cùng namespace với Ingress.
- Certificate phải có SAN đúng domain.
- `Prefix` không phải string prefix đơn giản, mà match theo path element.
- `Exact` match chính xác và case-sensitive.
- `ImplementationSpecific` phụ thuộc Ingress Controller; ưu tiên Exact/Prefix khi có thể.
- Path cụ thể hơn được ưu tiên hơn path tổng quát.
- Nếu cùng path, Kubernetes API quy định Exact ưu tiên; trong Traefik demo đặt priority rõ ràng.
- Không có rewrite thì backend thường nhận nguyên path client gọi.
- Với ReplacePathRegex cần hiểu capture group `${1}`, `${2}`; StripPrefix không cần regex.
- Khi test bằng IP trực tiếp, dễ thiếu Host header và bị 404.
- `curl --resolve` là công cụ rất tốt để test Ingress trong lab mà không cần sửa DNS.

### V. Tài liệu tham khảo bổ sung

- Kubernetes Documentation - Ingress path types  
  https://kubernetes.io/docs/concepts/services-networking/ingress/#path-types

- Kubernetes Documentation - Multiple matches  
  https://kubernetes.io/docs/concepts/services-networking/ingress/#multiple-matches

- Traefik Kubernetes Ingress routing: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/ingress/
- Traefik Middleware: https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/overview/
- Traefik StripPrefix: https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/stripprefix/
- Traefik ReplacePathRegex: https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/replacepathregex/


## 14. Lab tổng hợp cuối buổi

## 14.1. Yêu cầu bài lab

Học viên cần tự triển khai hoàn chỉnh các yêu cầu sau:

- Cài Helm trên `k8s-master-01`.
- Cài MetalLB bằng Helm.
- Cấu hình MetalLB IP pool:
  - `10.10.10.240-10.10.10.250`
- Cài Traefik Ingress Controller bằng Helm.
- Đảm bảo Service `traefik` nhận được external IP từ MetalLB.
- Tạo namespace `production-web`.
- Triển khai một ứng dụng nginx gồm:
  - Deployment 3 replicas.
  - ConfigMap chứa `index.html`.
  - Service type `ClusterIP`.
- Tạo Ingress HTTP cho domain:
  - `prod-web.lab.local`
- Tạo self-signed certificate cho:
  - `prod-web.lab.local`
- Tạo TLS Secret.
- Cập nhật Ingress để hỗ trợ HTTPS.
- Test được:
  - `http://prod-web.lab.local`
  - `https://prod-web.lab.local`
- Kiểm tra log của Ingress Controller.
- Xác định Pod backend nào đang phục vụ request.

## 14.2. Gợi ý manifest tổng hợp

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-web
```

### ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prod-web-content
  namespace: production-web
data:
  index.html: |
    <h1>Production Web on Kubernetes</h1>
    <p>Exposed by Traefik Ingress Controller and MetalLB.</p>
```

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prod-web
  namespace: production-web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: prod-web
  template:
    metadata:
      labels:
        app: prod-web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: content
          configMap:
            name: prod-web-content
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: prod-web-svc
  namespace: production-web
spec:
  type: ClusterIP
  selector:
    app: prod-web
  ports:
    - name: http
      port: 80
      targetPort: 80
```

### Ingress HTTP/HTTPS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prod-web-ingress
  namespace: production-web
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - prod-web.lab.local
      secretName: prod-web-tls
  rules:
    - host: prod-web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prod-web-svc
                port:
                  number: 80
```

## 14.3. Lệnh tạo certificate cho bài lab tổng hợp

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout prod-web.lab.local.key \
  -out prod-web.lab.local.crt \
  -subj "/CN=prod-web.lab.local/O=Kubernetes Lab" \
  -addext "subjectAltName=DNS:prod-web.lab.local"
```

Tạo Secret:

```bash
kubectl create secret tls prod-web-tls \
  --cert=prod-web.lab.local.crt \
  --key=prod-web.lab.local.key \
  -n production-web
```

## 14.4. Lệnh kiểm tra

Để có cả HTTP và HTTPS trong lab tổng hợp, tạo thêm HTTP Ingress riêng với cùng host (không bật redirect nếu muốn HTTP 200):

```bash
cat <<'EOF' > prod-web-http.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prod-web-http
  namespace: production-web
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: prod-web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prod-web-svc
                port:
                  number: 80
EOF
kubectl apply -f prod-web-http.yaml
```

```bash
kubectl get all -n production-web
kubectl get ingress -n production-web
kubectl describe ingress prod-web-ingress -n production-web
kubectl get svc -n traefik
kubectl logs -n traefik deploy/traefik --tail=100
```

Test HTTP:

```bash
curl --resolve prod-web.lab.local:80:10.10.10.240 http://prod-web.lab.local/
```

Test HTTPS:

```bash
curl --cacert prod-web.lab.local.crt --resolve prod-web.lab.local:443:10.10.10.240 https://prod-web.lab.local/
```

## 15. Troubleshooting

## 15.1. Service LoadBalancer bị EXTERNAL-IP `<pending>`

Kiểm tra Service:

```bash
kubectl get svc -n traefik
```

Nếu thấy:

```text
EXTERNAL-IP   <pending>
```

Nguyên nhân thường gặp:

- MetalLB chưa cài.
- MetalLB chưa có `IPAddressPool`.
- MetalLB chưa có `L2Advertisement`.
- IP pool không hợp lệ.
- IP pool không cùng mạng Layer 2 với node.
- MetalLB controller lỗi.
- MetalLB speaker lỗi.
- Namespace `metallb-system` thiếu Pod Security label `privileged`.

Lệnh kiểm tra:

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
kubectl get deployment -n metallb-system
# Use the controller deployment name shown above
kubectl logs -n metallb-system deploy/metallb-controller  # Adjust to actual name if different
```

## 15.2. MetalLB cấp IP nhưng client không truy cập được

Kiểm tra:

```bash
kubectl get svc -n traefik
curl -v --connect-timeout 5 --resolve web.lab.local:80:10.10.10.240 http://web.lab.local/
```

Nguyên nhân thường gặp:

- Client không có route tới IP pool hoặc gateway không thể ARP tới IP (client không bắt buộc cùng subnet nếu routing đúng).
- Firewall chặn.
- IP pool trùng với thiết bị khác.
- ARP cache bị cũ.
- Không có route đến subnet chứa IP pool.
- Ingress Controller chưa chạy.
- Service của Ingress Controller chưa có endpoint.

Kiểm tra endpoint:

```bash
kubectl get endpointslice -n traefik
```

## 15.3. Truy cập domain bị lỗi DNS

Test bằng `curl --resolve` để loại trừ lỗi DNS:

```bash
curl --resolve web.lab.local:80:10.10.10.240 http://web.lab.local/
```

Nếu `curl --resolve` được nhưng browser không được, lỗi nằm ở DNS hoặc file hosts.

Kiểm tra từ client:

```bash
nslookup web.lab.local
ping web.lab.local
```

## 15.4. Ingress trả về 404

Traefik trả 404 thường do request không match rule.

Kiểm tra:

```bash
kubectl describe ingress -n lesson-06
```

Các lỗi thường gặp:

- Sai hostname.
- Client không gửi đúng Host header.
- Dùng IP trực tiếp thay vì domain.
- Sai `path`.
- Sai `ingressClassName`.
- Ingress không được controller nhận.

Test đúng Host header:

```bash
curl -H "Host: web.lab.local" http://10.10.10.240/
```

## 15.5. Ingress trả về 503

Với allowEmptyServices=true, 503 thường gặp khi router match nhưng không có endpoint sẵn sàng. Cần phân biệt lỗi 502/504 khi kết nối backend thất bại.

Kiểm tra Service:

```bash
kubectl get svc -n lesson-06
kubectl describe svc lesson-06-web-svc -n lesson-06
```

Kiểm tra EndpointSlice:

```bash
kubectl get endpointslice -n lesson-06
```

Kiểm tra Pod label:

```bash
kubectl get pods -n lesson-06 --show-labels
```

Nguyên nhân thường gặp:

- Service selector không match label của Pod.
- Pod chưa Running.
- Pod không Ready.
- targetPort sai.
- Container không lắng nghe port tương ứng.

## 15.6. HTTPS báo lỗi certificate

Nếu dùng self-signed certificate, browser sẽ cảnh báo không tin cậy. Đây là bình thường trong lab.

Nếu dùng `curl`, thêm `-k`:

```bash
curl -k https://web.lab.local/
```

Nếu vẫn lỗi, kiểm tra:

```bash
kubectl describe secret web-lab-local-tls -n lesson-06
kubectl describe ingress lesson-06-web-https -n lesson-06
openssl s_client -connect 10.10.10.240:443 -servername web.lab.local
```

Các lỗi thường gặp:

- Secret không cùng namespace với Ingress.
- Secret không đúng type `kubernetes.io/tls`.
- Certificate không có SAN đúng domain.
- Host trong `tls.hosts` không khớp host trong `rules`.
- Client truy cập bằng IP thay vì domain.

## 15.7. Helm install thất bại

Kiểm tra release và event trước khi thay đổi:

```bash
helm status traefik -n traefik
helm status metallb -n metallb-system
kubectl get pods -n traefik
kubectl get events -n traefik --sort-by=.lastTimestamp
```

Kiểm tra values, chart version, CRD, quyền và image pull. Nếu nâng cấp lỗi, xem `helm history` và đánh giá rollback. Không uninstall MetalLB/Traefik đang phục vụ ứng dụng chỉ vì release failed.


Với CRD của MetalLB, cần cẩn thận trước khi xóa trong môi trường production.

## 16. Các lệnh quan trọng cần nhớ

### Helm

```bash
helm version
helm repo add <name> <url>
helm repo update
helm search repo <keyword>
helm show values <chart>
helm upgrade --install <release> <chart> -n <namespace> --create-namespace
helm list -A
helm status <release> -n <namespace>
helm uninstall <release> -n <namespace>
```

### MetalLB

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
kubectl get deployment -n metallb-system
# Use the controller deployment name shown above
kubectl logs -n metallb-system deploy/metallb-controller  # Adjust to actual name if different
```

### Traefik

```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
kubectl get ingressclass
kubectl logs -n traefik deploy/traefik
```

### Ingress

```bash
kubectl get ingress -A
kubectl describe ingress <name> -n <namespace>
kubectl get svc -n <namespace>
kubectl get endpointslice -n <namespace>
```

### cert-manager

```bash
kubectl get certificate,certificaterequest,issuer -A
kubectl get clusterissuer
kubectl get order,challenge -A
kubectl describe certificate <name> -n <namespace>
```

### Test HTTP/HTTPS

```bash
curl -H "Host: web.lab.local" http://10.10.10.240/
curl --resolve web.lab.local:80:10.10.10.240 http://web.lab.local/
curl -k --resolve web.lab.local:443:10.10.10.240 https://web.lab.local/
openssl s_client -connect 10.10.10.240:443 -servername web.lab.local
```

## 17. Câu hỏi kiểm tra cuối buổi

### Câu 1

Helm dùng để làm gì trong Kubernetes?

Gợi ý trả lời:

Helm là package manager cho Kubernetes, giúp đóng gói, cài đặt, nâng cấp và gỡ bỏ các ứng dụng hoặc thành phần hạ tầng thông qua Helm Chart.

### Câu 2

Chart và Release khác nhau như thế nào?

Gợi ý trả lời:

Chart là gói template Kubernetes manifest. Release là một lần cài đặt cụ thể của chart vào cluster.

### Câu 3

Vì sao Service type `LoadBalancer` trên kubeadm on-premise thường bị `<pending>`?

Gợi ý trả lời:

Vì Kubernetes on-premise không tự có cloud provider hoặc cloud-controller-manager để cấp external load balancer. Cần một thành phần như MetalLB để cấp IP cho Service type `LoadBalancer`.

### Câu 4

MetalLB Controller và MetalLB Speaker khác nhau như thế nào?

Gợi ý trả lời:

Controller xử lý logic cấp phát IP cho Service type `LoadBalancer`. Speaker chạy trên node và quảng bá IP ra mạng, ví dụ trả lời ARP trong Layer 2 mode.

### Câu 5

Vì sao IP pool của MetalLB không nên trùng dải DHCP?

Gợi ý trả lời:

Nếu IP pool trùng DHCP, một IP có thể vừa được MetalLB cấp cho Service, vừa được DHCP cấp cho thiết bị khác, gây IP conflict và lỗi truy cập.

### Câu 6

Ingress là gì?

Gợi ý trả lời:

Ingress là Kubernetes API object dùng để định nghĩa rule HTTP/HTTPS routing từ bên ngoài cluster vào Service bên trong cluster.

### Câu 7

Vì sao chỉ tạo Ingress object là chưa đủ?

Gợi ý trả lời:

Ingress object chỉ là cấu hình. Cần Ingress Controller để đọc cấu hình đó và thực thi bằng reverse proxy/load balancer.

### Câu 8

`ingressClassName: traefik` có ý nghĩa gì?

Gợi ý trả lời:

Nó chỉ định Ingress object này sẽ được xử lý bởi Ingress Controller tương ứng với class `traefik`.

### Câu 9

HTTPS trong bài lab được terminate ở đâu?

Gợi ý trả lời:

HTTPS được terminate tại Traefik Ingress Controller. Traffic từ client đến Ingress Controller là HTTPS, còn traffic từ Ingress Controller đến backend Service trong lab là HTTP.

### Câu 10

Nếu Ingress trả về 503, nên kiểm tra những gì?

Gợi ý trả lời:

Cần kiểm tra Service selector, Pod label, Pod readiness, EndpointSlice, targetPort và trạng thái Pod backend.

### Câu 11

Ingress NGINX EOL có nghĩa là Ingress API hoặc nginx web server bị xóa không?

Gợi ý trả lời: Không. Đây là retirement của community ingress-nginx controller; Ingress API và nginx web server là những thành phần khác.

### Câu 12

cert-manager khác Traefik như thế nào? Certificate lưu ở đâu?

Gợi ý trả lời: cert-manager cấp/gia hạn certificate và ghi vào TLS Secret; Traefik đọc Secret và terminate TLS, thực thi routing.

### Câu 13

Vì sao không xin Let's Encrypt cho web.lab.local? Khi nào dùng DNS-01?

Gợi ý trả lời: .local không phải domain public hợp lệ để CA công cộng xác thực. DNS-01 cần public authoritative DNS cho domain hợp lệ, phù hợp wildcard hoặc ứng dụng internal không mở port 80.

## 18. Tổng kết buổi học

Sau buổi này, học viên đã biết cách đưa ứng dụng web ra ngoài cluster theo mô hình gần với thực tế hơn so với NodePort đơn thuần.

Các điểm cần nhớ:

- Helm giúp cài đặt các thành phần Kubernetes phức tạp một cách có cấu trúc.
- MetalLB giúp môi trường on-premise có khả năng cấp external IP cho Service type `LoadBalancer`.
- MetalLB Layer 2 mode phù hợp cho lab và môi trường nhỏ vì đơn giản, không cần BGP.
- Ingress là object định nghĩa rule HTTP/HTTPS routing.
- Ingress Controller là thành phần thực thi các rule đó.
- Traefik Ingress Controller có thể expose ra ngoài thông qua Service type `LoadBalancer`.
- Trong lab on-premise, IP của Service type `LoadBalancer` được cấp bởi MetalLB.
- Một IP Ingress có thể phục vụ nhiều ứng dụng web khác nhau dựa trên hostname hoặc path.
- TLS Secret cho phép Ingress Controller terminate HTTPS.
- cert-manager tự động cấp/gia hạn certificate và cập nhật TLS Secret; Traefik đọc Secret để phục vụ TLS.
- HTTP-01 và DNS-01 là cơ chế xác thực ACME, không phải phương thức routing.
- Khi troubleshoot Ingress, cần đi theo chuỗi:
  - DNS/Host header.
  - MetalLB external IP.
  - Traefik Service.
  - Ingress rule.
  - Backend Service.
  - EndpointSlice.
  - Pod backend.

## 19. Dọn dẹp tài nguyên lab

Nếu muốn xóa ứng dụng lab:

```bash
kubectl delete namespace lesson-06 ingress-path-demo production-web --ignore-not-found=true --wait=true
```

Giữ lại Helm, MetalLB, Traefik và cert-manager cho các buổi tiếp theo.

## 20. Tài liệu tham khảo chính thức

- Kubernetes v1.35 Documentation - Ingress  
  https://v1-35.docs.kubernetes.io/docs/concepts/services-networking/ingress/

- Kubernetes v1.35 Documentation - Ingress Controllers  
  https://v1-35.docs.kubernetes.io/docs/concepts/services-networking/ingress-controllers/

- Helm Documentation - Installing Helm  
  https://helm.sh/docs/intro/install/

- Helm Documentation - Quickstart Guide  
  https://helm.sh/docs/intro/quickstart/

- MetalLB Documentation - Installation  
  https://metallb.io/installation/

- MetalLB Documentation - Configuration  
  https://metallb.io/configuration/

- Kubernetes - Ingress NGINX retirement: https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/
- Traefik Proxy - Kubernetes installation: https://doc.traefik.io/traefik/setup/kubernetes/
- Traefik Helm chart values: https://github.com/traefik/traefik-helm-chart/blob/master/traefik/VALUES.md
- Traefik Kubernetes Ingress provider: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/
- cert-manager installation: https://cert-manager.io/docs/installation/helm/
- cert-manager supported releases: https://cert-manager.io/docs/releases/
- cert-manager Ingress: https://cert-manager.io/docs/usage/ingress/
- cert-manager HTTP-01: https://cert-manager.io/docs/configuration/acme/http01/
- cert-manager DNS-01: https://cert-manager.io/docs/configuration/acme/dns01/
- Cloudflare solver: https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/
- cmctl: https://cert-manager.io/docs/reference/cmctl/
- Traefik Middleware: https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/

