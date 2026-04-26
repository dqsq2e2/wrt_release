#!/usr/bin/env bash

fix_default_set() {
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
    fi

    install -Dm544 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
    install -Dm544 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"
    install -Dm544 "$BASE_PATH/patches/992_set-wifi-uci.sh" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/992_set-wifi-uci.sh"

    if [ -f "$BUILD_DIR/package/emortal/autocore/files/tempinfo" ]; then
        if [ -f "$BASE_PATH/patches/tempinfo" ]; then
            \cp -f "$BASE_PATH/patches/tempinfo" "$BUILD_DIR/package/emortal/autocore/files/tempinfo"
        fi
    fi
}

fix_miniupnpd() {
    local miniupnpd_dir="$BUILD_DIR/feeds/packages/net/miniupnpd"
    local patch_file="999-chanage-default-leaseduration.patch"

    if [ -d "$miniupnpd_dir" ] && [ -f "$BASE_PATH/patches/$patch_file" ]; then
        install -Dm644 "$BASE_PATH/patches/$patch_file" "$miniupnpd_dir/patches/$patch_file"
    fi
}

change_dnsmasq2full() {
    if ! grep -q "dnsmasq-full" $BUILD_DIR/include/target.mk; then
        sed -i 's/dnsmasq/dnsmasq-full/g' ./include/target.mk
    fi
}

