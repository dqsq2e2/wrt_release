#!/usr/bin/env bash

set -euo pipefail

FORCE_BUILD=${FORCE_BUILD:-false}
WATCH_MODEL=${WATCH_MODEL:-all}
OUTPUT_FILE=${GITHUB_OUTPUT:-/dev/stdout}
SOURCE_COMMIT=${GITHUB_SHA:-HEAD}
LEGACY_FINGERPRINT_COMMITS=(
    18f4b5355c012f625726a6268ce760db2c38144b
)

MODELS=(
    MEDIATEK-WIFI-YES
    MEDIATEK-WIFI-NO
    clx_s20p_immwrt
    jdcloud_ax6000_immwrt
)

read_ini_value() {
    local file=$1
    local key=$2
    sed -n "s/^${key}=//p" "$file" | head -n 1
}

append_git_hash_file() {
    local commit=$1
    local file=$2
    local file_hash
    if git cat-file -e "${commit}:${file}" 2>/dev/null; then
        file_hash=$(git show "${commit}:${file}" | sha256sum | awk '{print $1}')
        printf '%s\0%s  %s\n' "$file" "$file_hash" "$file"
    fi
}

calculate_git_hash() {
    local commit=$1
    shift
    local file
    for file in "$@"; do
        append_git_hash_file "$commit" "$file"
    done | sha256sum | awk '{print $1}'
}

ensure_git_commit() {
    local commit=$1
    if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
        git fetch --quiet --no-tags --depth=1 origin "$commit"
    fi
}

matrix='[]'

for model in "${MODELS[@]}"; do
    if [[ $WATCH_MODEL != all && $WATCH_MODEL != "$model" ]]; then
        continue
    fi

    ini_file="wrt_core/compilecfg/${model}.ini"
    config_file="wrt_core/deconfig/${model}.config"
    if [[ ! -f $ini_file || ! -f $config_file ]]; then
        echo "错误：缺少 $model 的 compilecfg 或 deconfig 文件" >&2
        exit 1
    fi

    repo_url=$(read_ini_value "$ini_file" REPO_URL)
    repo_branch=$(read_ini_value "$ini_file" REPO_BRANCH)
    repo_branch=${repo_branch:-main}
    commit_hash=$(read_ini_value "$ini_file" COMMIT_HASH)
    commit_hash=${commit_hash:-none}

    if [[ $commit_hash != none ]]; then
        upstream_sha=$commit_hash
    else
        upstream_sha=$(git ls-remote "$repo_url" "refs/heads/$repo_branch" | awk 'NR == 1 {print $1}')
    fi

    if [[ -z $upstream_sha ]]; then
        echo "错误：无法获取 $repo_url 分支 $repo_branch 的远端提交" >&2
        exit 1
    fi

    config_fragments=$(read_ini_value "$ini_file" CONFIG_FRAGMENTS)
    hash_files=(
        "$ini_file"
        "$config_file"
        wrt_core/deconfig/compile_base.config
        build.sh
        wrt_core/update.sh
        wrt_core/pre_clone_action.sh
        .github/workflows/release_wrt.yml
    )
    legacy_hash_files=(
        "$ini_file"
        "$config_file"
        wrt_core/deconfig/compile_base.config
        build.sh
        wrt_core/update.sh
        wrt_core/pre_clone_action.sh
        wrt_core/ci/detect_upstream_changes.sh
        .github/workflows/release_wrt.yml
        .github/workflows/upstream_watch.yml
    )

    IFS=',' read -r -a fragments <<<"$config_fragments"
    for fragment in "${fragments[@]}"; do
        fragment=${fragment//[[:space:]]/}
        if [[ -n $fragment ]]; then
            hash_files+=("wrt_core/deconfig/fragments/${fragment}.config")
            legacy_hash_files+=("wrt_core/deconfig/fragments/${fragment}.config")
        fi
    done

    while IFS= read -r module_file; do
        hash_files+=("$module_file")
        legacy_hash_files+=("$module_file")
    done < <(find wrt_core/modules -type f -name '*.sh' -print | sort)

    while IFS= read -r patch_file; do
        hash_files+=("$patch_file")
        legacy_hash_files+=("$patch_file")
    done < <(find wrt_core/patches -type f -print | sort)

    config_hash=$(calculate_git_hash "$SOURCE_COMMIT" "${hash_files[@]}")
    fingerprint=$(printf '%s\n%s\n%s\n%s\n' "$repo_url" "$repo_branch" "$upstream_sha" "$config_hash" | sha256sum | awk '{print $1}')
    cache_key="upstream-watch-${model}-${fingerprint}"
    cache_match=$(gh cache list --key "$cache_key" --limit 100 --json key --jq '.[].key' | grep -Fx "$cache_key" || true)

    if [[ $FORCE_BUILD != true && -z $cache_match ]]; then
        for legacy_commit in "${LEGACY_FINGERPRINT_COMMITS[@]}"; do
            ensure_git_commit "$legacy_commit"
            legacy_current_hash=$(calculate_git_hash "$legacy_commit" "${hash_files[@]}")
            if [[ $legacy_current_hash != "$config_hash" ]]; then
                continue
            fi

            legacy_config_hash=$(calculate_git_hash "$legacy_commit" "${legacy_hash_files[@]}")
            legacy_fingerprint=$(printf '%s\n%s\n%s\n%s\n' "$repo_url" "$repo_branch" "$upstream_sha" "$legacy_config_hash" | sha256sum | awk '{print $1}')
            legacy_cache_key="upstream-watch-${model}-${legacy_fingerprint}"
            cache_match=$(gh cache list --key "$legacy_cache_key" --limit 100 --json key --jq '.[].key' | grep -Fx "$legacy_cache_key" || true)
            if [[ -n $cache_match ]]; then
                break
            fi
        done
    fi

    if [[ $FORCE_BUILD == true || -z $cache_match ]]; then
        matrix=$(jq -c \
            --arg model "$model" \
            --arg upstream_sha "$upstream_sha" \
            --arg fingerprint "$fingerprint" \
            --arg repo_url "$repo_url" \
            --arg repo_branch "$repo_branch" \
            '. + [{model: $model, upstream_sha: $upstream_sha, fingerprint: $fingerprint, repo_url: $repo_url, repo_branch: $repo_branch}]' \
            <<<"$matrix")
        status=build
    else
        status=skip
    fi

    short_sha=${upstream_sha:0:12}
    echo "$model: $status ($repo_branch@$short_sha)"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '| `%s` | `%s` | `%s` | `%s` |\n' "$model" "$repo_branch" "$short_sha" "$status" >>"$GITHUB_STEP_SUMMARY"
    fi
done

count=$(jq 'length' <<<"$matrix")
matrix_payload=$(jq -cn --argjson include "$matrix" '{include: $include}')
echo "count=$count" >>"$OUTPUT_FILE"
echo "matrix=$matrix_payload" >>"$OUTPUT_FILE"
