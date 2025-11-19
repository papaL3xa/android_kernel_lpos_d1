#!/bin/bash

# Enhanced Android Kernel Build Script for LPOS D1
# Enhanced version with better error handling and organization

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
KERNEL_NAME="LPoS"
KERNEL_VERSION="v8.6.2-stable"
DEVICE="Note 10"
BUILD_DIR="${PWD}"
OUT_DIR="${BUILD_DIR}/out"
ARCH="arm64"
PLATFORM_VERSION=12
ANDROID_MAJOR_VERSION=s

# Toolchain and binary paths
export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"
export work_dir="${BUILD_DIR}"
export dt_tool="${work_dir}/binaries"
export repacker="${dt_tool}/AIK/repackimg.sh"
export VBMETA="${dt_tool}/addons/vbmeta.img"

# Build arguments
export ARGS="CC=clang LD=ld.lld ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- AR=llvm-ar NM=llvm-nm AS=llvm-as READELF=llvm-readelf OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size STRIP=llvm-strip LLVM_AR=llvm-ar LLVM_DIS=llvm-dis LLVM_NM=llvm-nm LLVM=1"

# Defconfig
export exynos_defconfig="exynos9820-d1_defconfig"
export config_file="arch/arm64/configs/${exynos_defconfig}"

# Build information
export current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")
export KBUILD_BUILD_USER="@ravindu644"
export LLVM=1

# Function to print colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# Initialize build environment
initialize_build() {
    print_step "Initializing build environment..."
    
    # Create symbolic link for python
    if [ ! -L "$HOME/python" ]; then
        ln -sf /usr/bin/python2.7 "$HOME/python"
        print_info "Created Python symbolic link"
    fi
    
    # Set executable permissions
    if [ -d "$dt_tool" ]; then
        chmod +775 -R "$dt_tool/"
        print_info "Set executable permissions for binaries"
    fi
    
    # Create output directory
    mkdir -p "$OUT_DIR"
    
    # Verify toolchain
    if ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
        print_error "Toolchain not found in PATH"
        print_info "Please ensure toolchain is properly set up"
        exit 1
    fi
    
    print_success "Build environment initialized"
}

# Device Tree Blob generation
dtb_img() {
    print_step "Generating Device Tree Blob..."
    
    if [ ! -f "$dt_tool/mkdtimg" ]; then
        print_error "mkdtimg not found at $dt_tool/mkdtimg"
        return 1
    fi
    
    if [ ! -f "$dt_tool/exynos9825.cfg" ]; then
        print_error "exynos9825.cfg not found"
        return 1
    fi
    
    chmod +777 "$dt_tool"/* -R
    "$dt_tool/mkdtimg" cfg_create "$OUT_DIR/dt.img" "$dt_tool/exynos9825.cfg" -d "$work_dir/arch/arm64/boot/dts/exynos"
    
    if [ -f "$OUT_DIR/dt.img" ]; then
        print_success "DTB image created: $OUT_DIR/dt.img"
    else
        print_error "Failed to create DTB image"
        return 1
    fi
}

# Packing function
packing() {
    local selinux_status="$1"
    local ksu_enabled="$2"
    
    print_step "Repacking boot image (SELinux: $selinux_status, KSU: $ksu_enabled)..."
    
    # Prepare AIK directory
    cd "$dt_tool/AIK/ramdisk"
    mkdir -p debug_ramdisk dev metadata mnt proc second_stage_resources sys
    
    # Repack boot image
    cd "$work_dir"
    if sudo bash "$repacker"; then
        print_info "Boot image repacked successfully"
    else
        print_error "Failed to repack boot image"
        return 1
    fi
    
    # Move and create flashable files
    mv "$dt_tool/AIK/image-new.img" "$OUT_DIR/boot.img"
    
    # Create device-specific directory structure
    local device_dir="$DEVICE"
    if [ "$ksu_enabled" = "y" ]; then
        device_dir="${DEVICE}-KSU"
    fi
    
    cd "$OUT_DIR"
    mkdir -p "$device_dir/$selinux_status"
    cp "$VBMETA" .
    
    chmod +777 *
    
    # Create tar file
    local tar_name="LPoS ${KERNEL_VERSION}"
    if [ "$ksu_enabled" = "y" ]; then
        tar_name+=" [KSU]"
    fi
    tar_name+=" [${DEVICE}] - ${selinux_status}.tar"
    
    tar -cvf "$tar_name" boot.img dt.img vbmeta.img
    rm -f boot.img dt.img vbmeta.img
    mv "$tar_name" "$device_dir/$selinux_status/"
    
    print_success "Flashable package created: $device_dir/$selinux_status/$tar_name"
}

# Create final zip package
create_flashable_zip() {
    local zip_prefix="$1"
    
    print_step "Creating flashable ZIP package..."
    
    cd "$OUT_DIR"
    local zip_name="LPoS [${DEVICE}]"
    
    if [ -n "$zip_prefix" ]; then
        zip_name+="[${zip_prefix}]"
    fi
    
    zip_name+=".zip"
    
    if zip -r -9 "$zip_name" "$DEVICE"*; then
        mv "$zip_name" "${zip_name%.zip}-${current_datetime}.zip"
        print_success "ZIP package created: ${zip_name%.zip}-${current_datetime}.zip"
    else
        print_error "Failed to create ZIP package"
        return 1
    fi
}

# Configuration management
replace_config_option() {
    local option="$1"
    local value="$2"
    
    if [ -f "$config_file" ]; then
        if grep -q "^$option=" "$config_file"; then
            sed -i "s/^$option=.*/$option=$value/" "$config_file"
        else
            echo "$option=$value" >> "$config_file"
        fi
        print_info "Config updated: $option=$value"
    else
        print_error "Config file not found: $config_file"
        return 1
    fi
}

