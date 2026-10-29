#!/usr/bin/env bash
# 构建树一致性检查。

verify_native_apk_repository_support() {
    local apk_makefile="$BUILD_DIR/package/system/apk/Makefile"
    local base_files_makefile="$BUILD_DIR/package/base-files/Makefile"
    local default_settings_chinese="$BUILD_DIR/package/emortal/default-settings/files/99-default-settings-chinese"
    local feeds_makefile="$BUILD_DIR/include/feeds.mk"
    local version_makefile="$BUILD_DIR/include/version.mk"
    local keyring_makefile="$BUILD_DIR/package/system/openwrt-keyring/Makefile"
    local native_repo

    if [ ! -f "$apk_makefile" ]; then
        echo "错误：当前源码缺少 APK 包管理器。" >&2
        return 1
    fi

    if [ ! -f "$base_files_makefile" ] ||
       ! grep -Fq 'FeedSourcesAppendAPK' "$base_files_makefile"; then
        echo "错误：当前源码不能原生生成 APK distfeeds.list。" >&2
        return 1
    fi

    if [ ! -f "$default_settings_chinese" ] ||
       grep -qE 'mirrors\.vsean\.net/openwrt|downloads\.immortalwrt\.org,\$apk_mirror' "$default_settings_chinese"; then
        echo "错误：源码仍会把 APK 官方仓库替换为国内镜像。" >&2
        return 1
    fi

    if [ ! -f "$feeds_makefile" ] ||
       ! grep -Fq '$(filter custom_feed openwrt_bandix luci_app_bandix,$(feed))' "$feeds_makefile"; then
        echo "错误：仅用于编译的 feeds 仍会被写入运行时 APK 仓库。" >&2
        return 1
    fi

    if [ ! -f "$version_makefile" ]; then
        echo "错误：当前源码缺少版本仓库配置。" >&2
        return 1
    fi

    native_repo=$(grep -Eo 'https://downloads\.openwrt\.org/(snapshots|releases/25\.12-SNAPSHOT)' "$version_makefile" | head -n 1 || true)
    if [ -z "$native_repo" ]; then
        echo "错误：当前源码未配置 OpenWrt 官方 APK 软件源。" >&2
        return 1
    fi

    if [ ! -f "$keyring_makefile" ] ||
       ! grep -qE 'apk/immortalwrt-[^ ]+\.pem' "$keyring_makefile"; then
        echo "错误：当前源码缺少 ImmortalWrt APK 签名公钥。" >&2
        return 1
    fi

    echo "使用 OpenWrt 官方 APK 软件源：$native_repo"
}


