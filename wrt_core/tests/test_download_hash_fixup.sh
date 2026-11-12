#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$BASE_PATH/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/download_fixes.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
cd "$test_dir"
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY

pkg=package/network/config/firewall4
upstream_hash=a95c6cfe419c7d4e22bda5608aa6e46c67dadc9c7096879702d614cc498759d0
local_hash=9ce4fee1c5f90e5b097216ef49c8ec981adc5911939622d031f555d103a58ba3
pinned_sha=3722eadc088c3ab81389596ca9796112b436583a

write_makefile() {
    local proto=$1
    local version=$2
    local mirror_hash=$3

    mkdir -p "$pkg"
    printf '%s\n' \
        'PKG_NAME:=firewall4' \
        "PKG_SOURCE_PROTO:=$proto" \
        "PKG_SOURCE_VERSION:=$version" \
        "PKG_MIRROR_HASH:=$mirror_hash" > "$pkg/Makefile"
}

expect_unchanged() {
    local description=$1
    local log=$2
    local before

    before=$(cat "$pkg/Makefile")
    if adopt_local_git_tarball_hash "$pkg" "$log" 2> /dev/null; then
        echo "FAIL: $description: hash was adopted" >&2
        exit 1
    fi
    if [[ $(cat "$pkg/Makefile") != "$before" ]]; then
        echo "FAIL: $description: Makefile changed" >&2
        exit 1
    fi
    echo "PASS: $description"
}

# 与 OpenWrt download.mk 在 git 本地打包后输出的格式一致。
printf 'Hash mismatch for file firewall4-2026.11.08~3722eadc.tar.zst: expected %s, got %s\n' \
    "$upstream_hash" "$local_hash" > mismatch.log

write_makefile git "$pinned_sha" "$upstream_hash"
adopt_local_git_tarball_hash "$pkg" mismatch.log 2> /dev/null
grep -qx "PKG_MIRROR_HASH:=$local_hash" "$pkg/Makefile"
grep -qx "PKG_SOURCE_VERSION:=$pinned_sha" "$pkg/Makefile"
echo "PASS: known firewall4 commit adopts the verified runner hash"

write_makefile git 'v$(PKG_VERSION)' "$upstream_hash"
expect_unchanged "unpinned git version is not adopted" mismatch.log

write_makefile git "${pinned_sha:0:12}" "$upstream_hash"
expect_unchanged "abbreviated commit is not adopted" mismatch.log

write_makefile git "$(printf '%040d' 1)" "$upstream_hash"
expect_unchanged "another full commit is not adopted" mismatch.log

write_makefile svn "$pinned_sha" "$upstream_hash"
expect_unchanged "non-git source is not adopted" mismatch.log

write_makefile git "$pinned_sha" "$(printf '%064d' 1)"
expect_unchanged "mismatch of another source hash is not adopted" mismatch.log

write_makefile git "$pinned_sha" "$upstream_hash"
sed "s/$local_hash/$(printf '%064d' 2)/" mismatch.log > unknown-hash.log
expect_unchanged "unknown local hash is not adopted" unknown-hash.log
sed 's/firewall4-2026.11.08~3722eadc/other-2026.11.08~3722eadc/' mismatch.log > other-file.log
expect_unchanged "mismatch of another archive is not adopted" other-file.log
printf 'echo "%s"\n' "$(cat mismatch.log)" > command.log
expect_unchanged "quoted command output is not a mismatch diagnostic" command.log

mkdir -p package/other
cp "$pkg/Makefile" package/other/Makefile
if adopt_local_git_tarball_hash package/other mismatch.log; then
    echo "FAIL: another package was adopted" >&2
    exit 1
fi
cmp "$pkg/Makefile" package/other/Makefile
echo "PASS: another package is not adopted"

# 镜像站下载的文件校验失败由 download.pl 输出，不能被当成本地打包处理。
write_makefile git "$pinned_sha" "$upstream_hash"
printf 'SHA256 sum of the downloaded file does not match (file: %s, requested: %s) - deleting download.\n' \
    "$local_hash" "$upstream_hash" > mirror.log
expect_unchanged "mirror download mismatch is not adopted" mirror.log

summary="$test_dir/summary.md"
write_makefile git "$pinned_sha" "$upstream_hash"
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$summary" \
    adopt_local_git_tarball_hash "$pkg" mismatch.log > annotations.log 2> /dev/null
grep -q '^::warning title=' annotations.log
grep -qF "$local_hash" "$summary"
echo "PASS: GitHub annotation and step summary are written"

# 从入口读取实际预检函数，覆盖逐包重试、最终全量复查及失败中止。
source <(sed 's/\r$//' "$REPO_ROOT/build.sh" | \
    sed -n '/^retry_failed_downloads_verbose() {$/,/^# 读取设备元信息/{ /^# /d; p; }')

make() {
    printf '%s\n' "$*" >> make-calls.log
    if [[ $1 == "$pkg/download" && $2 == V=s ]]; then
        if grep -qx "PKG_MIRROR_HASH:=$local_hash" "$pkg/Makefile"; then
            [[ ${force_retry_failure:-0} == 0 ]]
            return
        fi
        cat "$retry_fixture"
    elif [[ $1 == download ]]; then
        if grep -qx "PKG_MIRROR_HASH:=$local_hash" "$pkg/Makefile"; then
            [[ ${force_retry_failure:-0} == 0 ]] && return 0
        fi
    else
        echo "FAIL: unexpected make arguments: $*" >&2
        return 99
    fi
    echo "ERROR: $pkg failed to build."
    # OpenWrt 的并行下载可能在输出包错误后仍返回 0，预检还必须检查日志。
    [[ $1 == download ]]
}

write_makefile git "$pinned_sha" "$upstream_hash"
: > make-calls.log
retry_fixture=mismatch.log
preflight_download_sources > preflight.log 2>&1
[[ $(wc -l < make-calls.log) == 4 ]]
grep -qx "PKG_MIRROR_HASH:=$local_hash" "$pkg/Makefile"
echo "PASS: preflight repairs the known hash, retries and rechecks all downloads"

write_makefile git "$pinned_sha" "$upstream_hash"
: > make-calls.log
retry_fixture=unknown-hash.log
if preflight_download_sources > preflight.log 2>&1; then
    echo "FAIL: preflight accepted an unknown hash" >&2
    exit 1
fi
[[ $(wc -l < make-calls.log) == 3 ]]
grep -qx "PKG_MIRROR_HASH:=$upstream_hash" "$pkg/Makefile"
echo "PASS: preflight stops on an unknown hash even if make download exits zero"

write_makefile git "$pinned_sha" "$upstream_hash"
: > make-calls.log
retry_fixture=mismatch.log
force_retry_failure=1
if preflight_download_sources > preflight.log 2>&1; then
    echo "FAIL: preflight accepted a failed corrected download" >&2
    exit 1
fi
[[ $(wc -l < make-calls.log) == 4 ]]
echo "PASS: a failed download after hash repair still stops compilation"
