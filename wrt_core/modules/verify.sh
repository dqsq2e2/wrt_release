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
        echo "错误：源码仍会把 ImmortalWrt 官方 APK 仓库替换为国内镜像。" >&2
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

    native_repo=$(grep -Eo 'https://downloads\.immortalwrt\.org/[^ )"]+' "$version_makefile" | head -n 1 || true)
    if [ -z "$native_repo" ]; then
        echo "错误：当前源码未配置 ImmortalWrt APK 软件源。" >&2
        return 1
    fi

    if [ ! -f "$keyring_makefile" ] ||
       ! grep -qE 'apk/immortalwrt-[^ ]+\.pem' "$keyring_makefile"; then
        echo "错误：当前源码缺少 ImmortalWrt APK 签名公钥。" >&2
        return 1
    fi

    echo "保留源码原生 APK 软件源：$native_repo"
}


verify_custom_feed_installed_paths() {
    local custom_feed_name
    local custom_feed_package_dir
    # install_feeds 后必须存在的 custom_feed 包路径。
    local required_package_dirs=(
        luci-app-adguardhome luci-app-mosdns v2ray-geodata luci-app-easytier
        luci-app-passwall nikki luci-app-nikki mihomo-meta luci-app-emmc-health
        luci-app-wolultra luci-app-mini-diskmanager luci-app-homeproxy sing-box
        axonhub luci-app-axonhub gecoosac luci-app-gecoosac
        taskd luci-lib-xterm luci-lib-taskd luci-app-store
    )
    local missing_package_dirs=()

    custom_feed_name=$(get_custom_feed_name)
    custom_feed_package_dir=$(get_custom_feed_package_dir)

    collect_missing_directories "$custom_feed_package_dir" required_package_dirs missing_package_dirs

    if [ ${#missing_package_dirs[@]} -ne 0 ]; then
        printf '错误：%s 安装后缺少以下仓库依赖路径：\n' "$custom_feed_name" >&2
        printf '  - %s\n' "${missing_package_dirs[@]}" >&2
        return 1
    fi
}