fix_mk_def_depends() {
    sed -i 's/libustream-mbedtls/libustream-openssl/g' $BUILD_DIR/include/target.mk 2>/dev/null
    if [ -f $BUILD_DIR/target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' $BUILD_DIR/target/linux/qualcommax/Makefile
    fi
}

fix_kconfig_recursive_dependency() {
    local file="$BUILD_DIR/scripts/package-metadata.pl"
    if [ -f "$file" ]; then
        sed -i 's/<PACKAGE_\$pkgname/!=y/g' "$file"
        echo "已修复 package-metadata.pl 的 Kconfig 递归依赖生成逻辑。"
    fi
}

remove_wifi_menu() {
    # 检查配置文件中是否禁用了 WiFi
    # 如果配置中有 CONFIG_PACKAGE_hostapd-common=n 或 CONFIG_PACKAGE_wpad-*=n，说明禁用了 WiFi
    local config_file=".config"
    
    # 如果在 update.sh 中调用，需要使用完整路径
    if [ ! -f "$config_file" ] && [ -n "$BUILD_DIR" ]; then
        config_file="$BUILD_DIR/.config"
    fi
    
    # 如果 .config 还不存在，跳过
    if [ ! -f "$config_file" ]; then
        echo "跳过 WiFi 菜单移除（配置文件尚未生成）"
        return 0
    fi
    
    echo "=========================================="
    echo "调试：检查 WiFi 配置状态"
    echo "配置文件路径: $config_file"
    echo "=========================================="
    
    # 显示相关配置行
    echo "hostapd-common 配置:"
    grep "CONFIG_PACKAGE_hostapd-common" "$config_file" || echo "  未找到 hostapd-common 配置"
    
    echo "iw 配置:"
    grep "CONFIG_PACKAGE_iw" "$config_file" || echo "  未找到 iw 配置"
    
    echo "iwinfo 配置:"
    grep "CONFIG_PACKAGE_iwinfo" "$config_file" || echo "  未找到 iwinfo 配置"
    
    echo "=========================================="
    
    # 检查是否禁用了 WiFi 包（使用更精确的匹配）
    # 只有当 hostapd-common 和 iw 都被禁用时，才认为 WiFi 被禁用
    # iwinfo 只是查询工具，不是 WiFi 驱动，不能作为判断依据
    local hostapd_disabled=0
    local iw_disabled=0
    
    if grep -q "^CONFIG_PACKAGE_hostapd-common=n" "$config_file" || \
       grep -q "^# CONFIG_PACKAGE_hostapd-common is not set" "$config_file"; then
        echo "✓ hostapd-common 已禁用"
        hostapd_disabled=1
    fi
    
    if grep -q "^CONFIG_PACKAGE_iw=n" "$config_file" || \
       grep -q "^# CONFIG_PACKAGE_iw is not set" "$config_file"; then
        echo "✓ iw 已禁用"
        iw_disabled=1
    fi
    
    # 只有当 hostapd-common 和 iw 都被禁用时，才移除 WiFi 界面
    if [ $hostapd_disabled -eq 1 ] && [ $iw_disabled -eq 1 ]; then
        echo "检测到 WiFi 已禁用（hostapd-common 和 iw 都被禁用），正在移除 WiFi 界面..."
    else
        echo "检测到 WiFi 已启用，保留 WiFi 界面"
        echo "  - hostapd-common: $([ $hostapd_disabled -eq 0 ] && echo '启用' || echo '禁用')"
        echo "  - iw: $([ $iw_disabled -eq 0 ] && echo '启用' || echo '禁用')"
        return 0
    fi
    
    # 安全地移除 WiFi 菜单项，不破坏其他网络配置
    local luci_network_menu="$BUILD_DIR/feeds/luci/modules/luci-mod-network/root/usr/share/luci/menu.d/luci-mod-network.json"
    
    # 如果当前已经在 BUILD_DIR 中，使用相对路径
    if [ ! -f "$luci_network_menu" ]; then
        luci_network_menu="feeds/luci/modules/luci-mod-network/root/usr/share/luci/menu.d/luci-mod-network.json"
    fi
    
    if [ -f "$luci_network_menu" ]; then
        echo "正在从 LuCI 菜单中移除 WiFi 选项..."
        
        # 备份原文件
        cp "$luci_network_menu" "$luci_network_menu.bak"
        
        # 使用 jq 或 sed 精确删除 wireless 相关条目
        # 只删除 wireless 菜单项，保留其他网络配置
        if command -v jq &> /dev/null; then
            # 使用 jq 精确删除
            jq 'del(.["admin/network/wireless"])' "$luci_network_menu" > "$luci_network_menu.tmp"
            mv "$luci_network_menu.tmp" "$luci_network_menu"
        else
            # 使用 sed 删除 wireless 相关的 JSON 块
            # 匹配从 "admin/network/wireless" 开始到对应的 } 结束
            sed -i '/"admin\/network\/wireless"/,/^[[:space:]]*},\?$/d' "$luci_network_menu"
        fi
        
        echo "已从 LuCI 菜单中移除 WiFi 选项"
    fi
    
    # 可选：创建一个 uci-defaults 脚本在运行时隐藏 WiFi 界面
    local uci_defaults_dir="package/base-files/files/etc/uci-defaults"
    if [ ! -d "$uci_defaults_dir" ] && [ -n "$BUILD_DIR" ]; then
        uci_defaults_dir="$BUILD_DIR/package/base-files/files/etc/uci-defaults"
    fi
    
    if [ -d "$uci_defaults_dir" ]; then
        cat > "$uci_defaults_dir/99-hide-wifi-menu" << 'EOF'
#!/bin/sh
# Hide WiFi menu in LuCI
uci -q batch << EOI
delete luci.main.wireless
commit luci
EOI
exit 0
EOF
        chmod +x "$uci_defaults_dir/99-hide-wifi-menu"
        echo "已创建运行时 WiFi 菜单隐藏脚本"
    fi
    
    # 添加 CSS 隐藏 WiFi 相关元素（额外保险）
    local custom_css_dir="package/base-files/files/www/luci-static"
    if [ ! -d "$custom_css_dir" ] && [ -n "$BUILD_DIR" ]; then
        custom_css_dir="$BUILD_DIR/package/base-files/files/www/luci-static"
    fi
    
    if [ ! -d "$custom_css_dir" ]; then
        mkdir -p "$custom_css_dir"
    fi
    
    cat > "$custom_css_dir/custom.css" << 'EOF'
/* Hide WiFi menu items */
[href*="wireless"],
[data-page*="wireless"],
.cbi-section-node[id*="wireless"] {
    display: none !important;
}
EOF
    echo "已添加 CSS 隐藏规则"
}

fix_natmap_makefile() {
    local natmap_makefile="$BUILD_DIR/feeds/small8/luci-app-natmap/Makefile"
    
    if [ -f "$natmap_makefile" ]; then
        echo "正在修复 luci-app-natmap Makefile..."
        
        # 修复 PKG_VERSION 和 PKG_RELEASE 格式
        sed -i 's/PKG_VERSION:=.*$/PKG_VERSION:=1.0.0/' "$natmap_makefile"
        sed -i 's/PKG_RELEASE:=.*$/PKG_RELEASE:=1/' "$natmap_makefile"
        
        # 如果没有 PKG_RELEASE，添加它
        if ! grep -q "PKG_RELEASE" "$natmap_makefile"; then
            sed -i '/PKG_VERSION/a PKG_RELEASE:=1' "$natmap_makefile"
        fi
        
        echo "已修复 luci-app-natmap Makefile"
    fi
}

fix_rstrip_script() {
    local rstrip_script="$BUILD_DIR/scripts/rstrip.sh"
    
    if [ -f "$rstrip_script" ]; then
        echo "正在修复 rstrip.sh 脚本..."
        
        # 备份原文件
        cp "$rstrip_script" "$rstrip_script.bak"
        
        # 修复：跳过 shared object 和 relocatable 文件
        sed -i '/file.*\$F.*grep.*ELF/a\
        # Skip shared objects and relocatable files\
        if file "$F" | grep -q "shared object\\|relocatable"; then\
            continue\
        fi' "$rstrip_script"
        
        echo "已修复 rstrip.sh 脚本"
    fi
}

update_default_lan_addr() {
    local CFG_PATH="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
    fi
}

remove_something_nss_kmod() {
    local ipq_mk_path="$BUILD_DIR/target/linux/qualcommax/Makefile"
    local target_mks=("$BUILD_DIR/target/linux/qualcommax/ipq60xx/target.mk" "$BUILD_DIR/target/linux/qualcommax/ipq807x/target.mk")

    for target_mk in "${target_mks[@]}"; do
        if [ -f "$target_mk" ]; then
            sed -i 's/kmod-qca-nss-crypto//g' "$target_mk"
        fi
    done

    if [ -f "$ipq_mk_path" ]; then
        sed -i '/kmod-qca-nss-drv-eogremgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-gre/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-map-t/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-match/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-mirror/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tun6rd/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tunipip6/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-vxlanmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-wifi-meshmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-macsec/d' "$ipq_mk_path"

        sed -i 's/automount //g' "$ipq_mk_path"
        sed -i 's/cpufreq //g' "$ipq_mk_path"
    fi
}

update_affinity_script() {
    local affinity_script_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$affinity_script_dir" ]; then
        find "$affinity_script_dir" -name "set-irq-affinity" -exec rm -f {} \;
        find "$affinity_script_dir" -name "smp_affinity" -exec rm -f {} \;
        install -Dm755 "$BASE_PATH/patches/smp_affinity" "$affinity_script_dir/base-files/etc/init.d/smp_affinity"
    fi
}

fix_hash_value() {
    local makefile_path="$1"
    local old_hash="$2"
    local new_hash="$3"
    local package_name="$4"

    if [ -f "$makefile_path" ]; then
        sed -i "s/$old_hash/$new_hash/g" "$makefile_path"
        echo "已修正 $package_name 的哈希值。"
    fi
}

apply_hash_fixes() {
    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "860a816bf1e69d5a8a2049483197dbebe8a3da2c9b05b2da68c85ef7dee7bdde" \
        "582021891808442b01f551bc41d7d95c38fb00c1ec78a58ac3aaaf898fbd2b5b" \
        "smartdns"

    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "320c99a65ca67a98d11a45292aa99b8904b5ebae5b0e17b302932076bf62b1ec" \
        "43e58467690476a77ce644f9dc246e8a481353160644203a1bd01eb09c881275" \
        "smartdns"
}

update_ath11k_fw() {
    local makefile="$BUILD_DIR/package/firmware/ath11k-firmware/Makefile"
    local new_mk="$BASE_PATH/patches/ath11k_fw.mk"
    local url="https://raw.githubusercontent.com/VIKINGYFY/immortalwrt/refs/heads/main/package/firmware/ath11k-firmware/Makefile"

    if [ -d "$(dirname "$makefile")" ]; then
        echo "正在更新 ath11k-firmware Makefile..."
        if ! curl -fsSL -o "$new_mk" "$url" 2>/dev/null; then
            echo "警告：从 $url 下载 ath11k-firmware Makefile 失败（网络问题）" >&2
            echo "跳过 ath11k-firmware 更新，使用原始文件继续编译"
            return 0
        fi
        if [ ! -s "$new_mk" ]; then
            echo "警告：下载的 ath11k-firmware Makefile 为空文件" >&2
            echo "跳过 ath11k-firmware 更新，使用原始文件继续编译"
            rm -f "$new_mk"
            return 0
        fi
        mv -f "$new_mk" "$makefile"
        echo "ath11k-firmware Makefile 更新成功"
    fi
}

fix_mkpkg_format_invalid() {
    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-lib-taskd/Makefile ]; then
            sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' $BUILD_DIR/feeds/small8/luci-lib-taskd/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-openclash/Makefile ]; then
            sed -i 's/PKG_RELEASE:=beta/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-openclash/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile ]; then
            sed -i 's/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g' $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-store/Makefile ]; then
            sed -i 's/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g' $BUILD_DIR/feeds/small8/luci-app-store/Makefile
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-store/Makefile
        fi
    fi
}

