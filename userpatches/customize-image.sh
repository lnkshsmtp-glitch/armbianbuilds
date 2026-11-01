#!/bin/bash
# Armbian customization script
echo "=========================================="
echo "Injecting custom kernel headers package..."
echo "=========================================="

apt-get update
apt-get install -y linux-headers-current-rockchip64
