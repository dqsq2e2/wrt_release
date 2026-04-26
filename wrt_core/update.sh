#!/usr/bin/env bash

set -e
set -o errexit
set -o errtrace

error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}

trap 'error_handler' ERR

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4

# Convert BUILD_DIR to absolute path
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$(pwd)/$BUILD_DIR"
fi

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="26.x"
THEME_SET="argon"
LAN_ADDR="192.168.1.1"

SCRIPT_DIR=$(cd $(dirname $0) && pwd)
BASE_PATH=${BASE_PATH:-$SCRIPT_DIR}

source "$SCRIPT_DIR/modules/general.sh"
source "$SCRIPT_DIR/modules/feeds.sh"
source "$SCRIPT_DIR/modules/packages.sh"
source "$SCRIPT_DIR/modules/system.sh"
source "$SCRIPT_DIR/modules/cups.sh"
source "$SCRIPT_DIR/modules/docker.sh"


main() {
    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    remove_unwanted_packages
    remove_tweaked_packages
    update_homeproxy
    fix_default_set
    fix_miniupnpd
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends
    # remove_wifi_menu  # 移到 build.sh 中，在配置生成后执行
    fix_natmap_makefile
    fix_rstrip_script

    update_default_lan_addr
    remove_something_nss_kmod
    update_affinity_script
    update_ath11k_fw
    # fix_mkpkg_format_invalid
    change_cpuusage
    update_tcping
    add_ax6600_led
    set_custom_task
    apply_passwall_tweaks
    update_nss_pbuf_performance
    set_build_signature
    update_nss_diag
    update_menu_location
    fix_compile_coremark
    update_dnsmasq_conf
    add_backup_info_to_sysupgrade
    update_mosdns_deconfig
    update_oaf_deconfig
    add_timecontrol
    add_quickfile
    update_lucky
    fix_rust_compile_error
    update_smartdns
    update_diskman  # 临时禁用，避免删除错误
    update_dockerman
    set_nginx_default_config
    update_uwsgi_limit_as
    update_argon
    update_nginx_ubus_module
    check_default_settings
    install_opkg_distfeeds
    fix_easytier_mk
    remove_attendedsysupgrade
    fix_kconfig_recursive_dependency
    install_feeds
    fix_quickstart  # 移到 install_feeds 之后，避免被覆盖
    enable_turboacc_by_default  # 设置 TurboACC 默认启用（必须在 install_feeds 之后）
    
    # Docker 组件更新（所有源码都支持，但使用不同的依赖策略）
    echo "开始 Docker 组件更新..."
    update_docker_stack
    
    fix_cups_libcups_avahi_depends
    fix_easytier_lua
    update_adguardhome
    update_script_priority
    update_geoip
    fix_openssl_ktls
    fix_opkg_check
    fix_quectel_cm
    install_pbr_cmcc
    fix_pbr_ip_forward
    # apply_hash_fixes
}

main "$@"