verify_custom_feed_installed_paths() {
    local custom_feed_name
    local custom_feed_package_dir
    # install_feeds 后必须存在的 custom_feed 包路径。
    local required_package_dirs=(
        luci-app-adguardhome luci-app-mosdns v2ray-geodata luci-app-easytier
        luci-app-passwall nikki luci-app-nikki mihomo-meta luci-app-emmc-health
        luci-app-airoha-npu geo2txt
        luci-app-wolultra luci-app-mini-diskmanager luci-app-homeproxy sing-box
        axonhub luci-app-axonhub gecoosac luci-app-gecoosac
        luci-app-tingreader luci-app-upnp miniupnpd
        taskd luci-lib-xterm luci-lib-taskd luci-app-store
    )
    local missing_package_dirs=()

    if [[ ${DAED_PACKAGES_ENABLED:-0} == "1" ]]; then
        required_package_dirs+=(dae daed luci-app-daede vmlinux-btf)
    fi
    if [[ ${HONK_PACKAGES_ENABLED:-0} == "1" ]]; then
        required_package_dirs+=(honk luci-app-honk)
    fi

    custom_feed_name=$(get_custom_feed_name)
    custom_feed_package_dir=$(get_custom_feed_package_dir)

    collect_missing_directories "$custom_feed_package_dir" required_package_dirs missing_package_dirs

    if [ ${#missing_package_dirs[@]} -ne 0 ]; then
        printf '错误：%s 安装后缺少以下仓库依赖路径：\n' "$custom_feed_name" >&2
        printf '  - %s\n' "${missing_package_dirs[@]}" >&2
        return 1
    fi
}


verify_expected_kernel_version() {
    local expected="$1"
    local target_makefile="$2"
    local actual

    [[ -n $expected ]] || return 0
    if [[ ! -f $target_makefile ]]; then
        echo "Error: kernel target Makefile not found: $target_makefile" >&2
        return 1
    fi

    actual=$(sed -nE 's/^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*([^[:space:]]+).*/\1/p' "$target_makefile" | head -n 1)
    if [[ $actual != "$expected" ]]; then
        echo "Error: expected kernel $expected, upstream target uses ${actual:-unknown}." >&2
        return 1
    fi
}


verify_daed_config() {
    local config_path="$1"
    local enabled="${2:-0}"
    local symbol
    local required_symbols=(
        CONFIG_PACKAGE_daed=y
        CONFIG_PACKAGE_luci-app-daede=y
        CONFIG_PACKAGE_luci-app-daede_daed=y
        CONFIG_DAED_USE_KERNEL_BTF=y
        CONFIG_BPF_TOOLCHAIN_HOST=y
        CONFIG_KERNEL_DEBUG_INFO=y
        CONFIG_KERNEL_DEBUG_INFO_BTF=y
        CONFIG_KERNEL_BPF_EVENTS=y
        CONFIG_KERNEL_CGROUPS=y
        CONFIG_KERNEL_CGROUP_BPF=y
        CONFIG_KERNEL_NET_NS=y
        CONFIG_KERNEL_XDP_SOCKETS=y
        CONFIG_PACKAGE_kmod-sched-core=y
        CONFIG_PACKAGE_kmod-sched-bpf=y
        CONFIG_PACKAGE_kmod-veth=y
        CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
        CONFIG_PACKAGE_ip-full=y
    )
    local missing_symbols=()

    [[ $enabled == "1" ]] || return 0
    for symbol in "${required_symbols[@]}"; do
        if ! grep -qxF "$symbol" "$config_path"; then
            missing_symbols+=("$symbol")
        fi
    done

    if [[ ${#missing_symbols[@]} -ne 0 ]]; then
        printf 'Error: make defconfig dropped required daed/eBPF settings:\n' >&2
        printf '  - %s\n' "${missing_symbols[@]}" >&2
        return 1
    fi
}


verify_honk_config() {
    local config_path="$1"
    local enabled="${2:-0}"
    local symbol
    local required_symbols=(
        CONFIG_PACKAGE_honk=y
        CONFIG_PACKAGE_luci-app-honk=y
        CONFIG_PACKAGE_v2ray-geoip=y
        CONFIG_PACKAGE_v2ray-geosite=y
        CONFIG_BPF_TOOLCHAIN_HOST=y
        CONFIG_KERNEL_DEBUG_INFO=y
        CONFIG_KERNEL_DEBUG_INFO_BTF=y
        CONFIG_KERNEL_BPF_EVENTS=y
        CONFIG_KERNEL_CGROUPS=y
        CONFIG_KERNEL_CGROUP_BPF=y
        CONFIG_KERNEL_NET_NS=y
        CONFIG_KERNEL_XDP_SOCKETS=y
        CONFIG_PACKAGE_kmod-sched-core=y
        CONFIG_PACKAGE_kmod-sched-bpf=y
        CONFIG_PACKAGE_kmod-veth=y
        CONFIG_PACKAGE_kmod-nft-queue=y
        CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
        CONFIG_PACKAGE_ip-full=y
    )
    local missing_symbols=()

    [[ $enabled == "1" ]] || return 0
    for symbol in "${required_symbols[@]}"; do
        if ! grep -qxF "$symbol" "$config_path"; then
            missing_symbols+=("$symbol")
        fi
    done

    if [[ ${#missing_symbols[@]} -ne 0 ]]; then
        printf 'Error: make defconfig dropped required Honk/eBPF settings:\n' >&2
        printf '  - %s\n' "${missing_symbols[@]}" >&2
        return 1
    fi
}
