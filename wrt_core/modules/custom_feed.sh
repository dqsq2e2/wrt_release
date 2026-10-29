#!/usr/bin/env bash
# custom_feed 同步、注册和路径辅助。

get_custom_feed_name() {
    printf '%s\n' "custom_feed"
}


get_custom_feed_source_dir() {
    # install 前本地 src-link 的源目录。
    printf '%s\n' "$BUILD_DIR/$(get_custom_feed_name)"
}


get_custom_feed_worktree_dir() {
    # feeds update 后生成的 feeds/custom_feed 工作树。
    printf '%s\n' "$BUILD_DIR/feeds/$(get_custom_feed_name)"
}


get_custom_feed_package_dir() {
    # feeds install 后生成的 package/feeds/custom_feed 目录。
    printf '%s\n' "$BUILD_DIR/package/feeds/$(get_custom_feed_name)"
}


supports_ucode_luci_themes() {
    [ -d "$BUILD_DIR/feeds/luci/modules/luci-base/ucode" ]
}


sync_sparse_packages_to_feed_dir() {
    local repo_url="$1"
    local repo_branch="$2"
    local target_dir="$3"
    local repo_label="$4"
    shift 4

    local packages=("$@")
    local tmp_dir
    local missing_packages=()
    local clone_args=(clone --depth 1 --filter=blob:none --sparse)
    local pkg
    local package_name

    tmp_dir=$(mktemp -d)

    if [ -n "$repo_branch" ]; then
        clone_args+=(-b "$repo_branch")
    fi

    clone_args+=("$repo_url" "$tmp_dir")

    echo "正在从 $repo_label 稀疏同步指定目录..."
    if ! git_retry "${clone_args[@]}"; then
        echo "错误：从 $repo_url 拉取仓库骨架失败" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! git_retry -C "$tmp_dir" sparse-checkout set "${packages[@]}"; then
        echo "错误：配置 $repo_label 稀疏检出目录失败" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    for pkg in "${packages[@]}"; do
        if [ -d "$tmp_dir/$pkg" ]; then
            package_name=$(basename "$pkg")
            rm -rf "$target_dir/$package_name"
            mv "$tmp_dir/$pkg" "$target_dir/$package_name"
        else
            missing_packages+=("$pkg")
        fi
    done

    rm -rf "$tmp_dir"

    if [ ${#missing_packages[@]} -ne 0 ]; then
        printf '错误：%s 仓库缺少以下必要目录：\n' "$repo_label" >&2
        printf '  - %s\n' "${missing_packages[@]}" >&2
        return 1
    fi
}


sync_repo_root_package_to_feed_dir() {
    local repo_url="$1"
    local repo_branch="$2"
    local target_dir="$3"
    local repo_label="$4"
    local package_name="$5"
    local tmp_dir
    local clone_args=(clone --depth 1 --filter=blob:none)

    tmp_dir=$(mktemp -d)

    if [ -n "$repo_branch" ]; then
        clone_args+=(-b "$repo_branch")
    fi

    clone_args+=("$repo_url" "$tmp_dir")

    echo "正在从 $repo_label 同步单包仓库..."
    if ! git_retry "${clone_args[@]}"; then
        echo "错误：从 $repo_url 克隆 $repo_label 失败" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "$tmp_dir/Makefile" ]; then
        echo "错误：$repo_label 仓库根目录缺少 OpenWrt 软件包 Makefile" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir/.git"
    rm -rf "$target_dir/$package_name"

    if ! mv "$tmp_dir" "$target_dir/$package_name"; then
        echo "错误：无法将 $repo_label 移动到 $target_dir/$package_name" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
}


sync_tingreader_packages_to_feed_dir() {
    local repo_url="$1"
    local repo_branch="$2"
    local target_dir="$3"
    local repo_label="$4"
    local tmp_dir
    local clone_args=(clone --depth 1 --filter=blob:none)
    local pkg
    local tingreader_packages=(luci-app-tingreader)

    tmp_dir=$(mktemp -d)

    if [ -n "$repo_branch" ]; then
        clone_args+=(-b "$repo_branch")
    fi

    clone_args+=("$repo_url" "$tmp_dir")

    echo "正在从 $repo_label 同步 Ting Reader 软件包..."
    if ! git_retry "${clone_args[@]}"; then
        echo "错误：从 $repo_url 克隆 $repo_label 失败" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    # tingreader 的 Makefile 通过相对路径 include 仓库根目录的 version.mk，
    # 展平到 feed 目录后该文件必须位于 feed 根目录，否则版本与哈希变量缺失。
    if [ ! -f "$tmp_dir/version.mk" ]; then
        echo "错误：$repo_label 仓库缺少 version.mk" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    for pkg in "${tingreader_packages[@]}"; do
        if [ ! -f "$tmp_dir/$pkg/Makefile" ]; then
            echo "错误：$repo_label 仓库缺少 $pkg 软件包目录" >&2
            rm -rf "$tmp_dir"
            return 1
        fi

        rm -rf "$target_dir/$pkg"
        if ! mv "$tmp_dir/$pkg" "$target_dir/"; then
            echo "错误：无法同步 $repo_label/$pkg" >&2
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    rm -rf "$target_dir/version.mk"
    if ! mv "$tmp_dir/version.mk" "$target_dir/version.mk"; then
        echo "错误：无法同步 $repo_label/version.mk" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}


verify_istore_apk_support() {
    local package_dir="$1"
    local makefile_path="$package_dir/Makefile"
    local wrapper_path="$package_dir/root/bin/is-opkg"
    local compat_repo_path="$package_dir/src/root-apk/etc/apk/repositories.d/compat.list"

    if [ ! -f "$makefile_path" ] || \
       ! grep -Fq 'USE_APK="$(CONFIG_USE_APK)"' "$makefile_path"; then
        echo "错误：当前 luci-app-store 源码未启用 CONFIG_USE_APK 构建支持" >&2
        return 1
    fi

    if [ ! -f "$wrapper_path" ] || \
       ! grep -Fq 'FEEDS_SERVER=https://istore.istoreos.com/repo-apk' "$wrapper_path"; then
        echo "错误：当前 luci-app-store 缺少 APK 软件仓库支持" >&2
        return 1
    fi

    if [ ! -f "$compat_repo_path" ]; then
        echo "错误：当前 luci-app-store 缺少 APK 兼容仓库配置" >&2
        return 1
    fi
}


fix_emmc_health_luci_js_deps() {
    local package_dir="$1"
    local makefile_path="$package_dir/Makefile"

    if [ ! -f "$makefile_path" ]; then
        echo "错误：luci-app-emmc-health Makefile 不存在：$makefile_path" >&2
        return 1
    fi

    if grep -q "luci-js-deps" "$makefile_path"; then
        sed -i '/^[[:space:]]*DEPENDS:=/ s/[[:space:]]*+luci-js-deps//g' "$makefile_path"
        echo "已移除 luci-app-emmc-health 的 luci-js-deps 兼容性依赖。"
    fi
}


fix_mini_diskmanager_menu() {
    local package_dir="$1"
    local menu_file="$package_dir/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"

    if [ ! -f "$menu_file" ]; then
        echo "错误：Mini Disk Manager 菜单文件不存在：$menu_file" >&2
        return 1
    fi

    sed -i 's#admin/services/mini-diskmanager#admin/system/mini-diskmanager#g' "$menu_file"
}


fix_daede_luci_host_depends() {
    local makefile_path="$1/Makefile"

    if [[ ! -f $makefile_path ]]; then
        echo "Error: luci-app-daede Makefile not found: $makefile_path" >&2
        return 1
    fi
    if grep -Eq '^PKG_BUILD_DEPENDS[[:space:]:+?]*=.*luci-base/host' "$makefile_path"; then
        return 0
    fi

    # The standalone package invokes po2lmo without including luci.mk.
    sed -i '/^include $(INCLUDE_DIR)\/package.mk$/i PKG_BUILD_DEPENDS+=luci-base/host' "$makefile_path"
    grep -Eq '^PKG_BUILD_DEPENDS[[:space:]:+?]*=.*luci-base/host' "$makefile_path"
}


fix_honk_luci_vendor_install() {
    # Upstream removed the vendor files but still installs the optional directory.
    python3 - "$1/Makefile" <<'PY'
import pathlib
import sys

makefile = pathlib.Path(sys.argv[1])
contents = makefile.read_text(encoding="utf-8")
source = "./htdocs/luci-static/resources/view/honk/vendor/*"
destination = "$(1)/www/luci-static/resources/view/honk/vendor"
for recipe in (
    f"$(INSTALL_DIR) {destination}",
    f"$(INSTALL_DATA) {source} {destination}/",
):
    contents = contents.replace(
        f"\t{recipe}\n",
        f"\t$(if $(wildcard {source}),{recipe})\n",
    )
makefile.write_text(contents, encoding="utf-8")
PY
}


sync_honk_packages_for_core_revision() {
    local target_dir="$1"
    local core_revision="$2"
    local tmp_dir
    local feed_revision
    local matching_revision=""

    tmp_dir=$(mktemp -d)
    if ! curl_retry -fsSL -o "$tmp_dir/release-assets.json" \
        https://api.github.com/repos/kenzok8/openwrt-honk/releases/tags/staging; then
        echo "Error: failed to fetch Honk release asset inventory" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    # Keep history to find a complete package pair for the published core.
    # The staging tag itself is old and does not track the generated assets.
    if ! git_retry clone --filter=blob:none --sparse --no-checkout \
        --single-branch -b main https://github.com/kenzok8/openwrt-honk.git "$tmp_dir/repo"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! git -C "$tmp_dir/repo" rev-list --first-parent HEAD > "$tmp_dir/revisions"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    while IFS= read -r feed_revision; do
        if git -C "$tmp_dir/repo" show "$feed_revision:honk/Makefile" 2>/dev/null | \
            grep -Fxq "CORE_COMMIT:=$core_revision"; then
            if ! git -C "$tmp_dir/repo" show "$feed_revision:luci-app-honk/Makefile" \
                > "$tmp_dir/luci.mk" 2>/dev/null; then
                continue
            fi
            # Rolling releases can also lag behind the pinned Doona UI archive.
            if python3 - "$tmp_dir/luci.mk" "$tmp_dir/release-assets.json" <<'PY'
import json
import pathlib
import re
import sys

makefile = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
release = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
source = re.search(r"^PKG_SOURCE:=(doona-[A-Za-z0-9_.-]+\.tar\.gz)$", makefile, re.MULTILINE)
sha256 = re.search(r"^PKG_HASH:=([0-9a-f]{64})$", makefile, re.MULTILINE)
url = re.search(
    r"^PKG_SOURCE_URL:=https://github\.com/kenzok8/openwrt-honk/releases/download/staging/?$",
    makefile, re.MULTILINE,
)
if source is None or sha256 is None or url is None:
    raise SystemExit(1)
for asset in release.get("assets", []):
    if asset.get("name") == source[1] and asset.get("state") == "uploaded":
        digest = asset.get("digest")
        if digest is None or digest == f"sha256:{sha256[1]}":
            raise SystemExit(0)
raise SystemExit(1)
PY
            then
                matching_revision="$feed_revision"
                break
            fi
        fi
    done < "$tmp_dir/revisions"

    if [[ -z $matching_revision ]]; then
        echo "Error: no Honk package snapshot matches published core $core_revision and available Doona assets" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! git_retry -C "$tmp_dir/repo" sparse-checkout set honk luci-app-honk || \
       ! git_retry -C "$tmp_dir/repo" checkout --detach "$matching_revision"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ ! -f $tmp_dir/repo/honk/Makefile || ! -f $tmp_dir/repo/luci-app-honk/Makefile ]]; then
        echo "Error: matching Honk snapshot lacks the required package pair" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$target_dir"
    mv "$tmp_dir/repo/honk" "$tmp_dir/repo/luci-app-honk" "$target_dir/" || {
        rm -rf "$tmp_dir"
        return 1
    }
    rm -rf "$tmp_dir"
    echo "Honk package snapshot: $matching_revision (core $core_revision)"
}


