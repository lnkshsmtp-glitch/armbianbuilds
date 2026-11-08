# File: userpatches/extensions/dkms-headers.sh

function extension_prepare_config__install_headers_gpu_and_dkms() {
    display_alert "Configuring kernel headers, Panthor GPU, Browser HW Accel, and DKMS" "${EXTENSION}" "info"

    export INSTALL_HEADERS="yes"

    if [[ "${BRANCH}" == "vendor" ]]; then
        declare -g DEFAULT_OVERLAYS="panthor-gpu"
    fi

    add_packages_to_image \
        dkms build-essential bc kmod cpio flex bison \
        libncurses-dev libelf-dev libssl-dev dwarves \
        git pkg-config curl gnupg ca-certificates rsync \
        meson ninja-build cmake \
        libdrm-dev libva-dev libudev-dev v4l-utils vainfo \
        libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 \
        mesa-vulkan-drivers mesa-va-drivers mesa-utils vulkan-tools \
        chromium firefox-esr mpv
}

function extension_finish_config__rk3588_fetch_rocket_dvfs_patches() {
    if [[ "${BRANCH}" == "current" ]]; then
        # KERNELPATCHDIR is populated before extension_finish_config; fallback ensures it is never empty
        local rel_dir="${KERNELPATCHDIR:-archive/rockchip64-6.18}"
        local upatch_dir="${USERPATCHES_PATH}/kernel/${rel_dir}"
        local mpatch_dir="${SRC}/patch/kernel/${rel_dir}"
        mkdir -p "${upatch_dir}" "${mpatch_dir}"

        if [[ ! -f "${mpatch_dir}/zz-rocket-dvfs-0011.patch" ]]; then
            display_alert "Installing b4 in container and fetching 11 Rocket NPU DVFS patches into ${rel_dir}" "${EXTENSION}" "info"
            if ! command -v b4 >/dev/null 2>&1; then
                apt-get update >&2
                apt-get install -y b4 git >&2
            fi

            rm -rf /tmp/rocket-dvfs /tmp/rocket-split
            mkdir -p /tmp/rocket-dvfs /tmp/rocket-split

            b4 am --no-cover -o /tmp/rocket-dvfs -n series.mbx 20260922080114.44662-1-royalnet026@gmail.com >&2
            git mailsplit -o/tmp/rocket-split /tmp/rocket-dvfs/series.mbx >&2

            for f in /tmp/rocket-split/[0-9][0-9][0-9][0-9]; do
                local num
                num=$(basename "$f")
                cp -f "$f" "${upatch_dir}/zz-rocket-dvfs-${num}.patch"
                mv "$f" "${mpatch_dir}/zz-rocket-dvfs-${num}.patch"
            done
            rm -rf /tmp/rocket-dvfs /tmp/rocket-split
        fi

        local patch_count
        patch_count=$(find "${mpatch_dir}" -maxdepth 1 -name "zz-rocket-dvfs-*.patch" 2>/dev/null | wc -l)
        display_alert "Verified ${patch_count} Rocket NPU DVFS patches in ${mpatch_dir}" "${EXTENSION}" "info"
        if [[ "${patch_count}" -lt 11 ]]; then
            exit_with_error "Expected 11 zz-rocket-dvfs patches in ${mpatch_dir}, found ${patch_count}"
        fi
    fi
}

function custom_kernel_config__rk3588_gpu_vpu_npu() {
    if [[ "${BRANCH}" == "current" ]]; then
        display_alert "Enabling Panthor GPU, V4L2 Stateless VPU, and Rocket NPU DVFS configs" "${EXTENSION}" "info"
        opts_y+=(
            "CONFIG_DRM_ACCEL"
            "CONFIG_PM_DEVFREQ"
            "CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND"
            "CONFIG_DEVFREQ_GOV_PERFORMANCE"
            "CONFIG_DEVFREQ_GOV_POWERSAVE"
            "CONFIG_DEVFREQ_GOV_USERSPACE"
            "CONFIG_DEVFREQ_THERMAL"
            "CONFIG_V4L2_MEM2MEM_DEV"
            "CONFIG_MEDIA_CONTROLLER"
            "CONFIG_MEDIA_CONTROLLER_REQUEST_API"
        )
        opts_m+=(
            "CONFIG_DRM_PANTHOR"
            "CONFIG_DRM_ACCEL_ROCKET"
            "CONFIG_VIDEO_HANTRO"
            "CONFIG_VIDEO_ROCKCHIP_VDEC"
        )
    fi
}

