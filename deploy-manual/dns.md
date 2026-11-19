## HƯỚNG DẪN CÀI DNS SERVER

Trên server có add thêm 1 ổ đĩa 200G dev/sdb1 mount đến /data

```
apt -y update && apt -y upgrade
```

```
apt -y install bind9 bind9utils
```

```
vi /etc/bind/named.conf
```

thêm vào cuối file
```
include "/etc/bind/named.conf.internal-zones";
```

```
// This is the primary configuration file for the BIND DNS server named.
//
// Please read /usr/share/doc/bind9/README.Debian for information on the
// structure of BIND configuration files in Debian, *BEFORE* you customize
// this configuration file.
//
// If you are just adding zones, please do that in /etc/bind/named.conf.local

include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
include "/etc/bind/named.conf.default-zones";
include "/etc/bind/named.conf.internal-zones";

```

```
vi /etc/bind/named.conf.options
```

```

acl internal-network {
        10.0.0.0/24;
};
options {
        directory "/var/cache/bind";

        // If there is a firewall between you and nameservers you want
        // to talk to, you may need to fix the firewall to allow multiple
        // ports to talk.  See http://www.kb.cert.org/vuls/id/800113

        // If your ISP provided one or more IP addresses for stable
        // nameservers, you probably want to use them as forwarders.
        // Uncomment the following block, and insert the addresses replacing
        // the all-0's placeholder.

        // forwarders {
        //      0.0.0.0;
        // };

        //========================================================================
        // If BIND logs error messages about the root key being expired,
        // you will need to update your keys.  See https://www.isc.org/bind-keys
        //========================================================================
        dnssec-validation auto;

        listen-on-v6 { none; };
};

```

```
vi /etc/bind/named.conf.internal-zones
```

```
zone "k8s.local" IN {
        type primary;
        file "/etc/bind/k8s.local";
        allow-update { none; };
};
zone "0.0.10.in-addr.arpa" IN {
        type primary;
        file "/etc/bind/0.0.10.db";
        allow-update { none; };
};
zone "tanlv.io.vn" IN {
        type primary;
        file "/etc/bind/tanlv.io.vn";
        allow-update { none; };
};

```

```
vi /etc/default/named
```

```
# run resolvconf?
#RESOLVCONF=no

# startup options for the server
#OPTIONS="-u bind"
OPTIONS="-u bind -4"
```

```
vi /etc/bind/k8s.local
```

```
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
        IN  A       10.0.0.250

dns              IN  A       10.0.0.250
master01         IN  A       10.0.0.11
master02         IN  A       10.0.0.12
master03         IN  A       10.0.0.13
worker01         IN  A       10.0.0.21
worker02         IN  A       10.0.0.22
worker03         IN  A       10.0.0.23
haproxy          IN  A       10.0.0.30
rancher          IN  A       10.0.0.40
tke-k8s          IN  A       10.0.0.30

```

```
vi /etc/bind/tanlv.io.vn
```

```
$TTL 86400
@   IN  SOA     dns.tanlv.io.vn. root.tanlv.io.vn. (
        ;; any numerical values are OK for serial number
        ;; recommended : [YYYYMMDDnn] (update date + number)
        2024042901  ;Serial
        3600        ;Refresh
        1800        ;Retry
        604800      ;Expire
        86400       ;Minimum TTL
)
        IN  NS      dns.tanlv.io.vn.
        IN  A       10.0.0.250

tke-k8s                 IN  A       10.0.0.30
rancher                 IN  A       10.0.0.40
dns                     IN  A       10.0.0.250
```

```
 vi /etc/bind/0.0.10.db
```

```
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
12       IN  PTR     master02.k8s.local.
13       IN  PTR     master03.k8s.local.
21       IN  PTR     worker01.k8s.local.
22       IN  PTR     worker02.k8s.local.
23       IN  PTR     worker03.k8s.local.
30       IN  PTR     haproxy.k8s.local.
40       IN  PTR     rancher.k8s.local.
```

```
named-checkconf
named-checkzone 0.0.10.in-addr.arpa /etc/bind/0.0.10.db
named-checkzone k8s.local /etc/bind/k8s.local
named-checkzone tanlv.io.vn /etc/bind/tanlv.io.vn
systemctl restart named
systemctl status named
```