validate_honk_release_metadata() {
    python3 - "$1" "$2" <<'PY'
import json
import pathlib
import re
import sys

package_dir = pathlib.Path(sys.argv[1])
metadata_dir = pathlib.Path(sys.argv[2])
makefile = (package_dir / "Makefile").read_text(encoding="utf-8")
revision = re.search(r"^CORE_COMMIT:=([0-9a-f]{40})\s*$", makefile, re.MULTILINE)
if revision is None:
    raise SystemExit("Error: Honk Makefile has no pinned CORE_COMMIT")
revision = revision[1]

provenance = json.loads((metadata_dir / "generated-provenance.json").read_text(encoding="utf-8"))
core = provenance.get("core") if isinstance(provenance, dict) else None
release_revision = core.get("commit") if isinstance(core, dict) else None
if not isinstance(release_revision, str) or not re.fullmatch(r"[0-9a-f]{40}", release_revision):
    raise SystemExit("Error: Honk release provenance has no valid core commit")

stage = (metadata_dir / "generated-stage.mk").read_text(encoding="utf-8")
assignments = {}
for line in stage.splitlines():
    if not line.strip() or line.startswith("#"):
        continue
    # Newer upstream builders include the asset download URL in this manifest.
    if re.fullmatch(
        r"PKG_SOURCE_URL:=https://github\.com/kenzok8/openwrt-honk/releases/download/[A-Za-z0-9_.-]+/?",
        line,
    ) and "PKG_SOURCE_URL" not in assignments:
        assignments["PKG_SOURCE_URL"] = line.split(":=", 1)[1]
        continue
    match = re.fullmatch(r"(HONK_(?:ASSET|HASH)_(?:X86_64|AARCH64|ARMV7)):=(\S+)", line)
    if match is None or match[1] in assignments:
        raise SystemExit("Error: invalid Honk release stage manifest")
    assignments[match[1]] = match[2]

for arch, suffix in (("X86_64", "x86_64"), ("AARCH64", "aarch64"), ("ARMV7", "armv7")):
    if assignments.get(f"HONK_ASSET_{arch}") != f"honk-core-{release_revision}-{suffix}.tar.gz":
        raise SystemExit(f"Error: Honk {arch} release provenance does not match CORE_COMMIT")
    if not re.fullmatch(r"[0-9a-f]{64}", assignments.get(f"HONK_HASH_{arch}", "")):
        raise SystemExit(f"Error: Honk {arch} release has no valid SHA256")

(metadata_dir / "core-revision").write_text(release_revision, encoding="ascii")
if release_revision != revision:
    print(f"Honk source core {revision} differs from published core {release_revision}", file=sys.stderr)
    raise SystemExit(3)
PY
}


