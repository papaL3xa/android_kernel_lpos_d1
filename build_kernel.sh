#!/bin/bash

export WDIR="$(pwd)"
export PATH=toolchain/bin:~/proton-13/bin:$PATH
export VBMETA="${WDIR}/binaries/addons/vbmeta.img"
export KBUILD_BUILD_USER="@ravindu644"
export LLVM=1
export ARCH=arm64
export PLATFORM_VERSION=12
export ANDROID_MAJOR_VERSION=s
export REPACKER="${WDIR}/binaries/AIK/repackimg.sh"
export INSTALLER="${WDIR}/binaries/Installer"
export ARGS="
CC=clang
LD=ld.lld
ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
CROSS_COMPILE_ARM32=arm-linux-gnueabi-
CLANG_TRIPLE=aarch64-linux-gnu-
AR=llvm-ar
NM=llvm-nm
AS=llvm-as
READELF=llvm-readelf
OBJCOPY=llvm-objcopy
OBJDUMP=llvm-objdump
OBJSIZE=llvm-size
STRIP=llvm-strip
LLVM_AR=llvm-ar
LLVM_DIS=llvm-dis
LLVM_NM=llvm-nm
LLVM=1
"

#device specific variables
export DEVICE="N10"
export SOC="exynos9825"
export DEFCONFIG=exynos9820-d1_defconfig

# Fix for CI environment
export TERM=xterm

# Function to aggressively fix Kconfig issues
fix_kconfig_aggressive() {
    echo "[+] Aggressively fixing Kconfig issues..."
    
    # Create missing kperfmon directory and Kconfig
    mkdir -p drivers/kperfmon
    cat > drivers/kperfmon/Kconfig << 'EOF'
# SPDX-License-Identifier: GPL-2.0
config KPERFMON
    bool "Kernel Performance Monitor"
    default n
    help
      This is a stub for the missing kperfmon driver.
EOF

    # Fix drivers/Kconfig - remove problematic lines and fix formatting
    if [ -f "drivers/Kconfig" ]; then
        # Backup original
        cp drivers/Kconfig drivers/Kconfig.backup
        
        # Remove problematic kperfmon line completely
        grep -v 'kperfmon' drivers/Kconfig.backup > drivers/Kconfig.tmp
        
        # Remove special characters and fix line endings
        sed -i 's/\r//g' drivers/Kconfig.tmp
        sed -i '/^[[:space:]]*$/d' drivers/Kconfig.tmp
        
        # Remove unsupported characters
        tr -cd '\11\12\15\40-\176' < drivers/Kconfig.tmp > drivers/Kconfig
        
        rm -f drivers/Kconfig.tmp drivers/Kconfig.backup
        echo "[+] Fixed drivers/Kconfig"
    fi

    # Fix other problematic Kconfig files
    for kconfig in drivers/leds/Kconfig drivers/redriver/Kconfig drivers/samsung/misc/Kconfig; do
        if [ -f "$kconfig" ]; then
            # Remove special characters and fix formatting
            sed -i 's/\r//g' "$kconfig"
            sed -i '/^[[:space:]]*$/d' "$kconfig"
            tr -cd '\11\12\15\40-\176' < "$kconfig" > "${kconfig}.tmp"
            mv "${kconfig}.tmp" "$kconfig"
            echo "[+] Fixed $kconfig"
        fi
    done
}

# submodule
echo "[+] Initializing submodules..."
git submodule init && git submodule update --remote --depth=1

# Check if KSU submodule exists and initialize if needed
if [ ! -d "drivers/kernelsu" ]; then
    echo "[!] KernelSU submodule not found, initializing..."
    git submodule add https://github.com/tiann/KernelSU.git drivers/kernelsu || echo "[i] KernelSU already added"
    git submodule update --init --remote drivers/kernelsu
fi

# Apply aggressive Kconfig fixes
fix_kconfig_aggressive

#symlinking python3
if [ ! -f "$HOME/python" ]; then
    ln -s /usr/bin/python3 "$HOME/python"
fi 

#output dir
if [ ! -d "${WDIR}/out" ]; then
    mkdir -p "${WDIR}/out"
fi

#dev
if [ -z "$LPOS_KERNEL_VERSION" ]; then
    export LPOS_KERNEL_VERSION="dev"
fi

#setting up localversion
echo -e "CONFIG_LOCALVERSION_AUTO=n\nCONFIG_LOCALVERSION=\"-LPoS-${LPOS_KERNEL_VERSION}\"\n" > "${WDIR}/arch/arm64/configs/version.config"

#dt
dtb() {
    ${WDIR}/binaries/mkdtimg cfg_create "${INSTALLER}/dt.img" "${WDIR}/binaries/${SOC}.cfg" -d "${WDIR}/arch/arm64/boot/dts/exynos"
}

# Function to apply configs without interactive menu
apply_configs() {
    echo "[+] Applying configuration files..."
    
    # Apply each config file directly to .config
    for config in "$@"; do
        if [ -f "arch/arm64/configs/${config}.config" ]; then
            echo "[+] Applying ${config}.config"
            # Append config to .config
            cat "arch/arm64/configs/${config}.config" >> .config
        elif [ -f "${config}.config" ]; then
            echo "[+] Applying ${config}.config"
            cat "${config}.config" >> .config
        fi
    done
    
    # Finalize configuration
    yes "" | make ${ARGS} oldconfig
}

# Clean build function
clean_build() {
    echo "[+] Performing clean build..."
    make ${ARGS} clean && make ${ARGS} mrproper
    rm -f .config .config.old
}

