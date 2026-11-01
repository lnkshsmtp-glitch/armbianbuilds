#!/bin/bash

# This hook executes in the host environment during the build process.
# $DEB_DIR points to the host's compiled packages folder (output/debs/)
# $SDCARD points to the root directory where the image is mounted.

function post_armbian_repo_customize_image() {
    display_alert "Custom Extension" "Injecting matching kernel headers..." "info"

    # Strict filtering: Find only actual files ending in .deb matching our package naming scheme
    local headers_deb=$(find "${DEB_DIR}" -maxdepth 2 -type f -name "linux-headers-${CHOSEN_KERNEL}-${LINUXFAMILY}_*.deb" 2>/dev/null | head -n 1)

    if [ -n "$headers_deb" ] && [ -f "$headers_deb" ]; then
        display_alert "Custom Extension" "Found valid compiled headers: $(basename "$headers_deb")" "info"
        
        # Copy the .deb safely into the mounted image's temporary directory
        cp "$headers_deb" "${SDCARD}/tmp/"

        # Chroot into the image and force-install that specific package file
        chroot "${SDCARD}" /bin/bash -c "dpkg -i /tmp/$(basename "$headers_deb")"
        
        # Clean up the installer package from the image filesystem
        rm "${SDCARD}/tmp/$(basename "$headers_deb")"
    else
        display_alert "Custom Extension" "Could not find a valid matching .deb headers package in ${DEB_DIR}" "error"
        # Optional: List files in the directory to help debug if it fails
        ls -la "${DEB_DIR}"
    fi
}