prepare_honk_release() {
    local package_dir="$1"
    local release_url="https://github.com/kenzok8/openwrt-honk/releases/download/staging"
    local tmp_dir
    local filename
    local validation_status

    tmp_dir=$(mktemp -d)
    # These generated build inputs are published as release assets, not in Git.
    for filename in generated-stage.mk generated-provenance.json; do
        if ! curl_retry -fsSL -o "$tmp_dir/$filename" "$release_url/$filename"; then
            echo "Error: failed to fetch Honk release metadata: $filename" >&2
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    if validate_honk_release_metadata "$package_dir" "$tmp_dir"; then
        validation_status=0
    else
        validation_status=$?
    fi
    if [[ $validation_status == 3 ]]; then
        echo "Honk main is ahead of the release; synchronizing packages for the published core..."
        if ! sync_honk_packages_for_core_revision "$tmp_dir/feed" "$(cat "$tmp_dir/core-revision")" || \
           ! validate_honk_release_metadata "$tmp_dir/feed/honk" "$tmp_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        for filename in generated-stage.mk generated-provenance.json; do
            cp "$tmp_dir/$filename" "$tmp_dir/feed/honk/$filename" || {
                rm -rf "$tmp_dir"
                return 1
            }
        done
        rm -rf "$package_dir" "$(dirname "$package_dir")/luci-app-honk"
        if ! mv "$tmp_dir/feed/honk" "$package_dir" || \
           ! mv "$tmp_dir/feed/luci-app-honk" "$(dirname "$package_dir")/luci-app-honk"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    elif [[ $validation_status != 0 ]]; then
        rm -rf "$tmp_dir"
        return 1
    elif ! cp "$tmp_dir/generated-stage.mk" "$tmp_dir/generated-provenance.json" "$package_dir/"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}