# Function to build kernel with given configs
build_kernel() {
    local selinux_status=$1
    local ksu_flag=$2
    local extra_configs=$3
    
    if [ "$ksu_flag" = "yes" ]; then
        export FILENAME="KSU-LPoS-${DEVICE}-${LPOS_KERNEL_VERSION}-twrp-${selinux_status}"
        export CONFIGS="version ksu ${extra_configs}"
    else
        export FILENAME="LPoS-${DEVICE}-${LPOS_KERNEL_VERSION}-twrp-${selinux_status}"
        export CONFIGS="version ${extra_configs}"
    fi
    
    echo "[+] Building ${FILENAME}"
    
    clean_build
    
    # Generate defconfig
    if ! make ${ARGS} "$DEFCONFIG"; then
        echo "[!] Failed to generate defconfig, trying alternative approach..."
        # Try to use savedefconfig if available
        if [ -f "arch/arm64/configs/$DEFCONFIG" ]; then
            cp "arch/arm64/configs/$DEFCONFIG" .config
        else
            echo "[!] Cannot proceed without defconfig"
            return 1
        fi
    fi
    
    # Apply additional configs
    apply_configs $CONFIGS
    
    # Build kernel
    if make ${ARGS} -j$(nproc --all); then
        dtb
        repack
        return 0
    else
        echo "[!] Build failed for ${FILENAME}"
        return 1
    fi
}

#building non-ksu kernel
lpos(){
    echo "[+] Building LPoS kernel variants..."
    
    # Enforcing
    if build_kernel "enforcing" "no" ""; then
        echo "[+] LPoS enforcing build successful"
    else
        echo "[!] LPoS enforcing build failed"
    fi
    
    # Permissive  
    if build_kernel "permissive" "no" "permissive"; then
        echo "[+] LPoS permissive build successful"
    else
        echo "[!] LPoS permissive build failed"
    fi
}

#building ksu kernel
ksu(){
    #setting up localversion + ksu
    echo -e "CONFIG_LOCALVERSION_AUTO=n\nCONFIG_LOCALVERSION=\"-LPoS-${LPOS_KERNEL_VERSION}-KSU\"\n" > "${WDIR}/arch/arm64/configs/version.config"    
    
    # Ensure KSU directory exists
    if [ ! -d "drivers/kernelsu" ]; then
        echo "[!] ERROR: KernelSU directory not found!"
        exit 1
    fi
    
    echo "[+] Building KernelSU kernel variants..."
    
    # KSU Enforcing
    if build_kernel "enforcing" "yes" ""; then
        echo "[+] KSU enforcing build successful"
    else
        echo "[!] KSU enforcing build failed"
    fi
    
    # KSU Permissive
    if build_kernel "permissive" "yes" "permissive"; then
        echo "[+] KSU permissive build successful"
    else
        echo "[!] KSU permissive build failed"
    fi
}

deep_clean(){
    cd "${WDIR}"
    echo -e "[i] Cleaning Up...\n\n"
    make ${ARGS} clean && make ${ARGS} mrproper
    rm -f .config .config.old .config.tmp
}

#packing
repack() {
    echo -e "\n\n[+] Repacking boot.img..."
    if [ -f "${WDIR}/arch/arm64/boot/Image" ]; then
        mv "${WDIR}/arch/arm64/boot/Image" "${WDIR}/binaries/AIK/split_img/boot.img-kernel"
    else
        echo "[!] Error: Kernel Image not found at ${WDIR}/arch/arm64/boot/Image!"
        ls -la "${WDIR}/arch/arm64/boot/" || echo "Cannot list boot directory"
        exit 1
    fi
    
    cd "${WDIR}/binaries/AIK/ramdisk"
    if [ ! -d "debug_ramdisk" ]; then
        mkdir -p debug_ramdisk dev metadata mnt proc second_stage_resources sys
    fi
    cd "${WDIR}"
    
    # Check if repacker exists
    if [ ! -f "${REPACKER}" ]; then
        echo "[!] Error: Repacker script not found at ${REPACKER}"
        exit 1
    fi
    
    if sudo bash "${REPACKER}"; then
        echo -e "\n\n[+] Repacking Done..!"
        if [ -f "${WDIR}/binaries/AIK/image-new.img" ]; then
            mv -f "${WDIR}/binaries/AIK/image-new.img" "${INSTALLER}/boot.img"
        else
            echo "[!] Error: Repacked image not found!"
            exit 1
        fi
    else
        echo "[!] Error: Repacking failed!"
        exit 1
    fi
    
    echo -e "\n\n[i] Creating a Flashable zip..!"

    cd "${WDIR}/out"
    cp "${VBMETA}" "${INSTALLER}"
    cd "${INSTALLER}" 
    sudo chmod +755 -R -f * 
    rm -rf *.zip
    
    if zip -r -9 "${FILENAME}.zip" *; then
        rm -rf *.img
        mv "${FILENAME}.zip" "${WDIR}/out" 
        cd "${WDIR}"
        echo -e "\n\n[i] Compilation Done..🌛"
    else
        echo "[!] Error: Failed to create zip file!"
        exit 1
    fi
}

USER_INPUT=$1

case "$USER_INPUT" in
    "-c")
        echo -e "\n\n[i] Performing a clean build...\n\n"
        lpos ;;
    "-k")
        echo -e "\n\n[i] Building KernelSU...\n\n"
        ksu;;
    "-x") 
        echo -e "\n\n[i] Cleaning the source...\n\n"
        deep_clean ;;
    *)
        echo -e "\n[x] Wrong Input..! \n\n [i] Usage : \n\n To build LPoS : build_kernel.sh -c\n To Clean the source : build_kernel.sh -x\n To Build KernelSU : build_kernel.sh -k"
        ;;
esac