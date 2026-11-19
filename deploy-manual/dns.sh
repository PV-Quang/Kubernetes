#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# BIND9 DNS deployment for Ubuntu 24.04
# Based on the user's dns.md layout:
#   - Local forward zone
#   - Reverse zone
#   - Public forward zone
#   - IPv4 only
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    echo "[ERROR] Run this script as root or with sudo."
    exit 1
fi

BIND_DIR="/etc/bind"
SERIAL="$(date +%Y%m%d)01"
BACKUP_DIR="/root/bind-backup-$(date +%Y%m%d-%H%M%S)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LOCAL_RECORDS="$TMP_DIR/local_records"
PUBLIC_RECORDS="$TMP_DIR/public_records"
PTR_RECORDS="$TMP_DIR/ptr_records"
: > "$LOCAL_RECORDS"
: > "$PUBLIC_RECORDS"
: > "$PTR_RECORDS"

prompt_nonempty() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "$prompt" value
        value="${value//[$'\t\r\n']/}"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return 0
        fi
        echo "Value cannot be empty." >&2
    done
}

valid_ipv4() {
    local ip="$1"
    python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

valid_hostname() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

cidr_info() {
    local cidr="$1"
    python3 - "$cidr" <<'PY'
import ipaddress, sys
try:
    n = ipaddress.IPv4Network(sys.argv[1], strict=False)
except Exception as e:
    print(f"ERROR:{e}")
    raise SystemExit(1)

if n.prefixlen not in (8, 16, 24):
    print("ERROR:Only /8, /16 and /24 are supported for automatic reverse-zone generation")
    raise SystemExit(2)

o = str(n.network_address).split('.')
p = n.prefixlen
if p == 8:
    reverse = f"{o[0]}.in-addr.arpa"
elif p == 16:
    reverse = f"{o[1]}.{o[0]}.in-addr.arpa"
else:
    reverse = f"{o[2]}.{o[1]}.{o[0]}.in-addr.arpa"

print(n.with_prefixlen)
print(reverse)
PY
}

ip_in_cidr() {
    local ip="$1"
    local cidr="$2"
    python3 - "$ip" "$cidr" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
net = ipaddress.IPv4Network(sys.argv[2], strict=False)
raise SystemExit(0 if ip in net else 1)
PY
}

ptr_owner() {
    local ip="$1"
    local cidr="$2"
    python3 - "$ip" "$cidr" <<'PY'
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
net = ipaddress.IPv4Network(sys.argv[2], strict=False)
parts = str(ip).split('.')
if net.prefixlen == 24:
    print(parts[3])
elif net.prefixlen == 16:
    print(f"{parts[3]}.{parts[2]}")
elif net.prefixlen == 8:
    print(f"{parts[3]}.{parts[2]}.{parts[1]}")
else:
    raise SystemExit(1)
PY
}

add_records() {
    local zone_type="$1"
    local output_file="$2"
    local domain="$3"
    local add_ptr="$4"

    echo
    echo "============================================================"
    echo "Add A records for ${zone_type} zone: ${domain}"
    echo "Example: master01 -> 10.0.0.11"
    echo "Press Enter on hostname when finished."
    echo "============================================================"

    while true; do
        local host ip answer owner
        read -r -p "Hostname: " host
        [[ -z "$host" ]] && break

        if ! valid_hostname "$host"; then
            echo "[ERROR] Invalid hostname: $host"
            continue
        fi

        read -r -p "IPv4 address for ${host}.${domain}: " ip
        if ! valid_ipv4 "$ip"; then
            echo "[ERROR] Invalid IPv4 address: $ip"
            continue
        fi

        printf "%-24s IN  A       %s\n" "$host" "$ip" >> "$output_file"

        if [[ "$add_ptr" == "yes" ]] && ip_in_cidr "$ip" "$LOCAL_CIDR"; then
            read -r -p "Create PTR ${ip} -> ${host}.${domain}? [Y/n]: " answer
            answer="${answer:-Y}"
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                owner="$(ptr_owner "$ip" "$LOCAL_CIDR")"
                printf "%-12s IN  PTR     %s.%s.\n" "$owner" "$host" "$domain" >> "$PTR_RECORDS"
            fi
        fi
    done
}

clear
echo "============================================================"
echo " BIND9 DNS SERVER DEPLOYMENT - Ubuntu 24.04"
echo "============================================================"
echo

while true; do
    DNS_SERVER_IP="$(prompt_nonempty 'DNS server IPv4 address: ')"
    valid_ipv4 "$DNS_SERVER_IP" && break
    echo "[ERROR] Invalid IPv4 address: $DNS_SERVER_IP"
done

while true; do
    LOCAL_DOMAIN="$(prompt_nonempty 'Local domain (example: k8s.local): ')"
    valid_domain "$LOCAL_DOMAIN" && break
    echo "[ERROR] Invalid domain: $LOCAL_DOMAIN"
done

while true; do
    PUBLIC_DOMAIN="$(prompt_nonempty 'Public domain (example: tanlv.io.vn): ')"
    valid_domain "$PUBLIC_DOMAIN" && break
    echo "[ERROR] Invalid domain: $PUBLIC_DOMAIN"
done

while true; do
    LOCAL_CIDR_INPUT="$(prompt_nonempty 'Local IPv4 network CIDR (example: 10.0.0.0/24): ')"
    if mapfile -t CIDR_DATA < <(cidr_info "$LOCAL_CIDR_INPUT" 2>/dev/null); then
        if [[ ${#CIDR_DATA[@]} -ge 2 ]]; then
            LOCAL_CIDR="${CIDR_DATA[0]}"
            REVERSE_ZONE="${CIDR_DATA[1]}"
            break
        fi
    fi
    echo "[ERROR] Invalid/unsupported CIDR. Use /8, /16 or /24."
done

LOCAL_ZONE_FILE="${BIND_DIR}/${LOCAL_DOMAIN}"
PUBLIC_ZONE_FILE="${BIND_DIR}/${PUBLIC_DOMAIN}"
REVERSE_DB_NAME="${REVERSE_ZONE%.in-addr.arpa}.db"
REVERSE_ZONE_FILE="${BIND_DIR}/${REVERSE_DB_NAME}"

# Default records matching the structure in dns.md
printf "%-24s IN  A       %s\n" "dns" "$DNS_SERVER_IP" >> "$LOCAL_RECORDS"
printf "%-24s IN  A       %s\n" "dns" "$DNS_SERVER_IP" >> "$PUBLIC_RECORDS"

if ip_in_cidr "$DNS_SERVER_IP" "$LOCAL_CIDR"; then
    DNS_PTR_OWNER="$(ptr_owner "$DNS_SERVER_IP" "$LOCAL_CIDR")"
    printf "%-12s IN  PTR     dns.%s.\n" "$DNS_PTR_OWNER" "$LOCAL_DOMAIN" >> "$PTR_RECORDS"
else
    echo "[WARN] DNS server IP $DNS_SERVER_IP is outside $LOCAL_CIDR, so no PTR is created for dns.${LOCAL_DOMAIN}."
fi

add_records "LOCAL" "$LOCAL_RECORDS" "$LOCAL_DOMAIN" "yes"
add_records "PUBLIC" "$PUBLIC_RECORDS" "$PUBLIC_DOMAIN" "no"

echo
echo "============================================================"
echo "Configuration summary"
echo "============================================================"
printf "DNS server IP : %s\n" "$DNS_SERVER_IP"
printf "Local domain  : %s\n" "$LOCAL_DOMAIN"
printf "Public domain : %s\n" "$PUBLIC_DOMAIN"
printf "Local CIDR    : %s\n" "$LOCAL_CIDR"
printf "Reverse zone  : %s\n" "$REVERSE_ZONE"
echo
cat "$LOCAL_RECORDS"
echo
cat "$PUBLIC_RECORDS"
echo
cat "$PTR_RECORDS"
echo

read -r -p "Deploy this configuration? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled. No configuration was changed."
    exit 0
fi

echo "[1/8] Updating Ubuntu packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "[2/8] Installing BIND9..."
apt-get install -y bind9 bind9utils

echo "[3/8] Backing up current BIND configuration to ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"
cp -a /etc/bind "$BACKUP_DIR/"
[[ -f /etc/default/named ]] && cp -a /etc/default/named "$BACKUP_DIR/named.default"

echo "[4/8] Configuring named.conf..."
if ! grep -Fq 'include "/etc/bind/named.conf.internal-zones";' /etc/bind/named.conf; then
    printf '\ninclude "/etc/bind/named.conf.internal-zones";\n' >> /etc/bind/named.conf
fi

echo "[5/8] Creating named.conf.options and zone definitions..."
cat > /etc/bind/named.conf.options <<EOF_OPTIONS
acl internal-network {
        ${LOCAL_CIDR};
};
options {
        directory "/var/cache/bind";

        // Forwarders intentionally left disabled, matching dns.md.
        // BIND will use normal recursive DNS resolution for zones it does not host.
        // forwarders {
        //      8.8.8.8;
        // };

        dnssec-validation auto;

        listen-on-v6 { none; };
};
EOF_OPTIONS

cat > /etc/bind/named.conf.internal-zones <<EOF_ZONES
zone "${LOCAL_DOMAIN}" IN {
        type primary;
        file "${LOCAL_ZONE_FILE}";
        allow-update { none; };
};
zone "${REVERSE_ZONE}" IN {
        type primary;
        file "${REVERSE_ZONE_FILE}";
        allow-update { none; };
};
zone "${PUBLIC_DOMAIN}" IN {
        type primary;
        file "${PUBLIC_ZONE_FILE}";
        allow-update { none; };
};
EOF_ZONES

cat > /etc/default/named <<'EOF_DEFAULT'
# run resolvconf?
#RESOLVCONF=no

# startup options for the server
#OPTIONS="-u bind"
OPTIONS="-u bind -4"
EOF_DEFAULT

echo "[6/8] Creating zone files..."
cat > "$LOCAL_ZONE_FILE" <<EOF_LOCAL
\$TTL 86400
@   IN  SOA     dns.${LOCAL_DOMAIN}. root.${LOCAL_DOMAIN}. (
        ${SERIAL}  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        IN  NS      dns.${LOCAL_DOMAIN}.
        IN  A       ${DNS_SERVER_IP}

$(cat "$LOCAL_RECORDS")
EOF_LOCAL

cat > "$PUBLIC_ZONE_FILE" <<EOF_PUBLIC
\$TTL 86400
@   IN  SOA     dns.${PUBLIC_DOMAIN}. root.${PUBLIC_DOMAIN}. (
        ${SERIAL}  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        IN  NS      dns.${PUBLIC_DOMAIN}.
        IN  A       ${DNS_SERVER_IP}

$(cat "$PUBLIC_RECORDS")
EOF_PUBLIC

cat > "$REVERSE_ZONE_FILE" <<EOF_REVERSE
\$TTL 86400
@   IN  SOA     dns.${LOCAL_DOMAIN}. root.${LOCAL_DOMAIN}. (
        ${SERIAL}  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        IN  NS      dns.${LOCAL_DOMAIN}.

$(cat "$PTR_RECORDS")
EOF_REVERSE

chown root:bind /etc/bind/named.conf.options \
                /etc/bind/named.conf.internal-zones \
                "$LOCAL_ZONE_FILE" \
                "$PUBLIC_ZONE_FILE" \
                "$REVERSE_ZONE_FILE"
chmod 0644 /etc/bind/named.conf.options \
           /etc/bind/named.conf.internal-zones \
           "$LOCAL_ZONE_FILE" \
           "$PUBLIC_ZONE_FILE" \
           "$REVERSE_ZONE_FILE"

echo "[7/8] Validating BIND configuration..."
named-checkconf
named-checkzone "$REVERSE_ZONE" "$REVERSE_ZONE_FILE"
named-checkzone "$LOCAL_DOMAIN" "$LOCAL_ZONE_FILE"
named-checkzone "$PUBLIC_DOMAIN" "$PUBLIC_ZONE_FILE"

echo "[8/8] Restarting named..."
systemctl restart named
systemctl enable named >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " DEPLOYMENT COMPLETE"
echo "============================================================"
systemctl --no-pager --full status named || true

echo
echo "Generated files:"
echo "  /etc/bind/named.conf.internal-zones"
echo "  /etc/bind/named.conf.options"
echo "  ${LOCAL_ZONE_FILE}"
echo "  ${PUBLIC_ZONE_FILE}"
echo "  ${REVERSE_ZONE_FILE}"
echo
echo "Backup: ${BACKUP_DIR}"
echo
echo "Useful checks:"
echo "  named-checkconf"
echo "  named-checkzone ${LOCAL_DOMAIN} ${LOCAL_ZONE_FILE}"
echo "  named-checkzone ${PUBLIC_DOMAIN} ${PUBLIC_ZONE_FILE}"
echo "  named-checkzone ${REVERSE_ZONE} ${REVERSE_ZONE_FILE}"
echo "  systemctl status named"
echo "============================================================"