change_cpuusage() {
    local luci_rpc_path="$BUILD_DIR/feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
    local qualcommax_sbin_dir="$BUILD_DIR/target/linux/qualcommax/base-files/sbin"
    local filogic_sbin_dir="$BUILD_DIR/target/linux/mediatek/filogic/base-files/sbin"

    if [ -f "$luci_rpc_path" ]; then
        sed -i "s#const fd = popen('top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\'')#const cpuUsageCommand = access('/sbin/cpuusage') ? '/sbin/cpuusage' : 'top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\''#g" "$luci_rpc_path"
        sed -i '/cpuUsageCommand/a \\t\t\tconst fd = popen(cpuUsageCommand);' "$luci_rpc_path"
    fi

    local old_script_path="$BUILD_DIR/package/base-files/files/sbin/cpuusage"
    if [ -f "$old_script_path" ]; then
        rm -f "$old_script_path"
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax" ]; then
        install -Dm755 "$BASE_PATH/patches/cpuusage" "$qualcommax_sbin_dir/cpuusage"
    fi
    if [ -d "$BUILD_DIR/target/linux/mediatek" ]; then
        install -Dm755 "$BASE_PATH/patches/hnatusage" "$filogic_sbin_dir/cpuusage"
    fi
}

update_tcping() {
    local tcping_path="$BUILD_DIR/feeds/small8/tcping/Makefile"
    local url="https://raw.githubusercontent.com/Openwrt-Passwall/openwrt-passwall-packages/refs/heads/main/tcping/Makefile"

    if [ -d "$(dirname "$tcping_path")" ]; then
        echo "正在更新 tcping Makefile..."
        if ! curl -fsSL -o "$tcping_path.new" "$url" 2>/dev/null; then
            echo "警告：从 $url 下载 tcping Makefile 失败（网络问题）" >&2
            echo "跳过 tcping 更新，使用原始文件继续编译"
            return 0
        fi
        if [ ! -s "$tcping_path.new" ]; then
            echo "警告：下载的 tcping Makefile 为空文件" >&2
            rm -f "$tcping_path.new"
            return 0
        fi
        mv "$tcping_path.new" "$tcping_path"
        echo "tcping Makefile 更新成功"
    fi
}

