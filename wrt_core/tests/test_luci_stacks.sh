#!/usr/bin/env bash
set -euo pipefail

base=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$base/.." && pwd)
source <(sed 's/\r$//' "$base/modules/luci_stacks.sh")
source <(sed 's/\r$//' "$base/modules/verify.sh")

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
preview() {
    (cd "$repo" && bash <(sed 's/\r$//' build.sh) S20-WIFI-NO config_preview)
}

preview > "$tmp/istore"
grep -qx '  LuCI stack: istore' "$tmp/istore"
ADD_CONFIG_FRAGMENTS=vantage REMOVE_CONFIG_FRAGMENTS=istore preview > "$tmp/vantage"
grep -qx '  Effective fragments: docker_deps,honk,vantage' "$tmp/vantage"
grep -qx '  LuCI stack: vantage' "$tmp/vantage"
REMOVE_CONFIG_FRAGMENTS=istore preview > "$tmp/none"
grep -qx '  LuCI stack: none' "$tmp/none"
if ADD_CONFIG_FRAGMENTS=vantage preview > "$tmp/conflict" 2>&1; then
    echo 'FAIL: both LuCI stacks were accepted' >&2
    exit 1
fi
grep -Fq 'istore and vantage are mutually exclusive' "$tmp/conflict"
echo 'PASS: default, switch, opt out and conflict'

for stack in istore vantage none; do
    sed 's/\r$//' "$base/deconfig/compile_base.config" > "$tmp/config"
    if [[ $stack != none ]]; then
        sed 's/\r$//' "$base/deconfig/fragments/$stack.config" >> "$tmp/config"
        grep -qx 'CONFIG_PACKAGE_luci-app-aurora-config=y' "$tmp/config"
    elif grep -Eq '^CONFIG_PACKAGE_(luci-theme-(vantage|argon|aurora)|luci-app-quickstart(-network)?|quickstart|luci-app-netwiz)=y$' "$tmp/config"; then
        echo 'FAIL: optional stack packages are in the common config' >&2
        exit 1
    fi
    verify_luci_stack_config "$tmp/config" "$stack"
done
echo 'PASS: selected stacks provide the required themes and packages'

# Run the real build entry through its post-defconfig checks.
project="$tmp/project"
mkdir -p "$project/wrt_core/modules" "$tmp/bin"
cp -a "$base/compilecfg" "$base/deconfig" "$project/wrt_core/"
sed 's/\r$//' "$repo/build.sh" > "$project/build.sh"
sed 's/\r$//' "$base/modules/verify.sh" > "$project/wrt_core/modules/verify.sh"
cat > "$project/wrt_core/update.sh" <<'SH'
#!/usr/bin/env bash
set -eu
mkdir -p "$3/feeds/luci/modules/luci-base/ucode"
printf '%s\n' "$LUCI_STACK" > "$3/stack"
SH
cat > "$tmp/bin/make" <<'SH'
#!/usr/bin/env bash
set -eu
[[ $1 == defconfig ]]
sed -i 's/\r$//' .config
printf '\nCONFIG_PACKAGE_openwrt-keyring=y\n' >> .config
if [[ -n ${DROP_PACKAGE:-} ]]; then
    sed -i "/^CONFIG_PACKAGE_$DROP_PACKAGE=y$/d" .config
fi
if [[ -n ${ADD_PACKAGE:-} ]]; then
    printf 'CONFIG_PACKAGE_%s=y\n' "$ADD_PACKAGE" >> .config
fi
SH
chmod +x "$project/wrt_core/update.sh" "$tmp/bin/make"

debug_build() {
    (cd "$project" && PATH="$tmp/bin:$PATH" bash build.sh MEDIATEK-WIFI-NO debug)
}

