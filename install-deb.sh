#!/usr/bin/env bash
set -euo pipefail

resconffile="/etc/systemd/resolved.conf"

#Check if there are installed previous versions
if [ "$(sudo docker ps -a | grep -c "tor-socat\|unbound\|pi-hole")" -gt 0 ]
  then
    #Remove them if exist
    sudo docker stop pi-hole &>/dev/null
    sudo docker rm pi-hole &>/dev/null
    sudo docker image rm nice-dns-web-pi-hole:latest &>/dev/null
    sudo docker stop unbound &>/dev/null
    sudo docker rm unbound &>/dev/null
    sudo docker image rm nice-dns-web-unbound:latest&>/dev/null
    sudo docker stop tor-socat &>/dev/null
    sudo docker rm tor-socat &>/dev/null
    sudo docker image rm sureserver/tor-socat:latest &>/dev/null
    sudo docker network rm nice-dns-web_dnsnet &>/dev/null
    sudo sed -i -e 's/^DNS=/#DNS=/g' $resconffile
    if [[ $(sudo grep "^#DNS=1.1.1.1" $resconffile) = "" ]]
      then
        sudo echo "DNS=1.1.1.1" | sudo tee -a $resconffile
      else
        sudo sed -i -e 's/^#DNS=1.1.1.1/DNS=1.1.1.1/g' $resconffile
      fi
    sudo systemctl enable systemd-resolved
    sudo systemctl restart systemd-resolved
  else
    #Install required software
    sudo apt-get install -yq git docker docker-compose
fi

#Start docker containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
sudo docker compose --env-file .env up -d
cd -
rm -rf nice-dns

#Apply changes to DNS resolver settings
sudo systemctl restart systemd-resolved