# Set LPOS default configuration
lpos_defaults() {
    print_step "Setting LPOS default configuration..."
    replace_config_option "CONFIG_KSU" "n"
    replace_config_option "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "n"
}

# Build kernel
build_kernel() {
    local selinux_mode="$1"
    local ksu_mode="$2"
    
    print_step "Building kernel (SELinux: $selinux_mode, KSU: $ksu_mode)..."
    
    # Set configuration
    replace_config_option "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "$selinux_mode"
    replace_config_option "CONFIG_KSU" "$ksu_mode"
    
    # Build kernel
    make ${ARGS} "$exynos_defconfig"
    if make ${ARGS} -j"$(nproc)"; then
        print_success "Kernel built successfully"
    else
        print_error "Kernel build failed"
        return 1
    fi
    
    # Generate DTB
    dtb_img
    
    # Copy kernel image
    if [ -f "$work_dir/arch/arm64/boot/Image" ]; then
        cp "$work_dir/arch/arm64/boot/Image" "$dt_tool/AIK/split_img/boot.img-kernel"
        print_info "Kernel image copied to AIK"
    else
        print_error "Kernel image not found"
        return 1
    fi
}

# Clean build
clean_build() {
    print_step "Starting clean build..."
    
    # Clean source
    make ${ARGS} clean && make ${ARGS} mrproper
    lpos_defaults
    
    # Build enforcing version
    export SELINUX_STATUS="Enforcing"
    build_kernel "n" "n"
    packing "$SELINUX_STATUS" "n"
    
    # Build permissive version
    export SELINUX_STATUS="Permissive" 
    build_kernel "y" "n"
    packing "$SELINUX_STATUS" "n"
    
    # Create final zip
    create_flashable_zip ""
    
    print_success "Clean build completed"
}

# Dirty build
dirty_build() {
    print_step "Starting dirty build..."
    
    export SELINUX_STATUS="Enforcing"
    build_kernel "n" "n"
    packing "$SELINUX_STATUS" "n"
    
    print_success "Dirty build completed"
}

# Deep clean
deep_clean() {
    print_step "Performing deep clean..."
    
    make ${ARGS} clean && make ${ARGS} mrproper
    lpos_defaults
    
    # Clean output directory
    if [ -d "$OUT_DIR" ]; then
        rm -rf "$OUT_DIR"
        print_info "Output directory cleaned"
    fi
    
    print_success "Deep clean completed"
}

# KernelSU build
build_ksu() {
    print_step "Setting up KernelSU..."
    
    # Clone KernelSU-next
    if [ ! -d "KernelSU-Next" ]; then
        if git clone https://github.com/GoRhanHee/KernelSU-Next.git; then
            print_info "KernelSU-Next cloned successfully"
        else
            print_error "Failed to clone KernelSU-Next"
            return 1
        fi
    fi
    
    # Build KSU enforcing
    print_step "Building KernelSU Enforcing..."
    export SELINUX_STATUS="Enforcing"
    build_kernel "n" "y"
    packing "$SELINUX_STATUS" "y"
    
    # Build KSU permissive
    print_step "Building KernelSU Permissive..."
    export SELINUX_STATUS="Permissive"
    build_kernel "y" "y"
    packing "$SELINUX_STATUS" "y"
    
    # Create KSU zip
    create_flashable_zip "KSU"
    
    # Clean up
    deep_clean
    
    print_success "KernelSU build completed"
}

# Main execution
main() {
    print_step "=== LPoS Kernel Build Script ==="
    print_info "Kernel: $KERNEL_NAME $KERNEL_VERSION"
    print_info "Device: $DEVICE"
    print_info "Architecture: $ARCH"
    print_info "Build Date: $current_datetime"
    
    # Initialize build environment
    initialize_build
    
    # Parse command line arguments
    case "${1:-}" in
        "-c"|"--clean")
            clean_build
            ;;
        "-d"|"--dirty")
            dirty_build
            ;;
        "-x"|"--clean-source")
            deep_clean
            ;;
        "-k"|"--kernelsu")
            build_ksu
            ;;
        "-h"|"--help")
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
    
    print_success "Build process completed successfully!"
}

# Help function
show_help() {
    echo -e "${CYAN}LPoS Kernel Build Script${NC}"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  -c, --clean         Perform clean build (both enforcing and permissive)"
    echo "  -d, --dirty         Perform dirty build (enforcing only)"  
    echo "  -x, --clean-source  Deep clean source tree"
    echo "  -k, --kernelsu      Build with KernelSU support"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --clean          # Clean build with both SELinux modes"
    echo "  $0 --kernelsu       # Build with KernelSU support"
    echo "  $0 --dirty          # Quick dirty build"
}

# Run main function
main "$@"