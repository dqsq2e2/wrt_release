#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$BASE_PATH/.." && pwd)
MODEL=jdcloud_ax6000_immwrt_honk
source <(sed 's/\r$//' "$BASE_PATH/modules/verify.sh")
source <(sed 's/\r$//' "$BASE_PATH/modules/custom_feed.sh")
source <(sed 's/\r$//' "$BASE_PATH/modules/feed_source_fixes.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

grep -Fq 'kenzok8/openwrt-honk|https://github.com/kenzok8/openwrt-honk.git|main|honk luci-app-honk' \
    "$BASE_PATH/modules/custom_feed.sh"
echo "PASS: Honk packages use the kenzok8 source"

preview=$(cd "$REPO_ROOT" && bash <(sed 's/\r$//' build.sh) "$MODEL" config_preview)
grep -q 'Effective fragments: honk,istore$' <<< "$preview"
grep -q 'Honk packages: enabled$' <<< "$preview"
grep -q 'Daed packages: skipped$' <<< "$preview"
grep -q 'Docker stack patches: skipped$' <<< "$preview"
grep -q 'Expected kernel: 6.18$' <<< "$preview"
echo "PASS: renamed model selects Honk without enabling daed or Docker"

preview=$(cd "$REPO_ROOT" && REMOVE_CONFIG_FRAGMENTS=honk \
    bash <(sed 's/\r$//' build.sh) "$MODEL" config_preview)
grep -q 'Honk packages: skipped$' <<< "$preview"
echo "PASS: removing Honk disables package integration"

preview=$(cd "$REPO_ROOT" && ADD_CONFIG_FRAGMENTS=honk \
    bash <(sed 's/\r$//' build.sh) jdcloud_ax6000_immwrt config_preview)
grep -q 'Honk packages: enabled$' <<< "$preview"
echo "PASS: Honk fragment can be added to an existing model"

preview=$(cd "$REPO_ROOT" && REMOVE_CONFIG_FRAGMENTS=honk bash <(sed 's/\r$//' build.sh) \
    jdcloud_ax6000_immwrt config_preview)
grep -q 'Honk packages: skipped$' <<< "$preview"
echo "PASS: removing Honk disables integration in the base AX6000 model"

sed 's/\r$//' "$BASE_PATH/deconfig/fragments/honk.config" > "$test_dir/config"
verify_honk_config "$test_dir/config" 1
grep -v '^CONFIG_KERNEL_DEBUG_INFO_BTF=y$' "$test_dir/config" > "$test_dir/no-btf"
if verify_honk_config "$test_dir/no-btf" 1 > "$test_dir/error.log" 2>&1; then
    echo "FAIL: missing kernel BTF was accepted" >&2
    exit 1
fi
grep -q 'CONFIG_KERNEL_DEBUG_INFO_BTF=y' "$test_dir/error.log"
verify_honk_config "$test_dir/no-btf" 0
echo "PASS: BTF loss fails selected Honk builds only"

for symbol in CONFIG_PACKAGE_honk CONFIG_PACKAGE_luci-app-honk \
    CONFIG_PACKAGE_v2ray-geoip CONFIG_PACKAGE_v2ray-geosite CONFIG_PACKAGE_kmod-nft-queue; do
    grep -v "^${symbol}=y$" "$test_dir/config" > "$test_dir/missing-symbol"
    if verify_honk_config "$test_dir/missing-symbol" 1 > "$test_dir/error.log" 2>&1; then
        echo "FAIL: missing $symbol was accepted" >&2
        exit 1
    fi
    grep -q "${symbol}=y" "$test_dir/error.log"
done
echo "PASS: missing Honk packages, Geo data and nft queue fail validation"

sed 's/\r$//' "$BASE_PATH/deconfig/fragments/daed.config" > "$test_dir/daed-config"
verify_daed_config "$test_dir/daed-config" 1
preview=$(cd "$REPO_ROOT" && ADD_CONFIG_FRAGMENTS=daed REMOVE_CONFIG_FRAGMENTS=honk \
    bash <(sed 's/\r$//' build.sh) "$MODEL" config_preview)
grep -q 'Effective fragments: istore,daed$' <<< "$preview"
grep -q 'Daed packages: enabled$' <<< "$preview"
grep -q 'Honk packages: skipped$' <<< "$preview"
echo "PASS: optional daed integration remains available"

printf 'KERNEL_PATCHVER:=6.18\n' > "$test_dir/target.mk"
verify_expected_kernel_version 6.18 "$test_dir/target.mk"
printf 'KERNEL_PATCHVER:=6.19\n' > "$test_dir/target.mk"
if verify_expected_kernel_version 6.18 "$test_dir/target.mk" > "$test_dir/error.log" 2>&1; then
    echo "FAIL: unexpected upstream kernel was accepted" >&2
    exit 1
fi
verify_expected_kernel_version "" "$test_dir/missing.mk"
echo "PASS: kernel guard rejects upstream version drift"

mkdir -p "$test_dir/luci-app-daede"
printf 'include $(INCLUDE_DIR)/package.mk\n' > "$test_dir/luci-app-daede/Makefile"
fix_daede_luci_host_depends "$test_dir/luci-app-daede"
fix_daede_luci_host_depends "$test_dir/luci-app-daede"
[[ $(grep -c '^PKG_BUILD_DEPENDS+=luci-base/host$' "$test_dir/luci-app-daede/Makefile") == 1 ]]
echo "PASS: optional daede po2lmo host dependency is installed exactly once"

if HONK_PACKAGES_ENABLED=invalid bash <(sed 's/\r$//' "$BASE_PATH/update.sh") \
    unused main "$test_dir/invalid-flag" none > "$test_dir/error.log" 2>&1; then
    echo "FAIL: invalid Honk integration flag was accepted" >&2
    exit 1
fi
grep -q 'HONK_PACKAGES_ENABLED must be 0 or 1' "$test_dir/error.log"
echo "PASS: invalid Honk integration flag fails before source checkout"

for enabled in 0 1; do
    cleanup_tree="$test_dir/feed-cleanup-$enabled"
    mkdir -p "$cleanup_tree/feeds/luci/applications/luci-app-honk" \
        "$cleanup_tree/feeds/packages/net/honk"
    (
        cd "$cleanup_tree"
        BUILD_DIR="$cleanup_tree"
        HONK_PACKAGES_ENABLED=$enabled
        remove_unwanted_packages
    )
    if [[ $enabled == 1 ]]; then
        [[ ! -d "$cleanup_tree/feeds/luci/applications/luci-app-honk" ]]
        [[ ! -d "$cleanup_tree/feeds/packages/net/honk" ]]
    else
        [[ -d "$cleanup_tree/feeds/luci/applications/luci-app-honk" ]]
        [[ -d "$cleanup_tree/feeds/packages/net/honk" ]]
    fi
done
echo "PASS: upstream Honk package cleanup follows the effective fragment"

# Run the real debug entry with stub checkout/make to check fragment propagation.
mkdir -p "$test_dir/project/wrt_core" "$test_dir/bin"
cp -a "$BASE_PATH/deconfig" "$BASE_PATH/compilecfg" "$BASE_PATH/modules" \
    "$test_dir/project/wrt_core/"
sed 's/\r$//' "$REPO_ROOT/build.sh" > "$test_dir/project/build.sh"
cat > "$test_dir/project/wrt_core/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${HONK_PACKAGES_ENABLED:-unset}" > "$TEST_HONK_FLAG"
printf '%s\n' "${DAED_PACKAGES_ENABLED:-unset}" > "$TEST_DAED_FLAG"
mkdir -p "$3/target/linux/mediatek"
printf 'KERNEL_PATCHVER:=6.18\n' > "$3/target/linux/mediatek/Makefile"
EOF
chmod +x "$test_dir/project/wrt_core/update.sh"
cat > "$test_dir/bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == defconfig ]]
printf '\nCONFIG_PACKAGE_openwrt-keyring=y\n' >> .config
sed -i 's/\r$//' .config
EOF
chmod +x "$test_dir/bin/make"
export TEST_HONK_FLAG="$test_dir/flag"
export TEST_DAED_FLAG="$test_dir/daed-flag"
(
    cd "$test_dir/project"
    PATH="$test_dir/bin:$PATH" bash build.sh "$MODEL" debug > "$test_dir/debug.log"
)
grep -qx '1' "$TEST_HONK_FLAG"
grep -qx '0' "$TEST_DAED_FLAG"
grep -qx 'CONFIG_PACKAGE_luci-app-fullconenat-sonic=y' \
    "$test_dir/project/immortalwrt-honk/.config"
grep -qx 'CONFIG_PACKAGE_honk=y' "$test_dir/project/immortalwrt-honk/.config"
echo "PASS: build entry passes enabled Honk integration to update.sh"
(
    cd "$test_dir/project"
    PATH="$test_dir/bin:$PATH" REMOVE_CONFIG_FRAGMENTS=honk \
        bash build.sh "$MODEL" debug > "$test_dir/debug.log"
)
grep -qx '0' "$TEST_HONK_FLAG"
grep -qx 'CONFIG_PACKAGE_luci-app-fullconenat-sonic=y' \
    "$test_dir/project/immortalwrt-honk/.config"
if grep -qx 'CONFIG_PACKAGE_honk=y' "$test_dir/project/immortalwrt-honk/.config"; then
    echo "FAIL: removing Honk still selects its core" >&2
    exit 1
fi
echo "PASS: removing Honk disables both source integration and package selection"

# Exercise the real watcher against an isolated Git snapshot and mocked caches.
export TEST_REAL_GIT
TEST_REAL_GIT=$(command -v git)
git clone --quiet --shared "$REPO_ROOT" "$test_dir/watch"
cp -a "$BASE_PATH/." "$test_dir/watch/wrt_core/"
cp -a "$REPO_ROOT/.github/." "$test_dir/watch/.github/"
cp "$REPO_ROOT/build.sh" "$test_dir/watch/build.sh"
find "$test_dir/watch/wrt_core" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
git -C "$test_dir/watch" add -- wrt_core .github build.sh
git -C "$test_dir/watch" -c user.name=Test -c user.email=test@example.invalid \
    commit --no-gpg-sign --allow-empty -qm "Test current build configuration"
mkdir -p "$test_dir/watch-bin"
cat > "$test_dir/watch-bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == ls-remote ]]; then
    [[ $2 == https://github.com/VIKINGYFY/immortalwrt.git ]]
    [[ $3 == refs/heads/owrt ]]
    printf '%s\t%s\n' "$WATCH_TEST_SHA" "$3"
else
    exec "$TEST_REAL_GIT" "$@"
fi
EOF
cat > "$test_dir/watch-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == cache && $2 == list && $3 == --key ]]
if [[ $4 == "${WATCH_TEST_CACHE_KEY:-}" ]]; then
    printf '%s\n' "$4"
fi
EOF
chmod +x "$test_dir/watch-bin/git" "$test_dir/watch-bin/gh"
export WATCH_TEST_SHA=1111111111111111111111111111111111111111

run_watcher() {
    : > "$test_dir/watch-output"
    (
        cd "$test_dir/watch"
        PATH="$test_dir/watch-bin:$PATH" WATCH_MODEL="$MODEL" \
            FORCE_BUILD="${WATCH_TEST_FORCE:-false}" GITHUB_SHA=HEAD \
            GITHUB_OUTPUT="$test_dir/watch-output" GITHUB_STEP_SUMMARY="" \
            bash wrt_core/ci/detect_upstream_changes.sh > "$test_dir/watch.log"
    )
}

watch_fingerprint() {
    sed -n 's/^matrix=//p' "$test_dir/watch-output" | jq -r '.include[0].fingerprint'
}

run_watcher
grep -qx 'count=1' "$test_dir/watch-output"
sed -n 's/^matrix=//p' "$test_dir/watch-output" | \
    jq -e --arg model "$MODEL" --arg sha "$WATCH_TEST_SHA" \
    '.include[0] | .model == $model and .upstream_sha == $sha and .repo_branch == "owrt"' >/dev/null
fingerprint=$(watch_fingerprint)
echo "PASS: first upstream check schedules the renamed Honk model"

export WATCH_TEST_CACHE_KEY="upstream-watch-${MODEL}-${fingerprint}"
run_watcher
grep -qx 'count=0' "$test_dir/watch-output"
echo "PASS: successful fingerprint skips an unchanged Honk build"

export WATCH_TEST_FORCE=true
run_watcher
grep -qx 'count=1' "$test_dir/watch-output"
unset WATCH_TEST_FORCE
echo "PASS: forced upstream check rebuilds a cached Honk model"

export WATCH_TEST_SHA=2222222222222222222222222222222222222222
run_watcher
grep -qx 'count=1' "$test_dir/watch-output"
[[ $(watch_fingerprint) != "$fingerprint" ]]
export WATCH_TEST_SHA=1111111111111111111111111111111111111111
echo "PASS: upstream source changes schedule another Honk build"

printf '\n# Test fragment change\n' >> "$test_dir/watch/wrt_core/deconfig/fragments/honk.config"
git -C "$test_dir/watch" add -- wrt_core/deconfig/fragments/honk.config
git -C "$test_dir/watch" -c user.name=Test -c user.email=test@example.invalid \
    commit --no-gpg-sign -qm "Test Honk fragment fingerprint"
run_watcher
grep -qx 'count=1' "$test_dir/watch-output"
[[ $(watch_fingerprint) != "$fingerprint" ]]
echo "PASS: Honk fragment changes invalidate the successful build marker"
