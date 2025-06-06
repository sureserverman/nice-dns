#!/usr/bin/env bash
set -euo pipefail

sudo cp custom-dns-deb.service /etc/systemd/system/custom-dns-deb.service
chmod +x custom-dns-deb
sudo cp custom-dns-deb /usr/bin/custom-dns-deb
sudo systemctl daemon-reload
sudo systemctl enable --now custom-dns-deb.service