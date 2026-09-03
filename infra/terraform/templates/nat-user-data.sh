#!/usr/bin/env bash
set -euxo pipefail

cat >/etc/sysctl.d/99-nat.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system

dnf install -y iptables-services
systemctl enable --now iptables
iptables -P FORWARD ACCEPT
iptables -t nat -A POSTROUTING -o "$(ip route show default | awk '{print $5; exit}')" -j MASQUERADE
service iptables save
