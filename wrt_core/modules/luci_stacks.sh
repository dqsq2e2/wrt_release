#!/usr/bin/env bash

fix_quickstart_assets() {
    local package_dir="$1"
    local assets="$package_dir/htdocs/luci-static/quickstart"
    local route='admin/system/diskman([^[:alnum:]_-]|$)'
    local fixed_route='admin/system/mini-diskmanager([^[:alnum:]_-]|$)'
    local asset
    local found=0
    local view="$package_dir/luasrc/view/quickstart/main.htm"

    # index.js is the entry point; newer builds split the home cards into app.js.
    for asset in "$assets"/*.js; do
        [[ -f $asset ]] || continue
        if grep -qE "$route|$fixed_route" "$asset"; then
            found=1
        fi
        if grep -qE "$route|admin/services/appfilter|linkState==\"DOWN\"" "$asset"; then
            sed -Ei \
                -e "s#$route#admin/system/mini-diskmanager\1#g" \
                -e 's|admin/services/appfilter|admin/services/oaf|g' \
                -e 's/linkState=="DOWN"/linkState!="UP"/g' \
                "$asset" || return 1
        fi
    done
    if [[ $found != 1 ]] || grep -qE "$route" "$assets"/*.js; then
        echo "Error: cannot verify the QuickStart disk manager route in $assets." >&2
        return 1
    fi

    # Keep the browser from reusing the unpatched bundles after a sysupgrade.
    if [[ -f "$assets/index.js" ]] && ! grep -Fq 'app.js?v=wrt-1-' "$assets/index.js"; then
        sed -i 's|app\.js?v=|app.js?v=wrt-1-|g' "$assets/index.js" || return 1
    fi
    if [[ -f $view ]]; then
        sed -i 's|index\.js?v=<%=asset_version%>|index.js?v=wrt-1-<%=asset_version%>|g' "$view" || return 1
    fi
    echo "QuickStart disk manager route: /cgi-bin/luci/admin/system/mini-diskmanager"
}

keep_aurora_standby() {
    local defaults="$1/root/etc/uci-defaults/30_luci-theme-aurora"

    if [[ ! -f $defaults ]] || ! grep -qF 'set luci.themes.Aurora=/luci-static/aurora' "$defaults"; then
        echo "Error: cannot verify Aurora theme registration in $defaults." >&2
        return 1
    fi
    sed -i '/^[[:space:]]*set luci\.main\.mediaurlbase=\/luci-static\/aurora[[:space:]]*$/d' "$defaults"
}

prepare_vantage_stack() {
    local feed theme netwiz file
    feed=$(get_custom_feed_worktree_dir)
    theme="$feed/luci-theme-vantage"
    netwiz="$feed/luci-app-netwiz"

    if [[ ! -f "$theme/htdocs/luci-static/vantage/vantage.css" ||
          ! -d "$theme/ucode/template/themes/vantage" ]]; then
        echo "Error: Vantage theme is missing its runtime assets." >&2
        return 1
    fi

    # NetWiz stages these files from root/ with the source modes.
    for file in \
        usr/libexec/rpcd/netwiz usr/libexec/rpcd/netwiz_dev \
        usr/libexec/netwiz-autodetect.sh usr/libexec/netwiz-monitor-loop.sh \
        etc/init.d/netwiz-monitor etc/init.d/netwiz-recovery \
        etc/init.d/netwiz-watchdog etc/hotplug.d/dhcp/99-netwiz-guard; do
        if ! chmod 755 "$netwiz/root/$file"; then
            echo "Error: cannot make NetWiz script executable: $file" >&2
            return 1
        fi
    done
}