debug_build > "$tmp/debug-default"
grep -qx istore "$project/owrt/stack"
grep -qx CONFIG_PACKAGE_luci-app-store=y "$project/owrt/.config"
grep -qx CONFIG_PACKAGE_luci-app-quickstart=y "$project/owrt/.config"
ADD_CONFIG_FRAGMENTS=vantage REMOVE_CONFIG_FRAGMENTS=istore debug_build > "$tmp/debug-vantage"
grep -qx vantage "$project/owrt/stack"
grep -qx CONFIG_PACKAGE_luci-app-store=y "$project/owrt/.config"
grep -qx CONFIG_PACKAGE_luci-app-quickstart-network=y "$project/owrt/.config"
if grep -Eq '^CONFIG_PACKAGE_(quickstart|luci-app-quickstart|luci-app-netwiz|luci-theme-argon)=y$' "$project/owrt/.config"; then
    echo 'FAIL: Vantage build includes the full QuickStart or NetWiz' >&2
    exit 1
fi
REMOVE_CONFIG_FRAGMENTS=istore debug_build > "$tmp/debug-none"
grep -qx none "$project/owrt/stack"
grep -qx CONFIG_PACKAGE_luci-app-store=y "$project/owrt/.config"

for package in luci-theme-vantage luci-app-quickstart-network luci-app-store apk-openssl; do
    if ADD_CONFIG_FRAGMENTS=vantage REMOVE_CONFIG_FRAGMENTS=istore DROP_PACKAGE="$package" \
        debug_build > "$tmp/debug-missing" 2>&1; then
        echo "FAIL: build accepted a config without $package" >&2
        exit 1
    fi
    grep -Fq -- "$package" "$tmp/debug-missing"
done
for package in quickstart luci-app-quickstart luci-app-netwiz; do
    if ADD_CONFIG_FRAGMENTS=vantage REMOVE_CONFIG_FRAGMENTS=istore ADD_PACKAGE="$package" \
        debug_build > "$tmp/debug-extra" 2>&1; then
        echo "FAIL: Vantage build accepted $package" >&2
        exit 1
    fi
    grep -Fq -- "cannot include $package" "$tmp/debug-extra"
done
echo 'PASS: debug builds validate each theme stack and APK independently'

assets="$tmp/quickstart/htdocs/luci-static/quickstart"
view="$tmp/quickstart/luasrc/view/quickstart"
mkdir -p "$assets" "$view"
printf '%s\n' '<script src="/luci-static/quickstart/index.js?v=<%=asset_version%>"></script>' > "$view/main.htm"
printf '%s\n' 'const tile={href:"/cgi-bin/luci/admin/system/diskman"}' > "$assets/index.js"
fix_quickstart_assets "$tmp/quickstart"
grep -Fq '/admin/system/mini-diskmanager' "$assets/index.js"

printf '%s\n' 'import{}from"./app.js?v=original";' > "$assets/index.js"
printf '%s\n' 'const a="/cgi-bin/luci/admin/system/diskman",b="/admin/services/appfilter";if(s.linkState=="DOWN"){}' > "$assets/app.js"
fix_quickstart_assets "$tmp/quickstart"
fix_quickstart_assets "$tmp/quickstart"
grep -Fq './app.js?v=wrt-1-original' "$assets/index.js"
grep -Fq '/admin/system/mini-diskmanager' "$assets/app.js"
grep -Fq '/admin/services/oaf' "$assets/app.js"
grep -Fq 'linkState!="UP"' "$assets/app.js"
grep -Fq 'index.js?v=wrt-1-<%=asset_version%>' "$view/main.htm"
if fix_quickstart_assets "$tmp/unknown-layout" > "$tmp/missing" 2>&1; then
    echo 'FAIL: missing QuickStart assets were accepted' >&2
    exit 1
fi
echo 'PASS: legacy and split QuickStart assets, cache busting and missing route detection'

defaults="$tmp/aurora/root/etc/uci-defaults"
mkdir -p "$defaults"
printf '%s\n' 'set luci.themes.Aurora=/luci-static/aurora' \
    'set luci.main.mediaurlbase=/luci-static/aurora' > "$defaults/30_luci-theme-aurora"
keep_aurora_standby "$tmp/aurora"
grep -qx 'set luci.themes.Aurora=/luci-static/aurora' "$defaults/30_luci-theme-aurora"
if grep -q 'luci.main.mediaurlbase' "$defaults/30_luci-theme-aurora"; then
    echo 'FAIL: Aurora still becomes the default theme' >&2
    exit 1
fi
echo 'PASS: Aurora registers without replacing the active theme'
