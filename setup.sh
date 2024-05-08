#!/bin/bash

# Check if prerequisites are met
read -p "Have you set up a disconnected registry? (Y/N): " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Proceeding with the installation..."
else
    echo "Please set up a disconnected registry first."
    echo "Refer to the following link for guidance: https://docs.openshift.com/container-platform/4.15/installing/disconnected_install/installing-mirroring-disconnected.html"
    exit 1
fi


# Variable declaration
echo "Enter the starting IP address range: e.g. 192.168.3.91"
read starting_ip

echo "Enter the domain name: e.g. ocp.com"
read base_domain

echo "Enter the cluster name: e.g. babbar"
read cluster_name

echo "Enter the pull-secret"
read pull_secret

echo "Enter the ssh-key"
read ssh_key

echo "Enter the local quay ca-bundle (from disconnected registry)"
read ca_bundle


# Functions

# Function to check if firewall is disabled
check_firewall_disabled() {
    if systemctl is-active --quiet firewalld && systemctl is-enabled --quiet firewalld; then
        echo "Firewall is already disabled. Skipping..."
        return 0
    else
        return 1
    fi
}

# Function to disable firewall
disable_firewall() {
    echo "Disabling firewall..."
    systemctl stop firewalld
    systemctl disable firewalld
    echo "Firewall disabled."
}

# Function to check if SELinux is disabled
check_selinux_disabled() {
    selinux_status=$(getenforce)
    if [ "$selinux_status" = "Disabled" ]; then
        echo "SELinux is already disabled. Skipping..."
        return 0
    else
        return 1
    fi
}

# Function to disable SELinux
disable_selinux() {
    echo "Disabling SELinux..."
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
    echo "SELinux disabled."
}

# Function to install packages
install_packages() {
    packages=("$@")  # Store all arguments as an array
    for package in "${packages[@]}"; do
        if ! yum list installed "$package" &>/dev/null; then  # Check if package is not already installed
            echo "Installing $package..."
            sudo yum install -y "$package"
            echo "$package installed."
        else
            echo "$package is already installed. Skipping..."
        fi
    done
}

# Function to restart and enable services
restart_and_enable_services() {
    services=("$@")  # Store all arguments as an array
    for service in "${services[@]}"; do
        echo "Restarting and enabling $service..."
        sudo systemctl restart "$service"
        sudo systemctl enable "$service"
        echo "$service restarted and enabled."
    done
}


# Function to generate HAProxy configuration file
generate_haproxy_config() {
    local ip=$1

# Function to increment IP address by a given value
    increment_ip() {
        local ip=$1
        local increment=$2
        IFS='.' read -r -a ip_parts <<< "$ip"
        ip_parts[3]=$(( ${ip_parts[3]} + $increment ))
        echo "${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.${ip_parts[3]}"
    }

# Generate HAProxy configuration
    cat > /etc/haproxy.cfg <<EOF
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats
    ssl-default-bind-ciphers PROFILE=SYSTEM
    ssl-default-server-ciphers PROFILE=SYSTEM

defaults
    mode                    tcp
    log                     global
    option                  httplog
    option                  dontlognull
    option http-server-close
    option forwardfor       except 127.0.0.0/8
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

listen ingress-http
    bind *:80
    mode tcp
    server worker1 $(increment_ip $ip 4):80 check
    server worker2 $(increment_ip $ip 5):80 check
    server worker3 $(increment_ip $ip 6):80 check
    server master1 $(increment_ip $ip 1):80 check
    server master2 $(increment_ip $ip 2):80 check
    server master3 $(increment_ip $ip 3):80 check

listen ingress-https
    bind *:443
    mode tcp
    server worker1 $(increment_ip $ip 4):443 check
    server worker2 $(increment_ip $ip 5):443 check
    server worker3 $(increment_ip $ip 6):443 check
    server master1 $(increment_ip $ip 1):443 check
    server master2 $(increment_ip $ip 2):443 check
    server master3 $(increment_ip $ip 3):443 check

listen api
    bind *:6443
    mode tcp
    server bootstrap $(increment_ip $ip 1):6443 check
    server master1 $(increment_ip $ip 1):6443 check
    server master2 $(increment_ip $ip 2):6443 check
    server master3 $(increment_ip $ip 3):6443 check

listen api-int
    bind *:22623
    mode tcp
    server bootstrap $(increment_ip $ip 1):22623 check
    server master1 $(increment_ip $ip 1):22623 check
    server master2 $(increment_ip $ip 2):22623 check
    server master3 $(increment_ip $ip 3):22623 check
EOF

    echo "HAProxy configuration file generated: haproxy.cfg"
}



