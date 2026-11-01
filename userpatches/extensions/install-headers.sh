#!/bin/bash

# This hook executes in the host environment during the build process.
# At this phase, the framework's local package repository is mounted inside the image.

function post_armbian_repo_customize_image() {
    display_alert "Custom Extension" "Force-installing newly compiled kernel headers..." "info"

    # We chroot into the target image, sync the active local repository index, 
    # and explicitly tell apt to install the headers package we just compiled.
    chroot "${SDCARD}" /bin/bash -c "apt-get update && apt-get install -y linux-headers-${CHOSEN_KERNEL}-${LINUXFAMILY}"
    
    if [ $? -eq 0 ]; then
        display_alert "Custom Extension" "Successfully injected kernel headers into the image rootfs!" "info"
    else
        display_alert "Custom Extension" "Failed to install kernel headers via apt." "error"
        exit 2
    fi
}
