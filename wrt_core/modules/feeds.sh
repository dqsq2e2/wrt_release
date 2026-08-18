#!/usr/bin/env bash

get_feeds_path() {
    local feeds_path="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        feeds_path="$BUILD_DIR/feeds.conf"
    fi
    printf '%s\n' "$feeds_path"
}

append_feed_if_missing() {
    local feeds_path="$1"
    local match_pattern="$2"
    local feed_entry="$3"

    if ! grep -q "$match_pattern" "$feeds_path"; then
        [ -z "$(tail -c 1 "$feeds_path")" ] || echo "" >>"$feeds_path"
        echo "$feed_entry" >>"$feeds_path"
    fi
}

exclude_build_only_apk_feeds() {
    local feeds_makefile="$BUILD_DIR/include/feeds.mk"

    if [ ! -f "$feeds_makefile" ]; then
        echo "错误：当前源码缺少 include/feeds.mk。" >&2
        return 1
    fi

    python3 - "$feeds_makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "$(if $(filter m,$(CONFIG_FEED_$(feed))),# )%U/packages/%A/$(feed)/packages.adb"
new = "$(if $(filter m,$(CONFIG_FEED_$(feed)))$(filter custom_feed openwrt_bandix luci_app_bandix,$(feed)),# )%U/packages/%A/$(feed)/packages.adb"

if new in text:
    raise SystemExit(0)
if text.count(old) != 1:
    raise SystemExit("include/feeds.mk 中未找到唯一的 APK feed 仓库生成规则")

path.write_text(text.replace(old, new))
PY

    echo "已从运行时 APK 仓库排除仅用于编译的 feeds：custom_feed openwrt_bandix luci_app_bandix"
}

update_feeds() {
    local FEEDS_PATH
    FEEDS_PATH=$(get_feeds_path)
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]small8[[:space:]]/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]custom_feed[[:space:]]/d' "$FEEDS_PATH"

    append_feed_if_missing "$FEEDS_PATH" "openwrt_bandix" "src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main"
    append_feed_if_missing "$FEEDS_PATH" "luci_app_bandix" "src-git luci_app_bandix https://github.com/timsaya/luci-app-bandix.git;main"
    exclude_build_only_apk_feeds

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    network_retry ./scripts/feeds update -a
}

install_feeds() {
    network_retry ./scripts/feeds update -i
    ./scripts/feeds install -a -f
}