# Function to create install-config.yaml
create_install_config() {
    cat <<EOF >/root/install/workspace/ocp/install-config.yaml
apiVersion: v1
baseDomain: $base_domain
compute:
- hyperthreading: Enabled
  name: worker
  replicas: 3
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 3
metadata:
  name: $cluster_name
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
fips: false
pullSecret: '$pull_secret'
sshKey: '$ssh_key'
additionalTrustBundle: |
  $ca_bundle
imageContentSources:
- mirrors:
  - registry.babbar.ocp.com:8443/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - registry.babbar.ocp.com:8443/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
}

# Convert starting IP to an array for manipulation
IFS='.' read -r -a ip_parts <<< "$starting_ip"

# Function to generate DNS records
generate_dns_forward() {
    cat <<EOF >/var/named/forward.zone
\$TTL 300
@       IN      SOA     bastion.$cluster_name.$base_domain. admin.$cluster_name.$base_domain. (
                2019120303   ; Serial
                1450         ; Refresh
                145          ; Retry
                604800       ; Expire
                300          ; TTL
                )
                IN      NS      bastion.$cluster_name.$base_domain.
                IN      NS      admin.$cluster_name.$base_domain.
EOF

    # Array of hostnames
    hostnames=(
        "bastion"
        "admin"
        "haproxy.$cluster_name.$base_domain."
        "registry.$cluster_name.$base_domain."
        "bastion.$cluster_name.$base_domain."
        "bootstrap.$cluster_name.$base_domain."
        "master01.$cluster_name.$base_domain."
        "master02.$cluster_name.$base_domain."
        "master03.$cluster_name.$base_domain."
        "etcd-1.$cluster_name.$base_domain."
        "etcd-2.$cluster_name.$base_domain."
        "etcd-3.$cluster_name.$base_domain."
        "worker01.$cluster_name.$base_domain."
        "worker02.$cluster_name.$base_domain."
        "worker03.$cluster_name.$base_domain."
        "api.$cluster_name.$base_domain."
        "api-int.$cluster_name.$base_domain."
        "*.apps.$cluster_name.$base_domain."
    )

    # Loop through hostnames and append IP addresses
    for ((i = 0; i < ${#hostnames[@]}; i++)); do
        ip="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$(( ${ip_parts[3]} + $i ))"
        echo "${hostnames[$i]}         IN      A       $ip" >>dns_records.txt
    done
}



# Convert starting IP to an array for manipulation
IFS='.' read -r -a ip_parts <<< "$starting_ip"

# Function to generate DNS records
generate_dns_reverse() {
    cat <<EOF >/var/named/reverse.zone
\$TTL 300
@ IN SOA bastion.$cluster_name.$base_domain. admin.$cluster_name.$base_domain. (
    2022042601 ;Serial (increment this when you update the zone file)
    3600 ;Refresh (1 hour)
    900 ;Retry (15 minutes)
    604800 ;Expire (1 week)
    300 ;Minimum TTL (5 minutes)
)

; Name Server Information
@ IN NS bastion.$cluster_name.$base_domain.

; A records
;bastion.$cluster_name.$base_domain.  IN A $starting_ip

; Reverse lookup for Name Server
$(( ${ip_parts[3]} )) IN PTR bastion.$cluster_name.$base_domain.

; PTR Records (IP address to Hostname)
$(( ${ip_parts[3]} )) IN PTR haproxy.$cluster_name.$base_domain.
$(( ${ip_parts[3]} )) IN PTR api.$cluster_name.$base_domain.
$(( ${ip_parts[3]} )) IN PTR api-int.$cluster_name.$base_domain.
$(( ${ip_parts[3]} )) IN PTR bastion.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 1 )) IN PTR bootstrap.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 2 )) IN PTR master01.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 3 )) IN PTR master02.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 4 )) IN PTR master03.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 5 )) IN PTR worker01.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 6 )) IN PTR worker02.$cluster_name.$base_domain.
$(( ${ip_parts[3]} + 7 )) IN PTR worker03.$cluster_name.$base_domain.
EOF
}