function post_install_kernel_debs__verify_dkms_build_symlink() {
    display_alert "Verifying kernel headers build symlink for DKMS" "${EXTENSION}" "info"
    chroot_sdcard "dpkg -l | grep -E 'linux-headers|dkms' || true"
}

function pre_umount_final_image__configure_rk3588_rootfs_and_env() {
    display_alert "Writing udev rules, browser flags, and /boot/armbianEnv.txt to ${SDCARD}" "${EXTENSION}" "info"

    mkdir -p "${SDCARD}/etc/udev/rules.d"
    cat << 'EOF' > "${SDCARD}/etc/udev/rules.d/61-mutter-panthor.rules"
SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="panthor", TAG+="mutter-device-preferred-primary"
EOF

    cat << 'EOF' > "${SDCARD}/etc/udev/rules.d/65-apex.rules"
SUBSYSTEM=="apex", MODE="0660", GROUP="apex"
EOF

    cat << 'EOF' > "${SDCARD}/etc/udev/rules.d/99-rk3588-vpu-npu.rules"
KERNEL=="mpp_service", MODE="0660", GROUP="video"
KERNEL=="rga", MODE="0660", GROUP="video"
KERNEL=="system", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
KERNEL=="system-uncached", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
KERNEL=="system-uncached-dma32", SUBSYSTEM=="dma_heap", MODE="0660", GROUP="video"
SUBSYSTEM=="video4linux", MODE="0660", GROUP="video"
SUBSYSTEM=="media", MODE="0660", GROUP="video"
SUBSYSTEM=="accel", MODE="0660", GROUP="render"
EOF

    mkdir -p "${SDCARD}/etc/chromium.d" "${SDCARD}/etc/firefox-esr" "${SDCARD}/etc/environment.d"
    cat << 'EOF' > "${SDCARD}/etc/chromium.d/50-rk3588-hwaccel"
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform-hint=auto --enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiVideoDecoder,VaapiIgnoreDriverChecks,CanvasOopRasterization"
EOF

    cat << 'EOF' > "${SDCARD}/etc/firefox-esr/syspref.js"
pref("gfx.webrender.all", true);
pref("layers.acceleration.force-enabled", true);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("widget.dmabuf.force-enabled", true);
EOF

    for env_file in "${SDCARD}/boot/armbianEnv.txt" "${MOUNT}/boot/armbianEnv.txt"; do
        if [[ -f "${env_file}" ]]; then
            display_alert "Updating ${env_file} with cma=1G and GPU overlays" "${EXTENSION}" "info"
            if grep -q "^extraargs=" "${env_file}"; then
                grep -q "cma=" "${env_file}" || sed -i 's/^extraargs=\(.*\)/extraargs=\1 cma=1G/' "${env_file}"
            else
                echo "extraargs=cma=1G" >> "${env_file}"
            fi

            if [[ "${BRANCH}" == "vendor" ]]; then
                grep -q "^overlay_prefix=" "${env_file}" || echo "overlay_prefix=rockchip-rk3588" >> "${env_file}"
                if grep -q "^overlays=" "${env_file}"; then
                    grep -q "panthor-gpu" "${env_file}" || sed -i 's/^overlays=\(.*\)/overlays=\1 panthor-gpu/' "${env_file}"
                else
                    echo "overlays=panthor-gpu" >> "${env_file}"
                fi
            fi
        fi
    done
}
