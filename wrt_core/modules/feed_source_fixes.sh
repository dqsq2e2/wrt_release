#!/usr/bin/env bash
# install_feeds 前的 feed 工作树修正。

remove_unwanted_packages() {
    # 移除将由 custom_feed 接管或会产生冲突的上游包。
    local luci_packages=(
        "luci-app-passwall" "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-openclash" "luci-app-mihomo" "luci-app-appfilter"
        "luci-app-msd_lite" "luci-app-unblockneteasemusic" "luci-app-adguardhome"
    )
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "shadowsocks-rust"
        "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev"
        "dae" "daed" "mihomo" "geoview" "open-app-filter" "msd_lite"
    )
    local packages_utils=(
        "cups"
    )
    for pkg in "${luci_packages[@]}"; do
        if [[ -d ./feeds/luci/applications/$pkg ]]; then
            \rm -rf ./feeds/luci/applications/$pkg
        fi
        if [[ -d ./feeds/luci/themes/$pkg ]]; then
            \rm -rf ./feeds/luci/themes/$pkg
        fi
    done

    for pkg in "${packages_net[@]}"; do
        if [[ -d ./feeds/packages/net/$pkg ]]; then
            \rm -rf ./feeds/packages/net/$pkg
        fi
    done

    for pkg in "${packages_utils[@]}"; do
        if [[ -d ./feeds/packages/utils/$pkg ]]; then
            \rm -rf ./feeds/packages/utils/$pkg
        fi
    done

    if [[ -d ./package/istore ]]; then
        \rm -rf ./package/istore
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        find "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi
}


update_homeproxy() {
    local repo_url="https://github.com/immortalwrt/homeproxy.git"
    local target_dir="$(get_custom_feed_worktree_dir)/luci-app-homeproxy"

    if [ -d "$target_dir" ]; then
        echo "正在更新 homeproxy..."
        rm -rf "$target_dir"
        if ! git_retry clone --depth 1 "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 homeproxy 仓库失败" >&2
            exit 1
        fi
    fi
}


resolve_latest_lucky_release() {
    local release_base_url="https://release.66666.host"
    local root_index
    local version_index
    local lucky_index
    root_index=$(mktemp)
    version_index=$(mktemp)
    lucky_index=$(mktemp)

    if ! curl_retry -fsSL -H "Accept: application/json" -o "$root_index" "$release_base_url/"; then
        echo "错误：无法获取 Lucky 发布目录。" >&2
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    fi

    local release_dir
    release_dir=$(python3 - "$root_index" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    entries = json.load(stream)

candidates = [
    entry for entry in entries
    if entry.get("is_dir") and re.fullmatch(r"v[0-9][0-9A-Za-z._-]*", entry.get("name", ""))
]
if not candidates:
    raise SystemExit(1)

latest = max(candidates, key=lambda entry: entry.get("mod_time", ""))
print(latest["name"])
PY
    ) || {
        echo "错误：Lucky 发布目录中没有可用版本。" >&2
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    }

    if ! curl_retry -fsSL -H "Accept: application/json" -o "$version_index" "$release_base_url/$release_dir/"; then
        echo "错误：无法获取 Lucky 版本目录 $release_dir。" >&2
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    fi

    local lucky_release_dir
    lucky_release_dir=$(python3 - "$version_index" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    entries = json.load(stream)

candidates = [
    entry for entry in entries
    if entry.get("is_dir") and re.fullmatch(r"[0-9]+(?:\.[0-9]+)+_lucky", entry.get("name", ""))
]
if not candidates:
    raise SystemExit(1)

latest = max(candidates, key=lambda entry: entry.get("mod_time", ""))
print(latest["name"])
PY
    ) || {
        echo "错误：$release_dir 中没有纯 Lucky 发布目录。" >&2
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    }

    local lucky_version="${lucky_release_dir%_lucky}"
    if ! curl_retry -fsSL -H "Accept: application/json" -o "$lucky_index" "$release_base_url/$release_dir/$lucky_release_dir/"; then
        echo "错误：无法获取 Lucky 文件目录 $release_dir/$lucky_release_dir。" >&2
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    fi

    if ! python3 - "$lucky_index" "$lucky_version" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    entries = json.load(stream)

version = sys.argv[2]
names = {entry.get("name") for entry in entries if not entry.get("is_dir")}
required = {
    f"lucky_{version}_Linux_arm64.tar.gz",
    f"lucky_{version}_Linux_x86_64.tar.gz",
}
missing = required - names
if missing:
    print("缺少 Lucky 架构包: " + ", ".join(sorted(missing)), file=sys.stderr)
    raise SystemExit(1)
PY
    then
        rm -f "$root_index" "$version_index" "$lucky_index"
        return 1
    fi

    rm -f "$root_index" "$version_index" "$lucky_index"
    printf '%s\t%s\t%s\n' "$release_dir" "$lucky_release_dir" "$lucky_version"
}