# Function to generate named.conf file
generate_named_conf() {
    cat <<EOF >/etc/named.conf
options {
        listen-on port 53 { 127.0.0.1; $starting_ip; };
        listen-on-v6 port 53 { ::1; };
        directory       "/var/named";
        dump-file       "/var/named/data/cache_dump.db";
        statistics-file "/var/named/data/named_stats.txt";
        memstatistics-file "/var/named/data/named_mem_stats.txt";
        secroots-file   "/var/named/data/named.secroots";
        recursing-file  "/var/named/data/named.recursing";
        allow-query     { localhost; $starting_ip; any; };
        forwarders    { 10.75.5.25; 10.38.5.26; $starting_ip; };

        recursion yes;

        dnssec-enable yes;
        dnssec-validation yes;

        managed-keys-directory "/var/named/dynamic";

        pid-file "/run/named/named.pid";
        session-keyfile "/run/named/session.key";
        /* https://fedoraproject.org/wiki/Changes/CryptoPolicy */
        include "/etc/crypto-policies/back-ends/bind.config";
};

logging {
        channel default_debug {
                file "data/named.run";
                severity dynamic;
        };
};

zone "." IN {
        type hint;
        file "named.ca";
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";

//forward zone
zone "$base_domain" IN {
     type master;
     file "forward.zone";
     allow-update { none; };
    allow-query {any; };
};
//backward zone
zone "${starting_ip##*.}.${starting_ip%.*}.in-addr.arpa" IN {
     type master;
     file "reverse.zone";
     allow-update { none; };
    allow-query { any; };
};
EOF
}



##### Function calling #####

# disabling firewall and selinux
echo "Checking firewall status..."
check_firewall_disabled
firewall_check_result=$?

echo "Checking SELinux status..."
check_selinux_disabled
selinux_check_result=$?

if [ $firewall_check_result -eq 0 ] && [ $selinux_check_result -eq 0 ]; then
    echo "Firewall and SELinux are already disabled. Nothing to do."
else
    if [ $firewall_check_result -ne 0 ]; then
        disable_firewall
    fi

    if [ $selinux_check_result -ne 0 ]; then
        disable_selinux
    fi

    echo "Firewall and SELinux disabled successfully."
fi

# Call the function to install packages
install_packages bind bind-utils httpd haproxy

# Call the function to generate named.conf forward.zone reverse.zone file
generate_named_conf
generate_dns_forward
generate_dns_reverse

# Call the function to generate HAProxy configuration file
generate_haproxy_config "$starting_ip"

# Call the function to restart and enable services
restart_and_enable_services named httpd haproxy

# Call the function to create the install-config.yaml
rm -rvf /tmp/ocp
mkdir -p /tmp/ocp
create_install_config

# Create manifests and ignition configs
openshift-install create manifests --dir /tmp/ocp
openshift-install create ignition-configs --dir /tmp/ocp

# Base64 encode the ignition configs
for i in $(ls /tmp/ocp/*.ign); do base64 -w0 $i > $i.64 ; done

exit 0