register_local_feed_source() {
    local custom_feed_dir="$1"
    local feeds_path="$2"
    local feed_name
    feed_name=$(get_custom_feed_name)

    sed -i "/[[:space:]]$feed_name[[:space:]]/d" "$feeds_path"
    [ -z "$(tail -c 1 "$feeds_path")" ] || echo "" >>"$feeds_path"
    echo "src-link $feed_name $custom_feed_dir" >>"$feeds_path"
    echo "已将 $feed_name 作为本地源 (src-link) 添加到 $feeds_path"
}


install_custom_feed() {
    local feeds_path
    local fullconenat_nft_dir="$BUILD_DIR/package/network/utils/fullconenat-nft"
    local fullconenat_dir="$BUILD_DIR/package/network/utils/fullconenat"
    local fullconenat_sonic_dir="$BUILD_DIR/package/network/utils/fullconenat-sonic"
    local custom_feed_dir
    local custom_feed_worktree_dir
    local custom_feed_name
    local argon_makefile

    local base_custom_feed_packages=(
        xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata geoview v2ray-plugin geo2txt \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        v2dat adguardhome luci-app-adguardhome ddns-go \
        luci-app-ddns-go quickstart \
        luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest netdata luci-app-netdata \
        lucky luci-app-lucky luci-app-openclash luci-app-homeproxy luci-app-amlogic \
        oaf open-app-filter luci-app-oaf easytier luci-app-easytier \
        msd_lite luci-app-msd_lite cups luci-app-cupsd
    )
    local required_feed_dirs=(
        cups tcping v2ray-geodata taskd luci-lib-xterm luci-lib-taskd luci-app-store
        luci-app-openclash
        luci-app-quickstart luci-app-homeproxy luci-app-mosdns geo2txt
        luci-app-passwall nikki luci-app-nikki mihomo-meta
        open-app-filter luci-app-oaf lucky luci-app-lucky luci-app-easytier
        luci-app-upnp miniupnpd
        luci-app-emmc-health luci-app-wolultra luci-app-mini-diskmanager
        axonhub luci-app-axonhub gecoosac luci-app-gecoosac sing-box
        luci-app-tingreader luci-app-velo5x0-fan
    )
    local custom_feed_sources=()
    local missing_feed_dirs=()
    local source_entry
    local repo_label
    local repo_url
    local repo_branch
    local repo_packages
    local repo_package_array=()

    # Trees with fullconenat-sonic (owrt >= 6af6d3945c) embed fullcone into
    # nf_nat/xt_MASQUERADE and ship no standalone fullconenat packages;
    # never fall back to the legacy custom_feed builds there.
    if [ ! -d "$fullconenat_nft_dir" ] && [ ! -d "$fullconenat_sonic_dir" ]; then
        base_custom_feed_packages+=(fullconenat-nft)
    fi
    if [ ! -d "$fullconenat_dir" ] && [ ! -d "$fullconenat_sonic_dir" ]; then
        base_custom_feed_packages+=(fullconenat)
    fi
    if supports_ucode_luci_themes; then
        required_feed_dirs+=(
            luci-theme-argon luci-app-argon-config
            luci-theme-aurora luci-app-aurora-config
        )
    fi

    # 统一从外部仓库同步指定包，避免分散维护 feeds.conf。
    custom_feed_sources=(
        "kenzok8/small-package|https://github.com/kenzok8/small-package.git||${base_custom_feed_packages[*]}"
        "linkease/istore|https://github.com/linkease/istore.git|main|luci/taskd luci/luci-lib-xterm luci/luci-lib-taskd luci/luci-app-store"
        "4IceG/luci-app-mini-diskmanager|https://github.com/4IceG/luci-app-mini-diskmanager.git|main|luci-app-mini-diskmanager"
        "sbwml/luci-app-mosdns|https://github.com/sbwml/luci-app-mosdns.git|v5|mosdns luci-app-mosdns"
        "Openwrt-Passwall/openwrt-passwall|https://github.com/Openwrt-Passwall/openwrt-passwall.git|main|luci-app-passwall"
        "nikkinikki-org/OpenWrt-nikki|https://github.com/nikkinikki-org/OpenWrt-nikki.git|main|nikki luci-app-nikki mihomo-meta"
    )

    if [[ ${DAED_PACKAGES_ENABLED:-0} == "1" ]]; then
        # Keep sibling directories: luci-app-daede installs defaults from ../dae and ../daed.
        custom_feed_sources+=(
            "kenzok8/openwrt-daede|https://github.com/kenzok8/openwrt-daede.git|main|dae daed luci-app-daede vmlinux-btf"
        )
        required_feed_dirs+=(dae daed luci-app-daede vmlinux-btf)
    fi

    if [[ ${HONK_PACKAGES_ENABLED:-0} == "1" ]]; then
        custom_feed_sources+=(
            "kenzok8/openwrt-honk|https://github.com/kenzok8/openwrt-honk.git|main|honk luci-app-honk"
            "kenzok8/wall|https://github.com/kenzok8/wall.git|main|v2ray-geodata"
        )
        required_feed_dirs+=(honk luci-app-honk)
    fi

    feeds_path=$(get_feeds_path)
    custom_feed_name=$(get_custom_feed_name)
    custom_feed_dir=$(get_custom_feed_source_dir)
    custom_feed_worktree_dir=$(get_custom_feed_worktree_dir)

    if [ -d "$custom_feed_dir" ]; then
        echo "清理旧的自定义 feed 目录..."
        rm -rf "$custom_feed_dir"
    fi
    mkdir -p "$custom_feed_dir"

    # 只同步配置仍在使用的 VIKINGYFY 包；UPnP 前端和 miniupnpd 后端保持版本配套。
    if ! sync_sparse_packages_to_feed_dir \
        "https://github.com/VIKINGYFY/packages.git" "main" \
        "$custom_feed_dir" "VIKINGYFY/packages (selected)" \
        axonhub luci-app-axonhub gecoosac luci-app-gecoosac \
        luci-app-wolultra luci-app-upnp miniupnpd; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if supports_ucode_luci_themes; then
        if ! sync_sparse_packages_to_feed_dir \
            "https://github.com/sbwml/luci-theme-argon.git" "openwrt-25.12" \
            "$custom_feed_dir" "sbwml/luci-theme-argon" \
            luci-theme-argon luci-app-argon-config; then
            rm -rf "$custom_feed_dir"
            return 1
        fi

        if ! sync_repo_root_package_to_feed_dir \
            "https://github.com/eamonxg/luci-theme-aurora.git" "master" \
            "$custom_feed_dir" "eamonxg/luci-theme-aurora" "luci-theme-aurora"; then
            rm -rf "$custom_feed_dir"
            return 1
        fi

        if ! sync_repo_root_package_to_feed_dir \
            "https://github.com/eamonxg/luci-app-aurora-config.git" "master" \
            "$custom_feed_dir" "eamonxg/luci-app-aurora-config" "luci-app-aurora-config"; then
            rm -rf "$custom_feed_dir"
            return 1
        fi

        argon_makefile="$custom_feed_dir/luci-theme-argon/Makefile"
        if [ ! -f "$argon_makefile" ]; then
            echo "错误：Argon 主题 Makefile 不存在：$argon_makefile" >&2
            rm -rf "$custom_feed_dir"
            return 1
        fi
        if ! grep -Eq '^LUCI_DEPENDS:=.*\+ucode-mod-math([[:space:]]|$)' "$argon_makefile"; then
            sed -i '/^LUCI_DEPENDS:=/ s/$/ +ucode-mod-math/' "$argon_makefile"
        fi
        if ! grep -Eq '^LUCI_DEPENDS:=.*\+ucode-mod-math([[:space:]]|$)' "$argon_makefile"; then
            echo "错误：无法为 Argon 主题添加 ucode-mod-math 运行时依赖" >&2
            rm -rf "$custom_feed_dir"
            return 1
        fi
    else
        echo "当前 LuCI 不支持 ucode 主题模板，保留上游主题源码。"
    fi

    for source_entry in "${custom_feed_sources[@]}"; do
        IFS='|' read -r repo_label repo_url repo_branch repo_packages <<< "$source_entry"
        read -r -a repo_package_array <<< "$repo_packages"

        if ! sync_sparse_packages_to_feed_dir "$repo_url" "$repo_branch" "$custom_feed_dir" "$repo_label" "${repo_package_array[@]}"; then
            rm -rf "$custom_feed_dir"
            return 1
        fi
    done

    if [[ ${DAED_PACKAGES_ENABLED:-0} == "1" ]]; then
        fix_daede_luci_host_depends "$custom_feed_dir/luci-app-daede" || return 1
    fi
    if [[ ${HONK_PACKAGES_ENABLED:-0} == "1" ]]; then
        prepare_honk_release "$custom_feed_dir/honk" || return 1
        fix_honk_luci_vendor_install "$custom_feed_dir/luci-app-honk" || return 1
    fi

    if ! verify_istore_apk_support "$custom_feed_dir/luci-app-store"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if ! fix_mini_diskmanager_menu "$custom_feed_dir/luci-app-mini-diskmanager"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if ! sync_repo_root_package_to_feed_dir "https://github.com/adminchenyu/eMMC-Health.git" "main" "$custom_feed_dir" "adminchenyu/eMMC-Health" "luci-app-emmc-health"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if ! fix_emmc_health_luci_js_deps "$custom_feed_dir/luci-app-emmc-health"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if ! sync_tingreader_packages_to_feed_dir \
        "https://github.com/dqsq2e2/luci-app-tingreader.git" "main" \
        "$custom_feed_dir" "dqsq2e2/luci-app-tingreader"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    if ! sync_repo_root_package_to_feed_dir \
        "https://github.com/dqsq2e2/luci-app-velo5x0-fan.git" "main" \
        "$custom_feed_dir" "dqsq2e2/luci-app-velo5x0-fan" "luci-app-velo5x0-fan"; then
        rm -rf "$custom_feed_dir"
        return 1
    fi

    register_local_feed_source "$custom_feed_dir" "$feeds_path"

    echo "正在更新 $custom_feed_name 本地 feed 索引..."
    network_retry ./scripts/feeds update "$custom_feed_name"

    collect_missing_directories "$custom_feed_worktree_dir" required_feed_dirs missing_feed_dirs

    if [ ${#missing_feed_dirs[@]} -ne 0 ]; then
        printf '错误：%s 本地 feed 未生成以下仓库依赖路径：\n' "$custom_feed_name" >&2
        printf '  - %s\n' "${missing_feed_dirs[@]}" >&2
        return 1
    fi

    echo "$custom_feed_name 指定包处理完成并已成功加载到 feeds 体系中！"
}


collect_missing_directories() {
    local base_dir="$1"
    local -n required_dirs_ref="$2"
    local -n missing_dirs_ref="$3"
    local dir_name

    for dir_name in "${required_dirs_ref[@]}"; do
        if [ ! -d "$base_dir/$dir_name" ]; then
            missing_dirs_ref+=("${base_dir#$BUILD_DIR/}/$dir_name")
        fi
    done
}
