#!/bin/bash
# File: userpatches/customize-image.sh

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

set -e

echo "=== [1/7] Detecting target Armbian kernel version ==="
TARGET_KERNEL=$(ls -1 /lib/modules | head -n 1)
if [ -z "${TARGET_KERNEL}" ] || [ ! -d "/lib/modules/${TARGET_KERNEL}/build" ]; then
    echo "ERROR: Target kernel headers not found in /lib/modules/${TARGET_KERNEL}/build"
    exit 1
fi
echo "Building against Target Kernel: ${TARGET_KERNEL}"

echo "=== [2/7] Compiling Google Coral TPU (gasket/apex) DKMS drivers ==="
rm -rf /tmp/gasket-driver /usr/src/gasket-1.0
git clone --depth 1 https://github.com/feranick/gasket-driver.git /tmp/gasket-driver
mkdir -p /usr/src/gasket-1.0
cp -r /tmp/gasket-driver/src/* /usr/src/gasket-1.0/

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

dkms add -m gasket -v 1.0
dkms build -m gasket -v 1.0 -k "${TARGET_KERNEL}"
dkms install -m gasket -v 1.0 -k "${TARGET_KERNEL}"
depmod -a "${TARGET_KERNEL}"

groupadd -f apex
cat << 'EOF' > /etc/udev/rules.d/65-apex.rules
SUBSYSTEM=="apex", MODE="0660", GROUP="apex"
EOF

cat << 'EOF' > /etc/modules-load.d/coral-tpu.conf
gasket
apex
EOF

echo "=== [3/7] Installing Coral Edge TPU runtime (Trixie arm64) ==="
rm -f /etc/apt/sources.list.d/coral-edgetpu.list /etc/apt/keyrings/coral-edgetpu.gpg
apt-get update
apt-get install -y libusb-1.0-0 libgcc-s1

EDGETPU_DEB_URL="https://github.com/feranick/libedgetpu/releases/download/16.0TF2.19.1-1/libedgetpu1-std_16.0tf2.19.1-1.trixie_arm64.deb"
curl -fL "${EDGETPU_DEB_URL}" -o /tmp/libedgetpu1-std.deb

rm -rf /tmp/edgetpu-pkg
dpkg-deb -R /tmp/libedgetpu1-std.deb /tmp/edgetpu-pkg
sed -i 's/libgcc1/libgcc-s1/g' /tmp/edgetpu-pkg/DEBIAN/control
dpkg-deb -b /tmp/edgetpu-pkg /tmp/libedgetpu1-std-trixie.deb
apt-get install -y /tmp/libedgetpu1-std-trixie.deb
ldconfig

echo "=== [4/7] Upgrading Mesa from trixie-backports & installing Mali-G610 CSF firmware ==="
cat << 'EOF' > /etc/apt/sources.list.d/trixie-backports.list
deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware
EOF

apt-get update
# Upgrade Mesa stack from trixie-backports if newer versions exist for Panthor/PanVK 1.4
apt-get install -y -t trixie-backports \
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 \
    mesa-vulkan-drivers mesa-va-drivers || true

# Ensure Mali-G610 CSF firmware is present before initramfs generation
mkdir -p /lib/firmware/arm/mali/arch10.8
if [ ! -f /lib/firmware/arm/mali/arch10.8/mali_csffw.bin ]; then
    curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin" \
        -o /lib/firmware/arm/mali/arch10.8/mali_csffw.bin
fi
cp /lib/firmware/arm/mali/arch10.8/mali_csffw.bin /lib/firmware/mali_csffw.bin

echo "=== [5/7] Configuring GNOME Mutter GPU rules, VPU permissions, and Boot Env ==="
# Force GNOME Mutter to select panthor as the primary 3D GPU
cat << 'EOF' > /etc/udev/rules.d/61-mutter-panthor.rules
SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="panthor", TAG+="mutter-device-preferred-primary"
EOF

# Grant video/render groups access to V4L2 stateless, RKMPP, RGA, DMA-Heap, and NPU nodes
cat << 'EOF' > /etc/udev/rules.d/99-rk3588-vpu-npu.rules
KERNEL=="mpp_service", MODE="0660", GROUP="video"
KERNEL=="rga", MODE="0660", GROUP="video"
KERNEL=="system", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
KERNEL=="system-uncached", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
KERNEL=="system-uncached-dma32", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
SUBSYSTEM=="video4linux", MODE="0660", GROUP="video"
SUBSYSTEM=="media", MODE="0660", GROUP="video"
SUBSYSTEM=="accel", MODE="0660", GROUP="render"
EOF

# Configure /boot/armbianEnv.txt for 1GB CMA (prevents 4K V4L2 buffer exhaustion) and vendor panthor overlay
if [ -f /boot/armbianEnv.txt ]; then
    grep -q "^extraargs=" /boot/armbianEnv.txt \
        && sed -i 's/^extraargs=\(.*\)/extraargs=\1 cma=1G/' /boot/armbianEnv.txt \
        || echo "extraargs=cma=1G" >> /boot/armbianEnv.txt

    if echo "${TARGET_KERNEL}" | grep -q "vendor"; then
        grep -q "^overlay_prefix=" /boot/armbianEnv.txt || echo "overlay_prefix=rockchip-rk3588" >> /boot/armbianEnv.txt
        if grep -q "^overlays=" /boot/armbianEnv.txt; then
            grep -q "panthor-gpu" /boot/armbianEnv.txt || sed -i 's/^overlays=\(.*\)/overlays=\1 panthor-gpu/' /boot/armbianEnv.txt
        else
            echo "overlays=panthor-gpu" >> /boot/armbianEnv.txt
        fi
    fi
fi

echo "=== [6/7] Configuring Chromium & Firefox Hardware Video Acceleration ==="
# 1. Chromium flags (sourced automatically by Debian's /usr/bin/chromium launcher)
mkdir -p /etc/chromium.d
cat << 'EOF' > /etc/chromium.d/50-rk3588-hwaccel
# Enable Wayland, Mali-G610 GPU rasterization, and V4L2 Zero-Copy HW video decode
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS} \
  --ozone-platform-hint=auto \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  --ignore-gpu-blocklist \
  --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiVideoDecoder,VaapiIgnoreDriverChecks,CanvasOopRasterization"
EOF

# 2. Build dongioia/libva-v4l2-request so Firefox VA-API talks to RK3588 V4L2 stateless decoders
rm -rf /tmp/libva-v4l2-request
if git clone --depth 1 https://github.com/dongioia/libva-v4l2-request.git /tmp/libva-v4l2-request; then
    cd /tmp/libva-v4l2-request
    meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu -Dwith_x11=yes -Dwith_wayland=yes
    ninja -C build
    ninja -C build install
    cd /
fi

# 3. Configure Firefox ESR system-wide preferences for Wayland WebRender + VA-API
mkdir -p /etc/firefox-esr
cat << 'EOF' > /etc/firefox-esr/syspref.js
// Force hardware WebRender on Mali-G610 (Panthor) and enable VA-API video decoding
pref("gfx.webrender.all", true);
pref("layers.acceleration.force-enabled", true);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("widget.dmabuf.force-enabled", true);
EOF

# Set environment variables for Wayland and VA-API in GNOME sessions
mkdir -p /etc/environment.d
cat << 'EOF' > /etc/environment.d/90-rk3588-gpu.conf
MOZ_ENABLE_WAYLAND=1
LIBVA_DRIVER_NAME=v4l2_request
EOF

echo "=== [7/7] Updating initramfs with Panthor & Mali CSF firmware ==="
grep -qxF "panthor" /etc/initramfs-tools/modules || echo "panthor" >> /etc/initramfs-tools/modules
update-initramfs -u -k "${TARGET_KERNEL}"

rm -rf /tmp/gasket-driver /tmp/libedgetpu1-std.deb /tmp/libedgetpu1-std-trixie.deb /tmp/edgetpu-pkg /tmp/libva-v4l2-request
echo "=== [NanoPC-T6 Build Customization] Complete ==="
