#!/bin/bash

# resconffile="/etc/systemd/resolved.conf"

#Check if there are installed previous versions
if [ $(sudo podman ps -a | grep -c "tor-socat\|unbound\|pi-hole") -gt 0 ]
  then
    #Remove them if exist
    podman stop pi-hole &>/dev/null
    podman rm pi-hole &>/dev/null
    podman image rm nice-dns-web-pi-hole:latest &>/dev/null
    podman stop unbound &>/dev/null
    podman rm unbound &>/dev/null
    podman image rm nice-dns-web-unbound:latest&>/dev/null
    podman stop tor-socat &>/dev/null
    podman rm tor-socat &>/dev/null
    podman image rm sureserver/tor-socat:latest &>/dev/null
    podman network rm nice-dns-web_dnsnet &>/dev/null
  else
    #Install required software
    sudo apt-get install -yq git podman podman-compose
fi

#Start podman containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman compose --env-file .env up -d
cd -
rm -rf nice-dns

#Apply changes to DNS resolver settings
sudo systemctl restart systemd-resolved