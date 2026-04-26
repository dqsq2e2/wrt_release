#!/usr/bin/env bash

set -e

# Determine wrt_core path
if [ -d "wrt_core" ]; then
    WRT_CORE_PATH="wrt_core"
elif [ -d "../wrt_core" ]; then
    WRT_CORE_PATH="../wrt_core"
else
    echo "Error: wrt_core directory not found!"
    exit 1
fi

BASE_PATH=$(cd "$WRT_CORE_PATH" && pwd)

Dev=$1
Build_Mod=$2

SUPPORTED_DEVS=()

collect_supported_devs() {
    local ini_file
    local dev_key
    local IFS

    SUPPORTED_DEVS=()

    for ini_file in "$BASE_PATH"/compilecfg/*.ini; do
        [[ -f "$ini_file" ]] || continue

        dev_key=$(basename "$ini_file" .ini)
        if [[ -f "$BASE_PATH/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        return
    fi

    IFS=$'\n' SUPPORTED_DEVS=($(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort))
}

print_usage() {
    echo "Usage: $0 <device> [debug]"
}

print_supported_devs() {
    local index

    echo "Supported devices:"
    for ((index = 0; index < ${#SUPPORTED_DEVS[@]}; index++)); do
        printf "  %d) %s\n" "$((index + 1))" "${SUPPORTED_DEVS[index]}"
    done
}

prompt_select_dev() {
    local input
    local selected_index

    while true; do
        print_supported_devs
        printf "Select device by number (q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            selected_index=${BASH_REMATCH[1]}
            if ((selected_index >= 1 && selected_index <= ${#SUPPORTED_DEVS[@]})); then
                Dev=${SUPPORTED_DEVS[selected_index - 1]}
                return
            fi
        fi

        echo "Invalid selection. Please enter a number between 1 and ${#SUPPORTED_DEVS[@]}."
    done
}

prompt_select_build_mode() {
    local input

    while true; do
        echo "Build mode:"
        echo "  1) normal"
        echo "  2) debug"
        printf "Select build mode (1-2, q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
            Build_Mod=""
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*2[[:space:]]*$ ]]; then
            Build_Mod="debug"
            return
        fi

        echo "Invalid selection. Please enter 1 or 2."
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

if [[ $# -eq 0 ]]; then
    collect_supported_devs

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        echo "Error: no supported devices found."
        exit 1
    fi

    if ! is_interactive_terminal; then
        print_usage
        print_supported_devs
        exit 1
    fi

    prompt_select_dev

    if [[ -z $Build_Mod ]]; then
        prompt_select_build_mode
    fi
fi

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE" | tr -d '\r\n' | xargs
}

remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/../$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/../$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

apply_config() {
    \cp -f "$CONFIG_FILE" "$BASE_PATH/../$BUILD_DIR/.config"
    
    if grep -qE "(ipq60xx|ipq807x)" "$BASE_PATH/../$BUILD_DIR/.config" &&
        ! grep -q "CONFIG_GIT_MIRROR" "$BASE_PATH/../$BUILD_DIR/.config"; then
        cat "$BASE_PATH/deconfig/nss.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    fi

    cat "$BASE_PATH/deconfig/compile_base.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    # 只有在配置文件中启用了 Docker 时才加载 docker_deps.config
    if grep -q "CONFIG_PACKAGE_dockerd=y" "$BASE_PATH/../$BUILD_DIR/.config"; then
        echo "检测到 Docker 已启用，加载 docker_deps.config"
        cat "$BASE_PATH/deconfig/docker_deps.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
        
        # 检查 Docker 兼容性（VIKINGYFY 源码不支持 nftables）
        source "$BASE_PATH/modules/docker.sh"
        if ! check_docker_compatibility; then
            echo "Docker 兼容性检查失败，请禁用 Docker 或使用 C佬源码"
            echo "继续编译可能会失败..."
        fi
    else
        echo "Docker 未启用，跳过 docker_deps.config"
    fi

    cat "$BASE_PATH/deconfig/proxy.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

if [[ -d action_build ]]; then
    BUILD_DIR="action_build"
fi

"$BASE_PATH/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH"

apply_config
remove_uhttpd_dependency

cd "$BASE_PATH/../$BUILD_DIR"

# 验证 apply_config 后的配置（defconfig 之前）
echo ""
echo "=========================================="
echo "验证 apply_config 后的配置（defconfig 之前）"
echo "=========================================="
echo "iptables-nft: $(grep '^CONFIG_PACKAGE_iptables-nft=' .config || echo '未设置')"
echo "kmod-ipt-nat: $(grep '^CONFIG_PACKAGE_kmod-ipt-nat=' .config || echo '未设置')"
echo "firewall4: $(grep '^CONFIG_PACKAGE_firewall4=' .config || echo '未设置')"
echo "=========================================="
echo ""

# 运行 defconfig 生成完整配置
make defconfig

# 验证关键配置是否生效（defconfig 之后）
echo ""
echo "=========================================="
echo "验证 defconfig 后的配置"
echo "=========================================="
echo "firewall4: $(grep '^CONFIG_PACKAGE_firewall4=' .config || echo '未设置')"
echo "iptables: $(grep '^CONFIG_PACKAGE_iptables=' .config || echo '未设置')"
echo "iptables-nft: $(grep '^CONFIG_PACKAGE_iptables-nft=' .config || echo '未设置')"
echo "kmod-ipt-nat: $(grep '^CONFIG_PACKAGE_kmod-ipt-nat=' .config || echo '未设置')"
echo "kmod-nft-nat: $(grep '^CONFIG_PACKAGE_kmod-nft-nat=' .config || echo '未设置')"
echo "=========================================="
echo ""

# 在配置生成后，检查是否需要移除 WiFi 界面
source "$BASE_PATH/modules/system.sh"
remove_wifi_menu

# 检查 iStore 核心组件是否被禁用
echo "正在检查 iStore 核心组件状态..."
NEED_FORCE=0

if ! grep -q "^CONFIG_PACKAGE_luci-app-store=y" .config; then
    echo "⚠️  luci-app-store 被禁用"
    NEED_FORCE=1
fi

if ! grep -q "^CONFIG_PACKAGE_luci-app-quickstart=y" .config; then
    echo "⚠️  luci-app-quickstart 被禁用"
    NEED_FORCE=1
fi

if ! grep -q "^CONFIG_PACKAGE_tar=y" .config; then
    echo "⚠️  tar 被禁用"
    NEED_FORCE=1
fi

if ! grep -q "^CONFIG_PACKAGE_taskd=y" .config; then
    echo "⚠️  taskd 被禁用"
    NEED_FORCE=1
fi

if ! grep -q "^CONFIG_PACKAGE_luci-lib-taskd=y" .config; then
    echo "⚠️  luci-lib-taskd 被禁用"
    NEED_FORCE=1
fi

if [ $NEED_FORCE -eq 1 ]; then
    echo ""
    echo "=========================================="
    echo "检测到 iStore 组件被 defconfig 禁用"
    echo "正在强制启用 iStore 及其依赖..."
    echo "=========================================="
    
    # 删除所有 iStore 相关配置
    sed -i '/CONFIG_PACKAGE_luci-app-store/d' .config
    sed -i '/CONFIG_PACKAGE_luci-i18n-store-zh-cn/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-quickstart/d' .config
    sed -i '/CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-istoreenhance/d' .config
    sed -i '/CONFIG_PACKAGE_luci-i18n-istoreenhance-zh-cn/d' .config
    sed -i '/CONFIG_PACKAGE_taskd/d' .config
    sed -i '/CONFIG_PACKAGE_luci-lib-taskd/d' .config
    sed -i '/CONFIG_PACKAGE_luci-lib-xterm/d' .config
    sed -i '/CONFIG_PACKAGE_luci-lib-ipkg/d' .config
    sed -i '/CONFIG_PACKAGE_quickstart/d' .config
    sed -i '/CONFIG_PACKAGE_istoreenhance/d' .config
    sed -i '/CONFIG_PACKAGE_mount-utils/d' .config
    
    # 删除 tar 相关配置
    sed -i '/CONFIG_PACKAGE_tar=\|CONFIG_PACKAGE_TAR_/d' .config
    sed -i '/CONFIG_PACKAGE_bzip2/d' .config
    sed -i '/CONFIG_PACKAGE_libbz2/d' .config
    sed -i '/CONFIG_PACKAGE_xz/d' .config
    sed -i '/CONFIG_PACKAGE_liblzma/d' .config
    sed -i '/CONFIG_PACKAGE_libacl/d' .config
    sed -i '/CONFIG_PACKAGE_libattr/d' .config
    sed -i '/CONFIG_PACKAGE_libzstd/d' .config
    
    # 强制启用所有依赖和组件
    cat >> .config << 'EOF'

# ========================================
# iStore Force Enable (依赖被禁用时强制启用)
# ========================================
# Core Dependencies
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_opkg=y
CONFIG_PACKAGE_luci-lib-ipkg=y
CONFIG_PACKAGE_libuci-lua=y
CONFIG_PACKAGE_mount-utils=y
CONFIG_PACKAGE_taskd=y
CONFIG_PACKAGE_luci-lib-taskd=y
CONFIG_PACKAGE_luci-lib-xterm=y

# tar and its compression dependencies (完整依赖链)
CONFIG_PACKAGE_tar=y

# bzip2 support
CONFIG_PACKAGE_bzip2=y
CONFIG_PACKAGE_libbz2=y

# xz/lzma support
CONFIG_PACKAGE_xz=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_liblzma=y

# zstd support
CONFIG_PACKAGE_libzstd=y

# ACL and xattr support
CONFIG_PACKAGE_libacl=y
CONFIG_PACKAGE_libattr=y

# tar feature flags
CONFIG_PACKAGE_TAR_BZIP2=y
CONFIG_PACKAGE_TAR_GZIP=y
CONFIG_PACKAGE_TAR_XZ=y
CONFIG_PACKAGE_TAR_ZSTD=y
CONFIG_PACKAGE_TAR_POSIX_ACL=y
CONFIG_PACKAGE_TAR_XATTR=y

# iStore Apps
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-i18n-store-zh-cn=y
CONFIG_PACKAGE_quickstart=y
CONFIG_PACKAGE_luci-app-quickstart=y
CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y
CONFIG_PACKAGE_istoreenhance=y
CONFIG_PACKAGE_luci-app-istoreenhance=y
CONFIG_PACKAGE_luci-i18n-istoreenhance-zh-cn=y
EOF
    
    echo "✅ iStore 组件已强制启用"
    echo "注意：不再运行 defconfig 以避免配置被覆盖"
else
    echo "✅ iStore 核心组件配置正常"
fi

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/../$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/../$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 3))
make -j20 || make -j1 V=s

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/../firmware/Packages.manifest" 2>/dev/null

if [[ -d action_build ]]; then
    make clean
fi