set_custom_task() {
    local sh_dir="$BUILD_DIR/package/base-files/files/etc/init.d"
    cat <<'EOF' >"$sh_dir/custom_task"
#!/bin/sh /etc/rc.common
START=99

boot() {
    sed -i '/drop_caches/d' /etc/crontabs/root
    echo "15 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches" >>/etc/crontabs/root

    sed -i '/wireguard_watchdog/d' /etc/crontabs/root

    local wg_ifname=$(wg show | awk '/interface/ {print $2}')

    if [ -n "$wg_ifname" ]; then
        echo "*/15 * * * * /usr/bin/wireguard_watchdog" >>/etc/crontabs/root
        uci set system.@system[0].cronloglevel='9'
        uci commit system
        /etc/init.d/cron restart
    fi

    crontab /etc/crontabs/root
}
EOF
    chmod +x "$sh_dir/custom_task"
}

apply_passwall_tweaks() {
    local chnlist_path="$BUILD_DIR/feeds/passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist"
    if [ -f "$chnlist_path" ]; then
        >"$chnlist_path"
    fi

    local xray_util_path="$BUILD_DIR/feeds/passwall/luci-app-passwall/luasrc/passwall/util_xray.lua"
    if [ -f "$xray_util_path" ]; then
        sed -i 's/maxRTT = "1s"/maxRTT = "2s"/g' "$xray_util_path"
        sed -i 's/sampling = 3/sampling = 5/g' "$xray_util_path"
    fi
}

install_opkg_distfeeds() {
    local emortal_def_dir="$BUILD_DIR/package/emortal/default-settings"
    local distfeeds_conf="$emortal_def_dir/files/99-distfeeds.conf"

    if [ -d "$emortal_def_dir" ] && [ ! -f "$distfeeds_conf" ]; then
        cat <<'EOF' >"$distfeeds_conf"
src/gz openwrt_base https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/base/
src/gz openwrt_luci https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/luci/
src/gz openwrt_packages https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/packages/
src/gz openwrt_routing https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/routing/
src/gz openwrt_telephony https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony/
EOF

        sed -i "/define Package\/default-settings\/install/a\\
\\t\$(INSTALL_DIR) \$(1)/etc\\n\
\t\$(INSTALL_DATA) ./files/99-distfeeds.conf \$(1)/etc/99-distfeeds.conf\n" $emortal_def_dir/Makefile

        sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" $emortal_def_dir/files/99-default-settings
    fi
}

