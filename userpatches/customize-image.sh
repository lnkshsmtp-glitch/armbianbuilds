#!/bin/bash

# This script runs natively inside the image chroot right before it wraps up.
# Armbian updates its internal compilation repo cache here.

echo "=========================================="
echo "Injecting custom kernel headers package..."
echo "=========================================="

# Update the local repo metadata and pull the matching 6.18.60 headers
apt-get update
apt-get install -y linux-headers-current-rockchip64
