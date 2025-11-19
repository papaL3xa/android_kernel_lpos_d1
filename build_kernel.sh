#!/bin/bash

# Enhanced Android Kernel Build Script for LPOS D1
# Fixed version for toolchain and build issues

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
KERNEL_VERSION="v1.0.0-stable"
DEVICE="Note 10"
BUILD_DIR="${PWD}"
OUT_DIR="${BUILD_DIR}/out"
ARCH="arm64"
PLATFORM_VERSION=12
ANDROID_MAJOR_VERSION=s

# Toolchain configuration - FIXED: Use proper toolchain
TOOLCHAIN_DIR="${BUILD_DIR}/toolchain"
CLANG_DIR="${BUILD_DIR}/clang"

# Export paths
export PATH="${TOOLCHAIN_DIR}/bin:${CLANG_DIR}/bin:${PATH}"

# Build arguments - FIXED: Simplified for compatibility
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export STRIP="llvm-strip"
export CC="clang"
export LD="ld.lld"
export ARCH="arm64"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export LLVM=1

# Binary paths
export work_dir="${BUILD_DIR}"
export dt_tool="${work_dir}/binaries"
export repacker="${dt_tool}/AIK/repackimg.sh"
export VBMETA="${dt_tool}/addons/vbmeta.img"

# Defconfig
export exynos_defconfig="exynos9820-d1_defconfig"
export config_file="arch/arm64/configs/${exynos_defconfig}"

# Build information
export current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")
export KBUILD_BUILD_USER="@ravindu644"

# Function to print colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# Check and setup toolchain
setup_toolchain() {
    print_step "Setting up toolchain..."
    
    # Check if toolchain exists
    if [ ! -d "$TOOLCHAIN_DIR" ]; then
        print_error "Toolchain not found at: $TOOLCHAIN_DIR"
        print_info "Please ensure toolchain is properly set up"
        print_info "Expected structure:"
        echo "  $TOOLCHAIN_DIR/bin/aarch64-linux-gnu-gcc"
        echo "  $CLANG_DIR/bin/clang"
        return 1
    fi
    
    # Check for essential binaries
    local missing_tools=()
    
    if ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
        missing_tools+=("aarch64-linux-gnu-gcc")
    fi
    
    if ! command -v clang &> /dev/null; then
        missing_tools+=("clang")
    fi
    
    if ! command -v ld.lld &> /dev/null; then
        missing_tools+=("ld.lld")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing tools: ${missing_tools[*]}"
        print_info "Please check your toolchain installation"
        return 1
    fi
    
    print_info "Toolchain version info:"
    aarch64-linux-gnu-gcc --version | head -1
    clang --version | head -1
    ld.lld --version | head -1
    
    print_success "Toolchain setup completed"
}

# Fix for missing init_clang_13.sh
fix_clang_android_script() {
    print_step "Checking for init_clang_13.sh..."
    
    if [ ! -f "./scripts/init_clang_13.sh" ]; then
        print_warning "init_clang_13.sh not found, creating compatibility workaround..."
        
        # Create a simple init_clang_13.sh wrapper
        cat > ./scripts/init_clang_13.sh << 'EOF'
#!/bin/bash
# Compatibility wrapper for init_clang_13.sh
exec clang "$@"
EOF
        
        chmod +x ./scripts/init_clang_13.sh
        print_info "Created init_clang_13.sh compatibility wrapper"
    else
        print_info "init_clang_13.sh already exists"
    fi
}