update_nss_pbuf_performance() {
    local pbuf_path="$BUILD_DIR/package/kernel/mac80211/files/pbuf.uci"
    if [ -d "$(dirname "$pbuf_path")" ] && [ -f $pbuf_path ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" $pbuf_path
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" $pbuf_path
    fi
}

set_build_signature() {
    local file="$BUILD_DIR/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -d "$(dirname "$file")" ] && [ -f $file ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by ZqinKing')/g" "$file"
    fi
}

update_nss_diag() {
    local file="$BUILD_DIR/package/kernel/mac80211/files/nss_diag.sh"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        \rm -f "$file"
        install -Dm755 "$BASE_PATH/patches/nss_diag.sh" "$file"
    fi
}

update_menu_location() {
    local samba4_path="$BUILD_DIR/feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    if [ -d "$(dirname "$samba4_path")" ] && [ -f "$samba4_path" ]; then
        sed -i 's/nas/services/g' "$samba4_path"
    fi

    local tailscale_path="$BUILD_DIR/feeds/small8/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    if [ -d "$(dirname "$tailscale_path")" ] && [ -f "$tailscale_path" ]; then
        sed -i 's/services/vpn/g' "$tailscale_path"
    fi
}

fix_compile_coremark() {
    local file="$BUILD_DIR/feeds/packages/utils/coremark/Makefile"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i 's/mkdir \$/mkdir -p \$/g' "$file"
    fi
}

update_dnsmasq_conf() {
    local file="$BUILD_DIR/package/network/services/dnsmasq/files/dhcp.conf"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i '/dns_redirect/d' "$file"
    fi
}

add_backup_info_to_sysupgrade() {
    local conf_path="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"

    if [ -f "$conf_path" ]; then
        cat >"$conf_path" <<'EOF'
/etc/AdGuardHome.yaml
/etc/easytier
/etc/lucky/
EOF
    fi
}

update_script_priority() {
    local qca_drv_path="$BUILD_DIR/package/feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
    if [ -d "${qca_drv_path%/*}" ] && [ -f "$qca_drv_path" ]; then
        sed -i 's/START=.*/START=88/g' "$qca_drv_path"
    fi

    local pbuf_path="$BUILD_DIR/package/kernel/mac80211/files/qca-nss-pbuf.init"
    if [ -d "${pbuf_path%/*}" ] && [ -f "$pbuf_path" ]; then
        sed -i 's/START=.*/START=89/g' "$pbuf_path"
    fi

    local mosdns_path="$BUILD_DIR/package/feeds/small8/luci-app-mosdns/root/etc/init.d/mosdns"
    if [ -d "${mosdns_path%/*}" ] && [ -f "$mosdns_path" ]; then
        sed -i 's/START=.*/START=94/g' "$mosdns_path"
    fi
}

update_mosdns_deconfig() {
    local mosdns_conf="$BUILD_DIR/feeds/small8/luci-app-mosdns/root/etc/config/mosdns"
    if [ -d "${mosdns_conf%/*}" ] && [ -f "$mosdns_conf" ]; then
        sed -i 's/8000/300/g' "$mosdns_conf"
        sed -i 's/5335/5336/g' "$mosdns_conf"
    fi
}

fix_quickstart() {
    local file_path="$BUILD_DIR/feeds/small8/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    local url="https://gist.githubusercontent.com/puteulanus/1c180fae6bccd25e57eb6d30b7aa28aa/raw/istore_backend.lua"
    
    if [ ! -f "$file_path" ]; then
        echo "quickstart istore_backend.lua 文件不存在，跳过修复"
        return 0
    fi
    
    echo "正在修复 quickstart..."
    
    # 尝试下载修复文件，如果失败则跳过（不影响编译）
    if curl -fsSL -o "$file_path.new" "$url" 2>/dev/null; then
        mv "$file_path.new" "$file_path"
        echo "quickstart 修复成功"
    else
        echo "警告：无法从 GitHub Gist 下载 quickstart 修复文件（网络问题）"
        echo "跳过 quickstart 修复，使用原始文件继续编译"
        rm -f "$file_path.new"
    fi
}

update_oaf_deconfig() {
    local conf_path="$BUILD_DIR/feeds/small8/open-app-filter/files/appfilter.config"
    local uci_def="$BUILD_DIR/feeds/small8/luci-app-oaf/root/etc/uci-defaults/94_feature_3.0"
    local disable_path="$BUILD_DIR/feeds/small8/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"

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

update_geoip() {
    local geodata_path="$BUILD_DIR/package/feeds/small8/v2ray-geodata/Makefile"
    if [ -d "${geodata_path%/*}" ] && [ -f "$geodata_path" ]; then
        local GEOIP_VER=$(awk -F"=" '/GEOIP_VER:=/ {print $NF}' $geodata_path | grep -oE "[0-9]{1,}")
        if [ -n "$GEOIP_VER" ]; then
            local base_url="https://github.com/v2fly/geoip/releases/download/${GEOIP_VER}"
            local old_SHA256
            if ! old_SHA256=$(wget -qO- "$base_url/geoip.dat.sha256sum" | awk '{print $1}'); then
                echo "错误：从 $base_url/geoip.dat.sha256sum 获取旧的 geoip.dat 校验和失败" >&2
                return 1
            fi
            local new_SHA256
            if ! new_SHA256=$(wget -qO- "$base_url/geoip-only-cn-private.dat.sha256sum" | awk '{print $1}'); then
                echo "错误：从 $base_url/geoip-only-cn-private.dat.sha256sum 获取新的 geoip-only-cn-private.dat 校验和失败" >&2
                return 1
            fi
            if [ -n "$old_SHA256" ] && [ -n "$new_SHA256" ]; then
                if grep -q "$old_SHA256" "$geodata_path"; then
                    sed -i "s|=geoip.dat|=geoip-only-cn-private.dat|g" "$geodata_path"
                    sed -i "s/$old_SHA256/$new_SHA256/g" "$geodata_path"
                fi
            fi
        fi
    fi
}

fix_rust_compile_error() {
    if [ -f "$BUILD_DIR/feeds/packages/lang/rust/Makefile" ]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$BUILD_DIR/feeds/packages/lang/rust/Makefile"
    fi
}

fix_easytier_lua() {
    local file_path="$BUILD_DIR/package/feeds/small8/luci-app-easytier/luasrc/model/cbi/easytier.lua"
    if [ -f "$file_path" ]; then
        sed -i 's/util.pcdata/xml.pcdata/g' "$file_path"
    fi
}

fix_easytier_mk() {
    local mk_path="$BUILD_DIR/feeds/small8/luci-app-easytier/easytier/Makefile"
    if [ -f "$mk_path" ]; then
        sed -i 's/!@(mips||mipsel)/!TARGET_mips \&\& !TARGET_mipsel/g' "$mk_path"
    fi
}

update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    local source_date="2024-03-02"
    local source_version="564fa3e9c2b04ea298ea659b793480415da26415"
    local mirror_hash="92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f"

    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=$source_date/g" "$makefile_path"
        sed -i "s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=$source_version/g" "$makefile_path"
        sed -i "s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=$mirror_hash/g" "$makefile_path"
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}

fix_openssl_ktls() {
    local config_in="$BUILD_DIR/package/libs/openssl/Config.in"
    if [ -f "$config_in" ]; then
        echo "正在更新 OpenSSL kTLS 配置..."
        sed -i 's/select PACKAGE_kmod-tls/depends on PACKAGE_kmod-tls/g' "$config_in"
        sed -i '/depends on PACKAGE_kmod-tls/a\\tdefault y if PACKAGE_kmod-tls' "$config_in"
    fi
}

fix_opkg_check() {
    local patch_file="$BASE_PATH/patches/001-fix-provides-version-parsing.patch"
    local opkg_dir="$BUILD_DIR/package/system/opkg"
    if [ -f "$patch_file" ]; then
        install -Dm644 "$patch_file" "$opkg_dir/patches/001-fix-provides-version-parsing.patch"
    fi
}

install_pbr_cmcc() {
    local pbr_pkg_dir="$BUILD_DIR/package/feeds/packages/pbr"
    local pbr_dir="$pbr_pkg_dir/files/usr/share/pbr"
    local pbr_conf="$pbr_pkg_dir/files/etc/config/pbr"
    local pbr_makefile="$pbr_pkg_dir/Makefile"

    if [ -d "$pbr_pkg_dir" ]; then
        echo "正在安装 PBR CMCC 配置文件..."
        install -Dm644 "$BASE_PATH/patches/pbr.user.cmcc" "$pbr_dir/pbr.user.cmcc"
        install -Dm644 "$BASE_PATH/patches/pbr.user.cmcc6" "$pbr_dir/pbr.user.cmcc6"

        if [ -f "$pbr_makefile" ]; then
            if ! grep -q "pbr.user.cmcc" "$pbr_makefile"; then
                echo "正在修改 PBR Makefile 添加安装规则..."
                sed -i '/pbr.user.netflix.*\$(1)/a\
	$(INSTALL_DATA) ./files/usr/share/pbr/pbr.user.cmcc $(1)/usr/share/pbr/pbr.user.cmcc\
	$(INSTALL_DATA) ./files/usr/share/pbr/pbr.user.cmcc6 $(1)/usr/share/pbr/pbr.user.cmcc6' "$pbr_makefile"
            fi
        fi
    fi

    if [ -f "$pbr_conf" ]; then
        if ! grep -q "pbr.user.cmcc" "$pbr_conf"; then
            echo "正在添加 PBR CMCC 配置条目..."
            sed -i "/option path '\/usr\/share\/pbr\/pbr.user.netflix'/,/option enabled '0'/{
                /option enabled '0'/a\\
\\
config include\\
	option path '/usr/share/pbr/pbr.user.cmcc'\\
	option enabled '0'\\
\\
config include\\
	option path '/usr/share/pbr/pbr.user.cmcc6'\\
	option enabled '0'
            }" "$pbr_conf"
        fi
    fi
}

