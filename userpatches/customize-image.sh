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

echo "=== [4/7] Upgrading Mesa from trixie-backports & checking Mali-G610 CSF firmware ==="
rm -f /etc/apt/sources.list.d/trixie-backports.list
if ! grep -rq "trixie-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    cat << 'EOF' > /etc/apt/sources.list.d/trixie-backports.list
deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware
EOF
fi

apt-get update
apt-get install -y -t trixie-backports \
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 \
    mesa-vulkan-drivers mesa-va-drivers || true

mkdir -p /lib/firmware/arm/mali/arch10.8
if [ ! -e /lib/firmware/arm/mali/arch10.8/mali_csffw.bin ]; then
    curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin" \
        -o /lib/firmware/arm/mali/arch10.8/mali_csffw.bin
fi
if [ ! -e /lib/firmware/mali_csffw.bin ]; then
    cp -L /lib/firmware/arm/mali/arch10.8/mali_csffw.bin /lib/firmware/mali_csffw.bin || true
fi

echo "=== [5/7] Configuring GNOME Mutter GPU rules and VPU permissions ==="
cat << 'EOF' > /etc/udev/rules.d/61-mutter-panthor.rules
SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="panthor", TAG+="mutter-device-preferred-primary"
EOF

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

echo "=== [6/7] Configuring Chromium & Firefox Hardware Video Acceleration ==="
mkdir -p /etc/chromium.d
cat << 'EOF' > /etc/chromium.d/50-rk3588-hwaccel
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform-hint=auto --enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiVideoDecoder,VaapiIgnoreDriverChecks,CanvasOopRasterization"
EOF

rm -rf /tmp/libva-v4l2-request
(
    git clone --depth 1 https://github.com/dongioia/libva-v4l2-request.git /tmp/libva-v4l2-request && \
    cd /tmp/libva-v4l2-request && \
    meson setup build --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu/dri && \
    ninja -C build && \
    ninja -C build install
) || echo "WARNING: libva-v4l2-request optional build skipped"

mkdir -p /etc/firefox-esr
cat << 'EOF' > /etc/firefox-esr/syspref.js
pref("gfx.webrender.all", true);
pref("layers.acceleration.force-enabled", true);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("widget.dmabuf.force-enabled", true);
EOF

mkdir -p /etc/environment.d
cat << 'EOF' > /etc/environment.d/90-rk3588-gpu.conf
MOZ_ENABLE_WAYLAND=1
EOF

if ! echo "${TARGET_KERNEL}" | grep -q "vendor" && [ -f /usr/lib/aarch64-linux-gnu/dri/v4l2_request_drv_video.so ]; then
    echo "LIBVA_DRIVER_NAME=v4l2_request" >> /etc/environment.d/90-rk3588-gpu.conf
fi

echo "=== [7/7] Updating initramfs and cleaning APT caches ==="
grep -qxF "panthor" /etc/initramfs-tools/modules || echo "panthor" >> /etc/initramfs-tools/modules
update-initramfs -u -k "${TARGET_KERNEL}"

rm -rf /tmp/gasket-driver /tmp/libedgetpu1-std.deb /tmp/libedgetpu1-std-trixie.deb /tmp/edgetpu-pkg /tmp/libva-v4l2-request
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* /var/cache/apt/*.bin || true

echo "=== [NanoPC-T6 Build Customization] Complete ==="