update_lucky() {
    local lucky_repo_url="https://github.com/gdy666/luci-app-lucky.git"
    local target_custom_feed_dir="$(get_custom_feed_worktree_dir)"
    local lucky_dir="$target_custom_feed_dir/lucky"
    local luci_app_lucky_dir="$target_custom_feed_dir/luci-app-lucky"

    if [ ! -d "$lucky_dir" ] || [ ! -d "$luci_app_lucky_dir" ]; then
        echo "Warning: $lucky_dir 或 $luci_app_lucky_dir 不存在，跳过 lucky 源代码更新。" >&2
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)

        echo "正在从 $lucky_repo_url 稀疏检出 luci-app-lucky 和 lucky..."

        if ! git_retry clone --depth 1 --filter=blob:none --no-checkout "$lucky_repo_url" "$tmp_dir"; then
            echo "错误：从 $lucky_repo_url 克隆仓库失败" >&2
            rm -rf "$tmp_dir"
            return 0
        fi

        pushd "$tmp_dir" >/dev/null
        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set luci-app-lucky lucky || {
            echo "错误：稀疏检出 luci-app-lucky 或 lucky 失败" >&2
            popd >/dev/null
            rm -rf "$tmp_dir"
            return 0
        }
        git_retry checkout --quiet

        \cp -rf "$tmp_dir/luci-app-lucky/." "$luci_app_lucky_dir/"
        \cp -rf "$tmp_dir/lucky/." "$lucky_dir/"

        popd >/dev/null
        rm -rf "$tmp_dir"
        echo "luci-app-lucky 和 lucky 源代码更新完成。"
    fi

    local lucky_conf="$(get_custom_feed_worktree_dir)/lucky/files/luckyuci"
    if [ -f "$lucky_conf" ]; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$lucky_conf"
        sed -i "s/option logger '1'/option logger '0'/g" "$lucky_conf"
    fi

    local makefile_path="$(get_custom_feed_worktree_dir)/lucky/Makefile"
    if [ ! -f "$makefile_path" ]; then
        echo "Warning: lucky Makefile not found. Skipping." >&2
        return 0
    fi

    local release_info
    if ! release_info=$(resolve_latest_lucky_release); then
        echo "Warning: Lucky 最新版本解析失败，保留上游纯 Lucky 下载逻辑。" >&2
        return 0
    fi

    local release_dir
    local lucky_release_dir
    local lucky_version
    IFS=$'\t' read -r release_dir lucky_release_dir lucky_version <<<"$release_info"
    local download_base_url="https://release.66666.host/$release_dir/$lucky_release_dir"

    echo "正在更新 lucky Makefile: $release_dir/$lucky_release_dir..."
    if ! python3 - "$makefile_path" "$lucky_version" "$download_base_url" <<'PY'
import pathlib
import re
import sys

makefile = pathlib.Path(sys.argv[1])
version = sys.argv[2]
download_base_url = sys.argv[3].rstrip("/")
lines = makefile.read_text(encoding="utf-8").splitlines(keepends=True)

version_count = 0
for index, line in enumerate(lines):
    if line.startswith("PKG_VERSION:="):
        lines[index] = f"PKG_VERSION:={version}\n"
        version_count += 1

if version_count != 1:
    raise SystemExit("Lucky Makefile 中未找到唯一的 PKG_VERSION")

prepare_start = next((index for index, line in enumerate(lines) if line.strip() == "define Build/Prepare"), None)
if prepare_start is None:
    raise SystemExit("Lucky Makefile 中未找到 Build/Prepare")

prepare_end = next(
    (index for index in range(prepare_start + 1, len(lines)) if lines[index].strip() == "endef"),
    None,
)
if prepare_end is None:
    raise SystemExit("Lucky Makefile 的 Build/Prepare 未闭合")

download_line = (
    "\t[ ! -f $(PKG_BUILD_DIR)/$(PKG_NAME)_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz ] "
    f"&& wget --tries=3 --timeout=30 {download_base_url}/$(PKG_NAME)_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz "
    "-O $(PKG_BUILD_DIR)/$(PKG_NAME)_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz\n"
)

download_indexes = [
    index for index in range(prepare_start + 1, prepare_end)
    if "wget " in lines[index] or "wrt_core/patches/lucky_" in lines[index]
]
if download_indexes:
    lines[download_indexes[0]] = download_line
    for index in reversed(download_indexes[1:]):
        del lines[index]
else:
    lines.insert(prepare_start + 1, download_line)

makefile.write_text("".join(lines), encoding="utf-8")
PY
    then
        echo "Warning: lucky Makefile 更新失败，保留上游下载逻辑。" >&2
        return 0
    fi

    echo "lucky Makefile 已切换到纯 Lucky $lucky_version：$download_base_url"
}


remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}


fix_mkpkg_format_invalid() {
    local custom_feed_worktree_dir
    custom_feed_worktree_dir=$(get_custom_feed_worktree_dir)

    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f "$custom_feed_worktree_dir/v2ray-geodata/Makefile" ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' "$custom_feed_worktree_dir/v2ray-geodata/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-lib-taskd/Makefile" ]; then
            sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' "$custom_feed_worktree_dir/luci-lib-taskd/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-openclash/Makefile" ]; then
            sed -i 's/PKG_RELEASE:=beta/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-openclash/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-quickstart/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-store/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
        fi
    fi
}


update_tcping() {
    local tcping_path="$(get_custom_feed_worktree_dir)/tcping/Makefile"
    local url="https://raw.githubusercontent.com/Openwrt-Passwall/openwrt-passwall-packages/refs/heads/main/tcping/Makefile"

    if [ -d "$(dirname "$tcping_path")" ]; then
        echo "正在更新 tcping Makefile..."
        if ! curl_retry -fsSL -o "$tcping_path" "$url"; then
            echo "错误：从 $url 下载 tcping Makefile 失败" >&2
            exit 1
        fi
    fi
}


apply_passwall_tweaks() {
    local chnlist_path="$(get_custom_feed_worktree_dir)/luci-app-passwall/root/usr/share/passwall/rules/chnlist"
    if [ -f "$chnlist_path" ]; then
        >"$chnlist_path"
    fi

    local xray_util_path="$(get_custom_feed_worktree_dir)/luci-app-passwall/luasrc/passwall/util_xray.lua"
    if [ -f "$xray_util_path" ]; then
        sed -i 's/maxRTT = "1s"/maxRTT = "2s"/g' "$xray_util_path"
        sed -i 's/sampling = 3/sampling = 5/g' "$xray_util_path"
    fi
}


update_mosdns_deconfig() {
    local mosdns_conf="$(get_custom_feed_worktree_dir)/luci-app-mosdns/root/etc/config/mosdns"
    if [ -d "${mosdns_conf%/*}" ] && [ -f "$mosdns_conf" ]; then
        sed -i 's/8000/300/g' "$mosdns_conf"
        sed -i 's/5335/5336/g' "$mosdns_conf"
    fi
}


fix_quickstart() {
    local file_path="$(get_custom_feed_worktree_dir)/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    local makefile_path="$(get_custom_feed_worktree_dir)/quickstart/Makefile"
    local url="https://gist.githubusercontent.com/puteulanus/1c180fae6bccd25e57eb6d30b7aa28aa/raw/istore_backend.lua"
    if [ -f "$file_path" ]; then
        echo "正在修复 quickstart..."
        if ! curl_retry -fsSL -o "$file_path" "$url"; then
            echo "错误：从 $url 下载 istore_backend.lua 失败" >&2
            exit 1
        fi
    fi

    if [ -f "$makefile_path" ]; then
        echo "正在移除 quickstart 非必要存储依赖..."
        sed -i \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools-drivedb//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartd//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+mdadm//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+parted//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+e2fsprogs//g' \
            "$makefile_path"
    fi
}


update_oaf_deconfig() {
    local conf_path="$(get_custom_feed_worktree_dir)/open-app-filter/files/appfilter.config"
    local uci_def="$(get_custom_feed_worktree_dir)/luci-app-oaf/root/etc/uci-defaults/94_feature_3.0"
    local disable_path="$(get_custom_feed_worktree_dir)/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"

    if [ -d "${conf_path%/*}" ] && [ -f "$conf_path" ]; then
        sed -i \
            -e "s/record_enable '1'/record_enable '0'/g" \
            -e "s/disable_hnat '1'/disable_hnat '0'/g" \
            -e "s/auto_load_engine '1'/auto_load_engine '0'/g" \
            "$conf_path"
    fi

    if [ -d "${uci_def%/*}" ] && [ -f "$uci_def" ]; then
        sed -i '/\(disable_hnat\|auto_load_engine\)/d' "$uci_def"

        cat >"$disable_path" <<-EOF
#!/bin/sh
[ "\$(uci get appfilter.global.enable 2>/dev/null)" = "0" ] && {
    /etc/init.d/appfilter disable
    /etc/init.d/appfilter stop
}
EOF
        chmod +x "$disable_path"
    fi
}


fix_easytier_mk() {
    local mk_path="$(get_custom_feed_worktree_dir)/luci-app-easytier/easytier/Makefile"
    if [ -f "$mk_path" ]; then
        sed -i 's/!@(mips||mipsel)/!TARGET_mips \&\& !TARGET_mipsel/g' "$mk_path"
    fi
}


remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}