# Initialize build environment
initialize_build() {
    print_step "Initializing build environment..."
    
    # Create symbolic link for python
    if [ ! -L "$HOME/python" ] && [ -f "/usr/bin/python2.7" ]; then
        ln -sf /usr/bin/python2.7 "$HOME/python"
        print_info "Created Python symbolic link"
    fi
    
    # Set executable permissions for binaries
    if [ -d "$dt_tool" ]; then
        chmod +775 -R "$dt_tool/"
        print_info "Set executable permissions for binaries"
    fi
    
    # Create output directory
    mkdir -p "$OUT_DIR"
    
    # Fix init_clang_13.sh issue
    fix_init_clang_13_script
    
    # Setup toolchain
    if ! setup_toolchain; then
        print_error "Toolchain setup failed"
        return 1
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
    local ksu_enabled="${2:-n}"
    
    print_step "Repacking boot image (SELinux: $selinux_status, KSU: $ksu_enabled)..."
    
    # Check if AIK directory exists
    if [ ! -d "$dt_tool/AIK" ]; then
        print_error "AIK directory not found: $dt_tool/AIK"
        return 1
    fi
    
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
    if [ -f "$dt_tool/AIK/image-new.img" ]; then
        mv "$dt_tool/AIK/image-new.img" "$OUT_DIR/boot.img"
    else
        print_error "Repacked image not found"
        return 1
    fi
    
    # Create device-specific directory structure
    local device_dir="$DEVICE"
    if [ "$ksu_enabled" = "y" ]; then
        device_dir="${DEVICE}-KSU"
    fi
    
    cd "$OUT_DIR"
    mkdir -p "$device_dir/$selinux_status"
    
    if [ -f "$VBMETA" ]; then
        cp "$VBMETA" .
    else
        print_warning "vbmeta.img not found, continuing without it"
        touch vbmeta.img
    fi
    
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
    
    # Find device directories to zip
    local device_dirs=()
    for dir in "$DEVICE"*; do
        if [ -d "$dir" ]; then
            device_dirs+=("$dir")
        fi
    done
    
    if [ ${#device_dirs[@]} -eq 0 ]; then
        print_error "No device directories found to zip"
        return 1
    fi
    
    if zip -r -9 "$zip_name" "${device_dirs[@]}"; then
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

# Build kernel with better error handling
build_kernel() {
    local selinux_mode="$1"
    local ksu_mode="${2:-n}"
    
    print_step "Building kernel (SELinux: $selinux_mode, KSU: $ksu_mode)..."
    
    # Set configuration
    replace_config_option "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "$selinux_mode"
    replace_config_option "CONFIG_KSU" "$ksu_mode"
    
    # Clean configuration state
    print_info "Preparing kernel configuration..."
    make ARCH="$ARCH" distclean 2>/dev/null || true
    make ARCH="$ARCH" mrproper 2>/dev/null || true
    
    # Build kernel with simplified approach
    print_info "Running defconfig..."
    if ! make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$exynos_defconfig"; then
        print_error "Failed to run defconfig"
        return 1
    fi
    
    print_info "Compiling kernel..."
    if make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" LD="$LD" -j"$(nproc)"; then
        print_success "Kernel built successfully"
    else
        print_error "Kernel build failed"
        return 1
    fi
    
    # Generate DTB
    if ! dtb_img; then
        print_error "DTB generation failed"
        return 1
    fi
    
    # Copy kernel image
    if [ -f "$work_dir/arch/arm64/boot/Image" ]; then
        cp "$work_dir/arch/arm64/boot/Image" "$dt_tool/AIK/split_img/boot.img-kernel"
        print_info "Kernel image copied to AIK"
    else
        print_error "Kernel image not found at $work_dir/arch/arm64/boot/Image"
        return 1
    fi
}

# Clean build
clean_build() {
    print_step "Starting clean build..."
    
    # Clean source
    make ARCH="$ARCH" distclean 2>/dev/null || true
    make ARCH="$ARCH" mrproper 2>/dev/null || true
    lpos_defaults
    
    # Build enforcing version
    export SELINUX_STATUS="Enforcing"
    if build_kernel "n" "n"; then
        packing "$SELINUX_STATUS" "n"
    else
        print_error "Enforcing build failed"
        return 1
    fi
    
    # Build permissive version  
    export SELINUX_STATUS="Permissive"
    if build_kernel "y" "n"; then
        packing "$SELINUX_STATUS" "n"
    else
        print_error "Permissive build failed"
        return 1
    fi
    
    # Create final zip
    create_flashable_zip ""
    
    print_success "Clean build completed"
}

# Dirty build
dirty_build() {
    print_step "Starting dirty build..."
    
    export SELINUX_STATUS="Enforcing"
    if build_kernel "n" "n"; then
        packing "$SELINUX_STATUS" "n"
        print_success "Dirty build completed"
    else
        print_error "Dirty build failed"
        return 1
    fi
}

# Deep clean
deep_clean() {
    print_step "Performing deep clean..."
    
    make ARCH="$ARCH" distclean 2>/dev/null || true
    make ARCH="$ARCH" mrproper 2>/dev/null || true
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
    
    # Clone KernelSU-next if needed
    if [ ! -d "KernelSU-Next" ]; then
        print_info "Cloning KernelSU-Next..."
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
    if build_kernel "n" "y"; then
        packing "$SELINUX_STATUS" "y"
    else
        print_error "KSU Enforcing build failed"
        return 1
    fi
    
    # Build KSU permissive
    print_step "Building KernelSU Permissive..."
    export SELINUX_STATUS="Permissive"
    if build_kernel "y" "y"; then
        packing "$SELINUX_STATUS" "y"
    else
        print_error "KSU Permissive build failed"
        return 1
    fi
    
    # Create KSU zip
    create_flashable_zip "KSU"
    
    print_success "KernelSU build completed"
}

# Show help
show_help() {
    echo -e "${CYAN}LPoS Kernel Build Script - Fixed Version${NC}"
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
    echo "Toolchain Requirements:"
    echo "  - aarch64-linux-gnu-gcc"
    echo "  - clang"
    echo "  - ld.lld"
    echo "  - Directory structure:"
    echo "    ./toolchain/bin/aarch64-linux-gnu-*"
    echo "    ./clang/bin/clang"
    echo ""
    echo "Examples:"
    echo "  $0 --clean          # Clean build with both SELinux modes"
    echo "  $0 --kernelsu       # Build with KernelSU support"
    echo "  $0 --dirty          # Quick dirty build"
}

# Main execution
main() {
    print_step "=== LPoS Kernel Build Script - Fixed Version ==="
    print_info "Kernel: $KERNEL_NAME $KERNEL_VERSION"
    print_info "Device: $DEVICE"
    print_info "Architecture: $ARCH"
    print_info "Build Date: $current_datetime"
    
    # Initialize build environment
    if ! initialize_build; then
        print_error "Build environment initialization failed"
        exit 1
    fi
    
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

# Run main function
main "$@"