fix_pbr_ip_forward() {
    local pbr_pkg_dir="$BUILD_DIR/package/feeds/packages/pbr"
    local pbr_init_script="$pbr_pkg_dir/files/etc/init.d/pbr"

    if [ ! -d "$pbr_pkg_dir" ]; then
        echo "PBR package directory not found: $pbr_pkg_dir"
        return 1
    fi

    if [ ! -f "$pbr_init_script" ]; then
        echo "PBR init script not found: $pbr_init_script"
        return 1
    fi

    # Check if fix is already applied (enabled check already present)
    if grep -q '\[ -n "$enabled" \] && \[ -n "$strict_enforcement" \]' "$pbr_init_script"; then
        echo "PBR IP Forward fix already applied"
        return 0
    fi

    # Check if the original pattern exists that needs fixing
    if ! grep -q '\[ -n "$strict_enforcement" \] && \[ "$(cat /proc/sys/net/ipv4/ip_forward)"' "$pbr_init_script"; then
        echo "PBR IP Forward: 未找到需要修复的代码，可能上游已修复或此版本无此问题"
        return 0
    fi

    echo "正在应用 PBR IP Forward 修复..."
    # Fix: Add enabled check before strict_enforcement check
    # Original: if [ -n "$strict_enforcement" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "0" ]; then
    # Fixed:   if [ -n "$enabled" ] && [ -n "$strict_enforcement" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "0" ]; then
    sed -i 's/\[ -n "\$strict_enforcement" \] && \[ "\$(cat \/proc\/sys\/net\/ipv4\/ip_forward)"/\[ -n "\$enabled" \] \&\& \[ -n "\$strict_enforcement" \] \&\& \[ "\$(cat \/proc\/sys\/net\/ipv4\/ip_forward)"/' "$pbr_init_script"
    
    if grep -q '\[ -n "$enabled" \] && \[ -n "$strict_enforcement" \]' "$pbr_init_script"; then
        echo "PBR IP Forward 修复应用成功"
        return 0
    else
        echo "修复应用失败：未找到预期的修复内容"
        return 1
    fi
}

