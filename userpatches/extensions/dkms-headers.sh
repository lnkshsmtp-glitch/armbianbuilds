# File: userpatches/extensions/dkms-headers.sh

function extension_prepare_config__install_headers_gpu_and_dkms() {
    display_alert "Configuring kernel headers, Panthor GPU, Browser HW Accel, and DKMS" "${EXTENSION}" "info"

    export INSTALL_HEADERS="yes"

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

function post_family_config__enable_vendor_panthor_overlay() {
    if [[ "${BRANCH}" == "vendor" ]]; then
        display_alert "Enabling panthor-gpu DT overlay for vendor kernel" "${EXTENSION}" "info"
        declare -g DEFAULT_OVERLAYS="panthor-gpu"
    fi
}

function custom_kernel_config__rk3588_gpu_vpu_npu() {
    if [[ "${BRANCH}" == "current" ]]; then
        display_alert "Ensuring Panthor GPU, V4L2 Stateless VPU, and Rocket NPU DVFS configs" "${EXTENSION}" "info"
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

function pre_umount_final_image__configure_rk3588_armbian_env() {
    local env_file="${MOUNT}/boot/armbianEnv.txt"
    if [[ -f "${env_file}" ]]; then
        display_alert "Updating /boot/armbianEnv.txt for 1GB CMA and GPU overlay" "${EXTENSION}" "info"

        # Reserve 1GB CMA so 4K V4L2/MPP hardware video decoding never runs out of contiguous buffers
        if grep -q "^extraargs=" "${env_file}"; then
            grep -q "cma=" "${env_file}" || sed -i 's/^extraargs=\(.*\)/extraargs=\1 cma=1G/' "${env_file}"
        else
            echo "extraargs=cma=1G" >> "${env_file}"
        fi

        # Ensure panthor-gpu overlay is active on vendor 6.1 builds
        if [[ "${BRANCH}" == "vendor" ]]; then
            grep -q "^overlay_prefix=" "${env_file}" || echo "overlay_prefix=rockchip-rk3588" >> "${env_file}"
            if grep -q "^overlays=" "${env_file}"; then
                grep -q "panthor-gpu" "${env_file}" || sed -i 's/^overlays=\(.*\)/overlays=\1 panthor-gpu/' "${env_file}"
            else
                echo "overlays=panthor-gpu" >> "${env_file}"
            fi
        fi
    fi
}
