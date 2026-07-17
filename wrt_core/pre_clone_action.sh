#!/usr/bin/env bash

# Determine wrt_core path
if [ -d "wrt_core" ]; then
    WRT_CORE_PATH="wrt_core"
elif [ -d "../wrt_core" ]; then
    WRT_CORE_PATH="../wrt_core"
else
    # Fallback to script directory if wrt_core is current dir or relative
    WRT_CORE_PATH=$(dirname "$0")
fi

BASE_PATH=$(cd "$WRT_CORE_PATH" && pwd)

source "$BASE_PATH/modules/network.sh"

Dev=$1

INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}
# GitHub Actions usually runs in root of repo, so build dir should be relative to repo root
# We need to construct absolute path or ensure context is correct.
# Assuming this script is run from repo root or wrt_core.
# Let's use relative path "action_build" next to wrt_core if possible or just use what works.
# Original script used BASE_PATH/action_build.
BUILD_DIR="$BASE_PATH/../action_build"

echo $REPO_URL $REPO_BRANCH
git_retry clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$BUILD_DIR"

# Cache identity includes the actual upstream commit so incompatible host/toolchain
# caches are not treated as an exact hit after the source branch advances.
SOURCE_HASH=$(git -C "$BUILD_DIR" rev-parse HEAD)
if [[ $COMMIT_HASH != "none" ]]; then
    SOURCE_HASH=$COMMIT_HASH
fi
echo "$REPO_URL/$REPO_BRANCH/$SOURCE_HASH" >"$BASE_PATH/../repo_flag"

# GitHub Action 移除国内下载源
PROJECT_MIRRORS_FILE="$BUILD_DIR/scripts/projectsmirrors.json"

if [ -f "$PROJECT_MIRRORS_FILE" ]; then
    sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$PROJECT_MIRRORS_FILE"
fi