fix_quectel_cm() {
    local makefile_path="$BUILD_DIR/package/feeds/packages/quectel-cm/Makefile"
    local cmake_patch_path="$BUILD_DIR/package/feeds/packages/quectel-cm/patches/020-cmake.patch"

    if [ -f "$makefile_path" ]; then
        echo "正在修复 quectel-cm Makefile..."

        sed -i '/^PKG_SOURCE:=/d' "$makefile_path"
        sed -i '/^PKG_SOURCE_URL:=@IMMORTALWRT/d' "$makefile_path"
        sed -i '/^PKG_HASH:=/d' "$makefile_path"

        sed -i '/^PKG_RELEASE:=/a\
\
PKG_SOURCE_PROTO:=git\
PKG_SOURCE_URL:=https://github.com/Carton32/quectel-CM.git\
PKG_SOURCE_VERSION:=$(PKG_VERSION)\
PKG_MIRROR_HASH:=skip' "$makefile_path"

        sed -i 's/^PKG_RELEASE:=2$/PKG_RELEASE:=3/' "$makefile_path"

        echo "quectel-cm Makefile 修复完成。"
    fi

    if [ -f "$cmake_patch_path" ]; then
        sed -i 's/-cmake_minimum_required(VERSION 2\.4)$/-cmake_minimum_required(VERSION 2.4) /' "$cmake_patch_path"
        sed -i 's/project(quectel-CM)$/project(quectel-CM) /' "$cmake_patch_path"
    fi
}

set_nginx_default_config() {
    local nginx_config_path="$BUILD_DIR/feeds/packages/net/nginx-util/files/nginx.config"
    if [ -f "$nginx_config_path" ]; then
        cat >"$nginx_config_path" <<EOF
config main 'global'
        option uci_enable 'true'

config server '_lan'
        list listen '443 ssl default_server'
        list listen '[::]:443 ssl default_server'
        option server_name '_lan'
        list include 'restrict_locally'
        list include 'conf.d/*.locations'
        option uci_manage_ssl 'self-signed'
        option ssl_certificate '/etc/nginx/conf.d/_lan.crt'
        option ssl_certificate_key '/etc/nginx/conf.d/_lan.key'
        option ssl_session_cache 'shared:SSL:32k'
        option ssl_session_timeout '64m'
        option access_log 'off; # logd openwrt'

config server 'http_only'
        list listen '80'
        list listen '[::]:80'
        option server_name 'http_only'
        list include 'conf.d/*.locations'
        option access_log 'off; # logd openwrt'
EOF
    fi

    local nginx_template="$BUILD_DIR/feeds/packages/net/nginx-util/files/uci.conf.template"
    if [ -f "$nginx_template" ]; then
        if ! grep -q "client_body_in_file_only clean;" "$nginx_template"; then
            sed -i "/client_max_body_size 128M;/a\\
\tclient_body_in_file_only clean;\\
\tclient_body_temp_path /mnt/tmp;" "$nginx_template"
        fi
    fi

    local luci_support_script="$BUILD_DIR/feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support"

    if [ -f "$luci_support_script" ]; then
        if ! grep -q "client_body_in_file_only off;" "$luci_support_script"; then
            echo "正在为 Nginx ubus location 配置应用修复..."
            sed -i "/ubus_parallel_req 2;/a\\        client_body_in_file_only off;\\n        client_max_body_size 1M;" "$luci_support_script"
        fi
    fi
}

