#!/usr/bin/env bash
set -euo pipefail

########################################
# CUSTOMER CONFIGURATION (EDIT HERE ONLY)
########################################
# ---- Network ----
NET_IFACE="ens192"
IP_ADDR="20.0.0.250"
CIDR="24"
GATEWAY="20.0.0.1"
DNS_ADDR="8.8.8.8"
DNS_SEARCH="k8s.local"

# ---- Hostname ----
HOSTNAME_FQDN="dns.k8s.local"

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
sed -i "2i 127.0.1.1 ${HOSTNAME_FQDN}" /etc/hosts
sed -i '3i\\' /etc/hosts

apt -y install bind9 bind9utils

cat > /etc/bind/named.conf <<'EOF'
include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
include "/etc/bind/named.conf.default-zones";
include "/etc/bind/named.conf.internal-zones";
EOF

cat > /etc/bind/named.conf.options <<'EOF'
acl internal-network {
        20.0.0.0/24;
};
options {
        directory "/var/cache/bind";
        dnssec-validation auto;
        listen-on-v6 { none; };
};
EOF

cat > /etc/bind/named.conf.internal-zones <<'EOF'
zone "k8s.local" IN {
        type primary;
        file "/etc/bind/k8s.local";
        allow-update { none; };
};
zone "0.0.20.in-addr.arpa" IN {
        type primary;
        file "/etc/bind/0.0.20.db";
        allow-update { none; };
};
EOF

cat > /etc/default/named <<'EOF'
# run resolvconf?
#RESOLVCONF=no

# startup options for the server
#OPTIONS="-u bind"
OPTIONS="-u bind -4"
EOF

cat > /etc/bind/k8s.local <<'EOF'
$TTL 86400
@   IN  SOA     dns.k8s.local. root.k8s.local. (
        ;; any numerical values are OK for serial number
        ;; recommended : [YYYYMMDDnn] (update date + number)
        2024042901  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        IN  NS      dns.k8s.local.
        IN  A       20.0.0.250

dns              IN  A       20.0.0.250
master01         IN  A       20.0.0.11
master02         IN  A       20.0.0.12
EOF

cat > /etc/bind/0.0.20.db <<'EOF'
$TTL 86400
@   IN  SOA     dns.k8s.local. root.k8s.local. (
        2024042901  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        ;; define Name Server
        IN  NS      dns.k8s.local.

250      IN  PTR     dns.k8s.local.
11       IN  PTR     master01.k8s.local.
EOF

echo "[INFO] Enabling bind9..."
systemctl enable --now bind9
systemctl restart bind9

echo "[INFO] Waiting for local DNS..."
for i in $(seq 1 10); do
  if dig @127.0.0.1 dns.k8s.local +short >/dev/null 2>&1; then
    echo "[INFO] Local DNS OK"
    break
  fi
  sleep 2
done

echo "[INFO] Switching DNS to local server ${IP_ADDR}"

sed -i "s/- ${DNS_ADDR}/- ${IP_ADDR}/" /etc/netplan/k8s.yaml
netplan apply

