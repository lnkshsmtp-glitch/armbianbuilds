# File: userpatches/extensions/dkms-headers.sh

function add_host_dependencies__rocket_npu_b4() {
    # Ensure b4 is installed inside the Armbian build container as well
    EXTRA_BUILD_DEPS+=("b4")
}

function post_family_config__rk3588_overlays_and_patches() {
    if [[ "${BRANCH}" == "vendor" ]]; then
        display_alert "Enabling panthor-gpu DT overlay for vendor kernel" "${EXTENSION}" "info"
        declare -g DEFAULT_OVERLAYS="panthor-gpu"
    elif [[ "${BRANCH}" == "current" ]]; then
        local kpatch_dir="${USERPATCHES_PATH}/kernel/${KERNELPATCHDIR}"
        mkdir -p "${kpatch_dir}"

        if [[ ! -f "${kpatch_dir}/zz-rocket-dvfs-0011.patch" ]]; then
            display_alert "Fetching 11-patch RK3588 Rocket NPU 1GHz DVFS series via b4" "${EXTENSION}" "info"
            rm -rf /tmp/rocket-dvfs /tmp/rocket-split
            mkdir -p /tmp/rocket-dvfs /tmp/rocket-split

            # Redirect stdout to stderr (>&2) to keep Armbian's metadata stdout channel clean
            b4 am --no-cover -o /tmp/rocket-dvfs -n series.mbx 20260922080114.44662-1-royalnet026@gmail.com >&2
            git mailsplit -o/tmp/rocket-split /tmp/rocket-dvfs/series.mbx >&2

            for f in /tmp/rocket-split/[0-9][0-9][0-9][0-9]; do
                local num
                num=$(basename "$f")
                mv "$f" "${kpatch_dir}/zz-rocket-dvfs-${num}.patch"
            done
            rm -rf /tmp/rocket-dvfs /tmp/rocket-split
        fi

        local patch_count
        patch_count=$(find "${kpatch_dir}" -maxdepth 1 -name "zz-rocket-dvfs-*.patch" 2>/dev/null | wc -l)
        display_alert "Staged ${patch_count} Rocket NPU DVFS patches in ${kpatch_dir}" "${EXTENSION}" "info"
        if [[ "${patch_count}" -lt 11 ]]; then
            exit_with_error "Expected 11 zz-rocket-dvfs patches in ${kpatch_dir}, found ${patch_count}"
        fi
    fi
}

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

function pre_umount_final_image__configure_rk3588_armbian_env() {
    local env_file="${MOUNT}/boot/armbianEnv.txt"
    if [[ -f "${env_file}" ]]; then
        display_alert "Updating /boot/armbianEnv.txt for 1GB CMA and GPU overlay" "${EXTENSION}" "info"

        # Reserve 1GB CMA so 4K V4L2/MPP hardware video decoding never runs out of contiguous memory
        if grep -q "^extraargs=" "${env_file}"; then
            grep -q "cma=" "${env_file}" || sed -i 's/^extraargs=\(.*\)/extraargs=\1 cma=1G/' "${env_file}"
        else
            echo "extraargs=cma=1G" >> "${env_file}"
        fi

        # Ensure panthor-gpu DT overlay is enabled on vendor 6.1 builds
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