update_uwsgi_limit_as() {
    local cgi_io_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-cgi_io.ini"
    local webui_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini"

    if [ -f "$cgi_io_ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$cgi_io_ini"
    fi

    if [ -f "$webui_ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$webui_ini"
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


enable_turboacc_by_default() {
    # TurboACC 配置文件路径（注意：不是 luci-app-turboacc-mtk）
    local turboacc_config="$BUILD_DIR/feeds/small8/luci-app-turboacc/root/etc/config/turboacc"
    
    if [ -f "$turboacc_config" ]; then
        echo "正在设置 TurboACC 默认启用..."
        # 只修改 global 段的 option set
        sed -i "/config turboacc 'global'/,/^config/ {
            s/option set '0'/option set '1'/
        }" "$turboacc_config"
        echo "TurboACC 已设置为默认启用"
    else
        echo "警告：未找到 TurboACC 配置文件: $turboacc_config" >&2
    fi
    
    # 确保 mtkhnat 内核模块自动加载
    local modules_d_dir="$BUILD_DIR/package/base-files/files/etc/modules.d"
    if [ ! -d "$modules_d_dir" ]; then
        mkdir -p "$modules_d_dir"
    fi
    
    # 创建模块自动加载配置
    echo "# MediaTek Hardware NAT" > "$modules_d_dir/60-mtkhnat"
    echo "mtkhnat" >> "$modules_d_dir/60-mtkhnat"
    echo "已配置 mtkhnat 内核模块自动加载"
    
    # 创建 uci-defaults 脚本确保 TurboACC 服务启动
    local uci_defaults_dir="$BUILD_DIR/package/base-files/files/etc/uci-defaults"
    if [ ! -d "$uci_defaults_dir" ]; then
        mkdir -p "$uci_defaults_dir"
    fi
    
    cat > "$uci_defaults_dir/95-turboacc-enable" << 'EOF'
#!/bin/sh
# 确保 TurboACC 服务启用并启动（不修改配置，配置已在编译时设置）

# 启用 TurboACC 服务
/etc/init.d/turboacc enable

# 加载 mtkhnat 模块（双重保险，防止自动加载失败）
modprobe mtkhnat 2>/dev/null || true

# 启动 TurboACC 服务
/etc/init.d/turboacc start

exit 0
EOF
    
    chmod +x "$uci_defaults_dir/95-turboacc-enable"
    echo "已创建 TurboACC 自动启用脚本"
}

check_iptables_conflicts() {
    local config_file=".config"
    
    # 如果在其他目录调用，使用完整路径
    if [ ! -f "$config_file" ] && [ -n "$BUILD_DIR" ]; then
        config_file="$BUILD_DIR/.config"
    fi
    
    # 如果 .config 还不存在，跳过检查
    if [ ! -f "$config_file" ]; then
        echo "跳过 iptables 冲突检查（配置文件尚未生成）"
        return 0
    fi
    
    echo "=========================================="
    echo "检查 iptables/nftables 冲突"
    echo "=========================================="
    
    local has_docker=0
    local has_conflict=0
    local conflict_packages=()
    
    # 检查是否启用了 Docker
    if grep -q "^CONFIG_PACKAGE_dockerd=y" "$config_file"; then
        has_docker=1
        echo "✓ 检测到 Docker 已启用"
    fi
    
    # 如果没有启用 Docker，跳过检查
    if [ $has_docker -eq 0 ]; then
        echo "Docker 未启用，跳过 iptables 冲突检查"
        echo "=========================================="
        return 0
    fi
    
    # 定义冲突的 iptables 包列表
    local conflict_list=(
        "kmod-ipt-nat"
        "kmod-ipt-nat6"
        "kmod-ipt-physdev"
        "kmod-nf-ipt"
        "kmod-nf-ipt6"
        "kmod-ipt-core"
        "kmod-ipt-conntrack"
        "kmod-ipt-extra"
        "kmod-ipt-filter"
        "kmod-ipt-fullconenat"
        "kmod-ipt-offload"
        "kmod-ipt-raw"
        "kmod-ipt-raw6"
        "kmod-ipt-tproxy"
        "kmod-nft-compat"
        "iptables-mod-extra"
        "iptables"
        "iptables-legacy"
        "ip6tables"
        "ip6tables-legacy"
    )
    
    # 检查每个冲突包
    for pkg in "${conflict_list[@]}"; do
        # 检查是否被启用（=y 或没有被明确禁用）
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file"; then
            has_conflict=1
            conflict_packages+=("$pkg (已启用)")
        elif ! grep -q "^CONFIG_PACKAGE_${pkg}=n" "$config_file" && \
             ! grep -q "^# CONFIG_PACKAGE_${pkg} is not set" "$config_file"; then
            # 如果既没有 =y 也没有 =n 或 is not set，说明可能会被依赖拉入
            has_conflict=1
            conflict_packages+=("$pkg (未明确禁用)")
        fi
    done
    
    # 检查必需的 nftables 支持
    local has_nftables=0
    if grep -q "^CONFIG_PACKAGE_nftables=y" "$config_file" && \
       grep -q "^CONFIG_PACKAGE_iptables-nft=y" "$config_file"; then
        has_nftables=1
        echo "✓ nftables 支持已启用"
        echo "✓ iptables-nft 兼容层已启用"
    elif grep -q "^CONFIG_PACKAGE_iptables-nft=y" "$config_file"; then
        has_nftables=1
        echo "✓ iptables-nft 兼容层已启用"
        if ! grep -q "^CONFIG_PACKAGE_nftables=y" "$config_file"; then
            echo "⚠️  nftables 用户空间工具未启用（但 iptables-nft 已启用，可以工作）"
        fi
    else
        echo "⚠️  警告：nftables 或 iptables-nft 未启用"
    fi
    
    # 输出检查结果
    if [ $has_conflict -eq 1 ]; then
        echo ""
        echo "❌ 错误：检测到与 Docker v29 nftables 冲突的 iptables 模块！"
        echo ""
        echo "冲突的包："
        for pkg in "${conflict_packages[@]}"; do
            echo "  - $pkg"
        done
        echo ""
        echo "解决方案："
        echo "1. 确保 docker_deps.config 已正确加载"
        echo "2. 检查设备配置文件是否启用了冲突的包"
        echo "3. 运行 'make defconfig' 后这些包应该被禁用"
        echo ""
        echo "Docker v29 使用纯 nftables 后端，不兼容传统 iptables 模块。"
        echo "OpenClash 也使用 nftables，两者可以通过 iptables-nft 兼容层共存。"
        echo "=========================================="
        return 1
    else
        echo ""
        echo "✅ 未检测到 iptables/nftables 冲突"
        echo "✅ Docker v29 + OpenClash 配置正确"
        echo "=========================================="
        return 0
    fi
}
