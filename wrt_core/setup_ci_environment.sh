#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_CODENAME:-} != noble || $(dpkg --print-architecture) != amd64 ]]; then
    echo "CI build setup requires Ubuntu 24.04 (amd64)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export APT_CONFIG
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
APT_CONFIG="$tmp_dir/apt.conf"
printf 'APT::Install-Recommends "false";\n' > "$APT_CONFIG"

if ! command -v curl >/dev/null || ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
    apt-get update
    apt-get install -y ca-certificates curl
fi

curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
    https://build-scripts.immortalwrt.org/init_build_environment.sh \
    -o "$tmp_dir/init.sh"

# Keep the runner's Ubuntu mirrors and avoid upgrading the runner's base OS.
sed -i -E '/^[[:blank:]]*apt(-get)?[[:blank:]]+(full|dist)-upgrade([[:blank:]]|$)/d;
           /^[[:blank:]]*check_network[[:blank:]]*$/d' "$tmp_dir/init.sh"

TMPDIR="$tmp_dir" bash -e "$tmp_dir/init.sh"
apt-get install -y dos2unix libfuse-dev
for tool in gcc g++ clang go node yarn gh ccache upx padjffs2 po2lmo; do
    command -v "$tool" >/dev/null || { echo "Missing WRT build tool: $tool" >&2; exit 1; }
done
apt-get clean
