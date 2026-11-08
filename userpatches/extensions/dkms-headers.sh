# File: userpatches/extensions/dkms-headers.sh

function add_host_dependencies__rocket_npu_b4() {
    EXTRA_BUILD_DEPS+=("b4")
}

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
        local rel_dir="archive/${LINUXFAMILY:-rockchip64}-${KERNEL_MAJOR_MINOR:-6.18}"
        local upatch_dir="${USERPATCHES_PATH}/kernel/${rel_dir}"
        local mpatch_dir="${SRC}/patch/kernel/${rel_dir}"
        mkdir -p "${upatch_dir}" "${mpatch_dir}"

        # Clean out any old 0001..0011 patches from patch dirs so patching.py doesn't trip on 6.18.62 backports
        rm -f "${upatch_dir}/"zz-rocket-dvfs-*.patch "${mpatch_dir}/"zz-rocket-dvfs-*.patch

        display_alert "Fetching 11 Rocket NPU 1GHz DVFS patches via b4" "${EXTENSION}" "info"
        if ! command -v b4 >/dev/null 2>&1; then
            apt-get update >&2
            apt-get install -y b4 git >&2
        fi

        rm -rf /tmp/rocket-dvfs /tmp/rocket-split
        mkdir -p /tmp/rocket-dvfs /tmp/rocket-split

        b4 am --no-cover -o /tmp/rocket-dvfs -n series.mbx 20260922080114.44662-1-royalnet026@gmail.com >&2
        git mailsplit -o/tmp/rocket-split /tmp/rocket-dvfs/series.mbx >&2

        # Stage ONLY 0006 (DT binding doc) into Armbian's patch dir to change the Pxxxx cache hash
        # and force a source kernel build without triggering reversed-patch errors in patching.py
        cp -f /tmp/rocket-split/0006 "${upatch_dir}/zz-rocket-dvfs-0006.patch"
        cp -f /tmp/rocket-split/0006 "${mpatch_dir}/zz-rocket-dvfs-0006.patch"
    fi
}

function custom_kernel_config__rk3588_gpu_vpu_npu() {
    if [[ "${BRANCH}" == "current" ]]; then
        # Locate the active kernel source worktree
        local ksrc_dir="${pwd}"
        if [[ ! -d "${ksrc_dir}/drivers/accel/rocket" ]]; then
            local rocket_file
            rocket_file=$(find "${SRC}/cache/sources" -path "*/drivers/accel/rocket/rocket_device.c" 2>/dev/null | head -n 1)
            ksrc_dir="${rocket_file%/drivers/accel/rocket/rocket_device.c}"
        fi

        if [[ -d "${ksrc_dir}/drivers/accel/rocket" ]] && [[ -d /tmp/rocket-split ]]; then
            display_alert "Applying unmerged Rocket NPU 1GHz DVFS patches to ${ksrc_dir}" "${EXTENSION}" "info"
            pushd "${ksrc_dir}" >/dev/null
            for f in /tmp/rocket-split/[0-9][0-9][0-9][0-9]; do
                local num
                num=$(basename "$f")
                if patch -p1 --dry-run -R --force < "$f" >/dev/null 2>&1; then
                    display_alert "Skipping patch ${num} (already merged in upstream 6.18.x)" "${EXTENSION}" "info"
                else
                    display_alert "Applying Rocket NPU DVFS patch ${num}" "${EXTENSION}" "info"
                    patch -p1 --forward --fuzz=3 -r - < "$f" >&2 || true
                fi
            done
            popd >/dev/null

            if ! grep -rq "opp-table-npu" "${ksrc_dir}/arch/arm64/boot/dts/rockchip/"; then
                exit_with_error "opp-table-npu missing from rk3588 device tree after patching!"
            fi
            display_alert "Verified opp-table-npu and rocket devfreq in kernel tree" "${EXTENSION}" "info"
        fi

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
