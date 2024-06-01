#!/bin/bash

#Install required software
sudo apt-get install -yq git docker docker-compose

#Start docker containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
sudo docker compose up -d
cd -
rm -rf nice-dns

#Use installed containers ad default DNS-server
sudo echo "DNS=127.0.0.1" | sudo tee -a /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved

#Deny in firewall any alternative DNS servers
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow out to 192.168.180.242 port 53
sudo ufw deny out 53
sudo ufw --force enable