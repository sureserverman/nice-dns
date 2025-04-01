#!/bin/bash

# resconffile="/etc/systemd/resolved.conf"

#Check if there are installed previous versions
if [ $(sudo podman ps -a | grep -c "tor-socat\|unbound\|pi-hole") -gt 0 ]
  then
    #Remove them if exist
    sudo podman stop pi-hole &>/dev/null
    sudo podman rm pi-hole &>/dev/null
    sudo podman image rm nice-dns-web-pi-hole:latest &>/dev/null
    sudo podman stop unbound &>/dev/null
    sudo podman rm unbound &>/dev/null
    sudo podman image rm nice-dns-web-unbound:latest&>/dev/null
    sudo podman stop tor-socat &>/dev/null
    sudo podman rm tor-socat &>/dev/null
    sudo podman image rm sureserver/tor-socat:latest &>/dev/null
    sudo podman network rm nice-dns-web_dnsnet &>/dev/null
    sudo sed -i -e 's/^DNS=/#DNS=/g' $resconffile
    # if [[ $(sudo grep "^#DNS=1.1.1.1" $resconffile) = "" ]]
    #   then
    #     sudo echo "DNS=1.1.1.1" | sudo tee -a $resconffile
    #   else
    #     sudo sed -i -e 's/^#DNS=1.1.1.1/DNS=1.1.1.1/g' $resconffile
    #   fi
    # sudo systemctl enable systemd-resolved
    # sudo systemctl restart systemd-resolved
  else
    #Install required software
    sudo apt-get install -yq git podman podman-compose
fi

#Disable stub listener for DNS
# if [[ $(sudo grep "DNSStubListener" $resconffile) = "" ]]
#   then
#     sudo echo "DNSStubListener=no" | sudo tee -a $resconffile
#   else
#     sudo sed -i -e 's/#DNSStubListener/DNSStubListener/g' $resconffile
#     sudo sed -i -e 's/DNSStubListener=yes/DNSStubListener=no/g' $resconffile
#   fi

#Use installed containers ad default DNS-server
# Comment all DNS server settings
# sudo sed -i -e 's/^DNS=/#DNS=/g' $resconffile

#Check if there is no line with 127.0.0.1
# if [[ $(sudo grep "^#DNS=127.0.0.1" $resconffile) = "" ]]
#   then
#     #Add one if there is none
#     sudo echo "DNS=127.0.0.1" | sudo tee -a $resconffile
#   else
#     #Uncomment if there is one
#     sudo sed -i -e 's/^#DNS=127.0.0.1/DNS=127.0.0.1/g' $resconffile
#   fi

#Start podman containers
git clone https://github.com/sureserverman/nice-dns.git
cd nice-dns
podman compose --env-file .env up -d
cd -
rm -rf nice-dns

#Apply changes to DNS resolver settings
sudo systemctl restart systemd-resolved