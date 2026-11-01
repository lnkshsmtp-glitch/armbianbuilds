#!/bin/bash

# This hook executes in the host environment during the build process.
# $DEB_DIR points to the host's compiled packages folder (output/debs/)
# $SDCARD points to the root directory where the image is mounted.

function post_armbian_repo_customize_image() {
    display_alert "Custom Extension" "Injecting matching kernel headers..." "info"

    # 1. Locate the exact headers package we just compiled for this specific build
    # $CHOSEN_KERNEL will be "current", $LINUXFAMILY will be "rockchip64"
    local headers_deb=$(ls -1 ${DEB_DIR}/linux-headers-${CHOSEN_KERNEL}-${LINUXFAMILY}_*.deb 2>/dev/null | head -n 1)

    if [ -f "$headers_deb" ]; then
        display_alert "Custom Extension" "Found compiled headers: $(basename $headers_deb)" "info"
        
        # 2. Copy the .deb safely into the mounted image's temporary directory
        cp "$headers_deb" "${SDCARD}/tmp/"

        # 3. Chroot into the image and force-install that specific package file
        chroot "${SDCARD}" /bin/bash -c "dpkg -i /tmp/$(basename $headers_deb)"
        
        # 4. Clean up the installer package from the image filesystem
        rm "${SDCARD}/tmp/$(basename $headers_deb)"
    else
        display_alert "Custom Extension" "Could not find matching compiled headers in ${DEB_DIR}" "warning"
    fi
}
