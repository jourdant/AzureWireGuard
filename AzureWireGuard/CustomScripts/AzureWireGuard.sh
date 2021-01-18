#!/bin/bash

##
## USAGE:    AzureWireGuard.sh [number_of_clients] [local_user_name] [fqdn] [port] [dns]
## EXAMPLE:  AzureWireGuard.sh 10 myuseraccount wgserver.example.com 443 1.1.1.1
##

## config
total_clients=$1
wireguard_interface_name=wg0
wireguard_interface_path=/etc/wireguard/$wireguard_interface_name.conf
wireguard_fqdn=$3
wireguard_port=$4
wireguard_client_dns=$5
tunnel_folder_path=/home/$2/$wireguard_fqdn-$wireguard_interface_name-client

## unattended-upgrade
apt-get update -y
unattended-upgrades --verbose

## IP Forwarding
sed -i -e 's/#net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sed -i -e 's/#net.ipv6.conf.all.forwarding.*/net.ipv6.conf.all.forwarding=1/g' /etc/sysctl.conf
sysctl -p

## Install WireGurard
apt-get update -y
apt-get install linux-headers-$(uname -r) -y
apt-get install wireguard -y
down_temp=$(wg-quick down $wireguard_interface_name)

## Configure WireGuard
mkdir -p $tunnel_folder_path
umask 077

# Generate configuration files
server_private_key=$(wg genkey)
server_public_key=$(echo $server_private_key | wg pubkey)
preshared_key=$(wg genpsk)

cat > $wireguard_interface_path << EOF
[Interface]
Address = 10.13.13.1/24
SaveConfig = true
PrivateKey = $server_private_key
ListenPort = $wireguard_port
PostUp = iptables -A FORWARD -i $wireguard_interface_name -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; ip6tables -A FORWARD -i $wireguard_interface_name -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i $wireguard_interface_name -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; ip6tables -D FORWARD -i $wireguard_interface_name -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

#iterate over each client and generate keys
for i in $(seq 1 $total_clients)
do
    #generate keys
    echo "[CLIENT $i]  Generating keys for wireguard..."
    client_private_key=$(wg genkey)
    client_public_key=$(echo $client_private_key | wg pubkey)

    #get client ip
    ip=$(expr $i + 10)

    #add to wg server config
    echo "[CLIENT $i]  Updating server config with new peer..."
    cat >> $wireguard_interface_path << EOF
[Peer]
PublicKey =  $client_public_key
PresharedKey = $preshared_key
AllowedIps = 10.13.13.$ip/32
EOF

    #generate wg tunnel file
    tunnel_file_path=$tunnel_folder_path/$wireguard_fqdn-$wireguard_interface_name-client-$i.conf
    echo "[CLIENT $i]  Saving tunnel config file to: $tunnel_file_path..."
    cat > $tunnel_file_path << EOF
[Interface]
PrivateKey = $client_private_key
Address = 10.13.13.$ip/32
DNS = $wireguard_client_dns

[Peer]
PublicKey =  $server_public_key
PresharedKey = $preshared_key
EndPoint = $wireguard_fqdn:$wireguard_port
AllowedIps = 0.0.0.0/0, ::/0
PersistentKeepAlive = 25
EOF

    chmod go+r $tunnel_file_path
done


## Firewall
ufw allow $wireguard_port/udp
ufw allow 22/tcp
ufw enable

## WireGuard Service
wg-quick up $wireguard_interface_name
systemctl enable wg-quick@$wireguard_interface_name

## Upgrade
apt-get full-upgrade -y

## Shutdown
shutdown -r 1440