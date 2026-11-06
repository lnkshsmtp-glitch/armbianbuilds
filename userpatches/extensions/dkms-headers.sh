# File: userpatches/extensions/dkms-headers.sh

function extension_prepare_config__install_headers_gpu_and_dkms() {
    display_alert "Configuring kernel headers, Panthor GPU, Browser HW Accel, and DKMS" "${EXTENSION}" "info"

    # 1. Install matching linux-headers package into the image
    export INSTALL_HEADERS="yes"

    # 2. On vendor (6.1) kernel, enable the panthor-gpu DT overlay by default
    if [[ "${BRANCH}" == "vendor" ]]; then
        export DEFAULT_OVERLAYS="panthor-gpu"
    fi

    # 3. Include DKMS, GPU/Vulkan/VA-API runtimes, browsers, and V4L2 build tools
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
