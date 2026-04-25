#!/usr/bin/env bash

update_feeds() {
    local FEEDS_PATH="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        FEEDS_PATH="$BUILD_DIR/feeds.conf"
    fi
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"

    if ! grep -q "small-package" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git small8 https://github.com/kenzok8/jell" >>"$FEEDS_PATH"
    fi

    # iStore official feeds
    if ! grep -q "linkease/nas-packages.git" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git nas https://github.com/linkease/nas-packages.git;master" >>"$FEEDS_PATH"
    fi

    if ! grep -q "linkease/nas-packages-luci.git" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main" >>"$FEEDS_PATH"
    fi

    if ! grep -q "linkease/istore" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git istore https://github.com/linkease/istore;main" >>"$FEEDS_PATH"
    fi

    if ! grep -q "openwrt-passwall" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall;main" >>"$FEEDS_PATH"
    fi

    if ! grep -q "openwrt_bandix" "$BUILD_DIR/$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
        echo 'src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main' >>"$BUILD_DIR/$FEEDS_CONF"
    fi

    if ! grep -q "luci_app_bandix" "$BUILD_DIR/$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
        echo 'src-git luci_app_bandix https://github.com/timsaya/luci-app-bandix.git;main' >>"$BUILD_DIR/$FEEDS_CONF"
    fi

    if ! grep -q "nikki" "$BUILD_DIR/$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
        echo 'src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main' >>"$BUILD_DIR/$FEEDS_CONF"
    fi

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    ./scripts/feeds update -a
}

install_feeds() {
    ./scripts/feeds update -i
    for dir in $BUILD_DIR/feeds/*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [[ ! "$dir" == *.index ]] && [[ ! "$dir" == *.targetindex ]]; then
            if [[ $(basename "$dir") == "small8" ]]; then
                install_small8
                install_fullconenat
            elif [[ $(basename "$dir") == "passwall" ]]; then
                install_passwall
            elif [[ $(basename "$dir") == "nikki" ]]; then
                install_nikki
            elif [[ $(basename "$dir") == "nas" ]] || [[ $(basename "$dir") == "nas_luci" ]] || [[ $(basename "$dir") == "istore" ]]; then
                # Install iStore feeds
                ./scripts/feeds install -f -ap $(basename "$dir")
            else
                ./scripts/feeds install -f -ap $(basename "$dir")
            fi
        fi
    done
}
