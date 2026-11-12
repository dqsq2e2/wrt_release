#!/usr/bin/env bash

# 源码包下载阶段的修正，由 build.sh 在构建目录内调用。

# 仅兼容 firewall4 固定提交在 ubuntu-24.04 runner 上重复得到的已知打包哈希。
# 不接受任意本地哈希，也不修改源码提交；其他版本、包和镜像下载错误仍由预检拦截。
# 修改后必须再次运行 make download，继续验证缓存文件或重新下载的文件。
# 参数：$1 包路径（如 package/network/config/firewall4），$2 该包 V=s 重试的日志。
# 返回 0 表示已修正 Makefile，可以再次下载。
adopt_local_git_tarball_hash() {
    local package_target=$1
    local retry_log=$2
    local makefile="$package_target/Makefile"
    local mismatch
    local file
    local expected
    local actual
    local pinned_sha=3722eadc088c3ab81389596ca9796112b436583a
    local upstream_hash=a95c6cfe419c7d4e22bda5608aa6e46c67dadc9c7096879702d614cc498759d0
    local runner_hash=9ce4fee1c5f90e5b097216ef49c8ec981adc5911939622d031f555d103a58ba3

    [[ $package_target == package/network/config/firewall4 ]] || return 1

    mismatch=$(sed -nE 's/^Hash mismatch for file ([^:]+): expected ([0-9a-f]{64}), got ([0-9a-f]{64})$/\1 \2 \3/p' "$retry_log" | tail -n 1)
    [[ -n $mismatch ]] || return 1
    read -r file expected actual <<< "$mismatch"

    [[ $file == firewall4-2026.11.08~3722eadc.tar.zst \
        && $expected == "$upstream_hash" && $actual == "$runner_hash" ]] || return 1

    if [[ ! -f $makefile ]] \
        || ! grep -qE '^PKG_SOURCE_PROTO[[:space:]]*:=[[:space:]]*git[[:space:]]*$' "$makefile" \
        || ! grep -qE "^PKG_SOURCE_VERSION[[:space:]]*:=[[:space:]]*${pinned_sha}[[:space:]]*\$" "$makefile" \
        || ! grep -qE "^PKG_MIRROR_HASH[[:space:]]*:=[[:space:]]*${expected}[[:space:]]*\$" "$makefile"; then
        echo "$package_target: $file 不符合已知 git 打包哈希兼容条件，不自动修正。" >&2
        return 1
    fi

    sed -i -E "s/^(PKG_MIRROR_HASH[[:space:]]*:=[[:space:]]*)${expected}/\1${actual}/" "$makefile" || return 1
    echo "Warning: $package_target 已应用 $file 的已知 runner 哈希兼容值：$expected -> $actual，重新校验中。" >&2
    if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
        echo "::warning title=源码包哈希已自动修正::$package_target ($file): $expected -> $actual"
    fi
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf -- '- `%s`：本地打包哈希与上游不一致，已改用本机生成值 `%s`（上游 `%s`）\n' \
            "$package_target" "$actual" "$expected" >> "$GITHUB_STEP_SUMMARY"
    fi
}
