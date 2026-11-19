## HƯỚNG DẪN CÀI RANCHER

link tham khảo:

resource yều cầu 4 CPU 4G RAM

https://docs.docker.com/engine/install/ubuntu/

https://hub.docker.com/r/rancher/rancher/tags

https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/other-installation-methods/rancher-on-a-single-node-with-docker

## 1.INSTALL DOCKER

1. Set up Docker's apt repository

```
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

2. Install the Docker packages

```
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## 2. INSTALL RANCHER

```
docker pull rancher/rancher:latest
```

tạo thư mục /opt/certs chứa 3 file cert.pem (file fullchain)  và key.pem (file privatekey)và cacerts.pem (file chain)( fullchain bỏ block đầu )

```
docker run -d --restart=unless-stopped \
  -p 80:80 -p 443:443 \
  --privileged \
  -v /opt/rancher:/var/lib/rancher \
  -v /opt/certs/cert.pem:/etc/rancher/ssl/cert.pem \
  -v /opt/certs/key.pem:/etc/rancher/ssl/key.pem \
  -v /opt/certs/cacerts.pem:/etc/rancher/ssl/cacerts.pem \
  rancher/rancher:latest
```
kiêm tra sau cài đặt
```
docker ps
```
![image](https://github.com/user-attachments/assets/14135825-6d2b-428b-a215-d1365ac22b77)

Nếu bị restart liên tục là chưa được

Một số lệnh tham khảo để check nếu bị lỗi
```
docker stop fervent_pascal
docker rm fervent_pascal
rm -rf /opt/rancher/k3s/server/db/reset-flag
rm -rf /opt/rancher
```

## 3. ĐĂNG NHẬP RANCHER, ĐỔI PASS VÀ ADD CỤM K8S
1. Đổi pass
```
docker logs  436b7e911463  2>&1 | grep "Bootstrap Password:"
```
436b7e911463 là container id chạy rancher, tìm qua lệnh docker ps, lấy được pass đem qua giao diện đổi pass

2. ADD CỤM K8S
![image](https://github.com/user-attachments/assets/d3cd4ab4-341f-49d9-8ad4-08b21b0e048b)
![image](https://github.com/user-attachments/assets/475623c6-bd8a-4cfd-9bb2-ef4c6bf4ad88)
![image](https://github.com/user-attachments/assets/89436646-6d5d-46a1-b8db-3f8ee0905343)

3. login con master-01, chạy lệnh số 2 để add cụm k8s vô rancher quản lí

![image](https://github.com/user-attachments/assets/69d8044f-5ec7-426a-b84b-ed115ff3f3ad)

sau đó đợi lên trạng thái active là xong
![image](https://github.com/user-attachments/assets/6f38f009-7401-4ee8-ac37-54f066c63c4c)

trong qua trình đợi có thể check theo dõi trạn thái của pod cattle-system qua lệnh:
```
kubectl get pods -A
```

![image](https://github.com/user-attachments/assets/6646e1e2-017b-445d-8a3d-5ab0598e4260)
