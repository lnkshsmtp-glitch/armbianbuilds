#!/bin/bash
# File: userpatches/customize-image.sh

set -e

echo "=== [1/5] Detecting target Armbian kernel version ==="
TARGET_KERNEL=$(ls -1 /lib/modules | head -n 1)
if [ -z "${TARGET_KERNEL}" ] || [ ! -d "/lib/modules/${TARGET_KERNEL}/build" ]; then
    echo "ERROR: Target kernel headers not found in /lib/modules/${TARGET_KERNEL}/build"
    exit 1
fi
echo "Building against Target Kernel: ${TARGET_KERNEL}"

echo "=== [2/5] Cloning and patching gasket-driver source ==="
rm -rf /tmp/gasket-driver /usr/src/gasket-1.0
git clone --depth 1 https://github.com/feranick/gasket-driver.git /tmp/gasket-driver
mkdir -p /usr/src/gasket-1.0
cp -r /tmp/gasket-driver/src/* /usr/src/gasket-1.0/

# Ensure compatibility across both 6.1 BSP and 6.12-6.18+ Mainline kernels
sed -i 's/no_llseek/noop_llseek/g' /usr/src/gasket-1.0/gasket_core.c

if grep -q 'MODULE_IMPORT_NS' /usr/src/gasket-1.0/gasket_page_table.c; then
    sed -i '/MODULE_IMPORT_NS/d' /usr/src/gasket-1.0/gasket_page_table.c
    cat << 'EOF' >> /usr/src/gasket-1.0/gasket_page_table.c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("DMA_BUF");
#else
MODULE_IMPORT_NS(DMA_BUF);
#endif
EOF
fi

cat << 'EOF' > /usr/src/gasket-1.0/dkms.conf
PACKAGE_NAME="gasket"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="gasket"
BUILT_MODULE_NAME[1]="apex"
DEST_MODULE_LOCATION[0]="/kernel/drivers/char"
DEST_MODULE_LOCATION[1]="/kernel/drivers/char"
AUTOINSTALL="yes"
EOF

echo "=== [3/5] Compiling and installing DKMS modules ==="
dkms add -m gasket -v 1.0
dkms build -m gasket -v 1.0 -k "${TARGET_KERNEL}"
dkms install -m gasket -v 1.0 -k "${TARGET_KERNEL}"
depmod -a "${TARGET_KERNEL}"

echo "=== [4/5] Setting up udev rules and module autoloading ==="
groupadd -f apex
cat << 'EOF' > /etc/udev/rules.d/65-apex.rules
SUBSYSTEM=="apex", MODE="0660", GROUP="apex"
EOF

cat << 'EOF' > /etc/modules-load.d/coral-tpu.conf
gasket
apex
EOF

echo "=== [5/5] Installing Edge TPU userspace runtime (libedgetpu1-std) ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/coral-edgetpu.gpg
echo "deb [signed-by=/etc/apt/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" \
    > /etc/apt/sources.list.d/coral-edgetpu.list

apt-get update
apt-get install -y libedgetpu1-std
rm -rf /tmp/gasket-driver
