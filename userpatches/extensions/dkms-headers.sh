# File: userpatches/extensions/dkms-headers.sh

function extension_prepare_config__install_headers_and_dkms() {
    display_alert "Enabling kernel headers and DKMS dependencies" "${EXTENSION}" "info"

    export INSTALL_HEADERS="yes"

    add_packages_to_image \
        dkms build-essential bc kmod cpio flex bison \
        libncurses-dev libelf-dev libssl-dev dwarves \
        git pkg-config curl gnupg ca-certificates rsync
}

function post_install_kernel_debs__verify_dkms_build_symlink() {
    display_alert "Verifying kernel headers build symlink for DKMS" "${EXTENSION}" "info"
    chroot_sdcard "dpkg -l | grep -E 'linux-headers|dkms' || true"
}
