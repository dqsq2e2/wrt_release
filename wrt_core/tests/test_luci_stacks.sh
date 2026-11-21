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
    elif grep -Eq '^CONFIG_PACKAGE_(luci-theme-(vantage|argon|aurora)|luci-app-quickstart|luci-app-netwiz)=y$' "$tmp/config"; then
        echo 'FAIL: optional stack packages are in the common config' >&2
        exit 1
    fi
    verify_luci_stack_config "$tmp/config" "$stack"
done
echo 'PASS: selected stacks provide the required themes and packages'

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
