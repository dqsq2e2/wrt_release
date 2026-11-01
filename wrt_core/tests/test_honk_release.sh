#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/custom_feed.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
core_revision=eac5e0c5fba5078a7ff4517a3e3851e7fa0f4f8e
mkdir -p "$test_dir/release" "$test_dir/package"
cat > "$test_dir/package/Makefile" <<EOF
CORE_COMMIT:=$core_revision
-include \$(CURDIR)/generated-stage.mk
HONK_ASSET_AARCH64?=honk-core-\$(CORE_COMMIT)-aarch64.tar.gz
HONK_HASH_AARCH64?=SKIP
PKG_SOURCE:=\$(HONK_ASSET_AARCH64)
PKG_HASH:=\$(HONK_HASH_AARCH64)

print-source:
	@printf '%s\t%s\n' '\$(PKG_SOURCE)' '\$(PKG_HASH)'
EOF
for arch in x86_64 aarch64 armv7; do
    printf 'HONK_ASSET_%s:=honk-core-%s-%s.tar.gz\nHONK_HASH_%s:=%064d\n' \
        "${arch^^}" "$core_revision" "$arch" "${arch^^}" 1 >> "$test_dir/release/generated-stage.mk"
done
printf '{"core":{"commit":"%s"}}\n' "$core_revision" > "$test_dir/release/generated-provenance.json"

curl_retry() {
    local output_file=""
    local url="${!#}"
    while (( $# )); do
        case "$1" in
            -o) output_file="$2"; shift ;;
        esac
        shift
    done
    if [[ $url == https://api.github.com/repos/kenzok8/openwrt-honk/releases/tags/staging ]]; then
        cp "$test_dir/release-assets.json" "$output_file"
    else
        [[ $url == https://github.com/kenzok8/openwrt-honk/releases/download/staging/* ]]
        cp "$test_dir/release/${url##*/}" "$output_file"
    fi
}

mkdir -p "$test_dir/immutable"
cat > "$test_dir/immutable/Makefile" <<'EOF'
CORE_COMMIT:=eac5e0c5fba5078a7ff4517a3e3851e7fa0f4f8e
HONK_SOURCE_TAG?=source-123456789
HONK_SOURCE_URL?=https://github.com/kenzok8/openwrt-honk/releases/download/$(HONK_SOURCE_TAG)
HONK_ASSET_X86_64?=honk-core-$(CORE_COMMIT)-x86_64.tar.gz
HONK_ASSET_AARCH64?=honk-core-$(CORE_COMMIT)-aarch64.tar.gz
HONK_ASSET_ARMV7?=honk-core-$(CORE_COMMIT)-armv7.tar.gz
HONK_HASH_X86_64?=0000000000000000000000000000000000000000000000000000000000000001
HONK_HASH_AARCH64?=0000000000000000000000000000000000000000000000000000000000000002
HONK_HASH_ARMV7?=0000000000000000000000000000000000000000000000000000000000000003
EOF
prepare_honk_release "$test_dir/immutable" > "$test_dir/output" 2> "$test_dir/error"
grep -q 'skipping legacy staging metadata' "$test_dir/output"
[[ ! -e "$test_dir/immutable/generated-stage.mk" ]]
[[ ! -e "$test_dir/immutable/generated-provenance.json" ]]
echo "PASS: immutable source releases do not request removed staging metadata"

before=$(make --no-print-directory -C "$test_dir/package" print-source)
[[ $before == *$'\tSKIP' ]]
prepare_honk_release "$test_dir/package"
after=$(make --no-print-directory -C "$test_dir/package" print-source)
[[ $after == "$(printf 'honk-core-%s-aarch64.tar.gz\t%064d' "$core_revision" 1)" ]]
cmp "$test_dir/release/generated-provenance.json" "$test_dir/package/generated-provenance.json"
echo "PASS: release metadata replaces SKIP with SHA256 and supplies the installed provenance file"

first_hash=$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")
prepare_honk_release "$test_dir/package"
[[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
echo "PASS: repeated release preparation is idempotent"

# Model upstream main moving ahead of the core archives in the rolling release.
# Exercise the real history selection without making network requests.
cp "$test_dir/package/Makefile" "$test_dir/package-makefile"
mkdir -p "$test_dir/history/honk" "$test_dir/history/luci-app-honk" \
    "$test_dir/luci-app-honk"
cp "$test_dir/package/Makefile" "$test_dir/history/honk/Makefile"
cat > "$test_dir/history/luci-app-honk/Makefile" <<'EOF'
# published UI
PKG_SOURCE:=doona-published.tar.gz
PKG_SOURCE_URL:=https://github.com/kenzok8/openwrt-honk/releases/download/staging
PKG_HASH:=0000000000000000000000000000000000000000000000000000000000000001
EOF
printf '{"assets":[{"name":"doona-published.tar.gz","state":"uploaded","digest":"sha256:%064d"}]}\n' \
    1 > "$test_dir/release-assets.json"
git -C "$test_dir/history" init -q -b main
git -C "$test_dir/history" add .
git -C "$test_dir/history" -c user.name=Test -c user.email=test@example.invalid \
    commit --no-gpg-sign -qm 'Published package pair'
published_feed_revision=$(git -C "$test_dir/history" rev-parse HEAD)
# The next snapshot pins the same core, but its new UI archive is unpublished.
sed -i 's/doona-published/doona-unpublished/' "$test_dir/history/luci-app-honk/Makefile"
git -C "$test_dir/history" add .
git -C "$test_dir/history" -c user.name=Test -c user.email=test@example.invalid \
    commit --no-gpg-sign -qm 'Unpublished UI update'
sed -i "s/$core_revision/2222222222222222222222222222222222222222/" \
    "$test_dir/history/honk/Makefile" "$test_dir/package/Makefile"
printf 'unpublished UI\n' > "$test_dir/history/luci-app-honk/Makefile"
printf 'unpublished UI\n' > "$test_dir/luci-app-honk/Makefile"
git -C "$test_dir/history" add .
git -C "$test_dir/history" -c user.name=Test -c user.email=test@example.invalid \
    commit --no-gpg-sign -qm 'Unpublished core update'

git_retry() {
    if [[ $1 == clone ]]; then
        git clone --quiet --no-local --filter=blob:none --sparse --no-checkout \
            --single-branch -b main "$test_dir/history" "${!#}"
    else
        git "$@"
    fi
}
prepare_honk_release "$test_dir/package" > "$test_dir/output" 2> "$test_dir/error"
grep -q "$published_feed_revision" "$test_dir/output"
cmp "$test_dir/package-makefile" "$test_dir/package/Makefile"
cmp "$test_dir/release/generated-stage.mk" "$test_dir/package/generated-stage.mk"
grep -qx '# published UI' "$test_dir/luci-app-honk/Makefile"
[[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
echo "PASS: source/release skew selects both packages and skips unpublished Doona snapshots"

# A valid manifest with no matching source must leave both installed packages intact.
sed -i "s/$core_revision/3333333333333333333333333333333333333333/g" \
    "$test_dir/release/generated-stage.mk" "$test_dir/release/generated-provenance.json"
if prepare_honk_release "$test_dir/package" > "$test_dir/output" 2> "$test_dir/error"; then
    echo "FAIL: release with no matching source snapshot was accepted" >&2
    exit 1
fi
grep -q 'no Honk package snapshot matches published core' "$test_dir/error"
cmp "$test_dir/package-makefile" "$test_dir/package/Makefile"
grep -qx '# published UI' "$test_dir/luci-app-honk/Makefile"
[[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
sed -i "s/3333333333333333333333333333333333333333/$core_revision/g" \
    "$test_dir/release/generated-stage.mk" "$test_dir/release/generated-provenance.json"
echo "PASS: unavailable source snapshot fails without changing either package"

printf 'PKG_SOURCE_URL:=https://github.com/kenzok8/openwrt-honk/releases/download/staging/\n' \
    >> "$test_dir/release/generated-stage.mk"
prepare_honk_release "$test_dir/package"
cmp "$test_dir/release/generated-stage.mk" "$test_dir/package/generated-stage.mk"
first_hash=$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")
echo "PASS: upstream manifest may specify its GitHub release download URL"

assert_invalid_metadata() {
    if prepare_honk_release "$test_dir/package" > "$test_dir/output" 2> "$test_dir/error"; then
        echo "FAIL: invalid release metadata was accepted" >&2
        exit 1
    fi
    [[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
}

cp "$test_dir/release/generated-stage.mk" "$test_dir/stage"
sed -i "s/$core_revision/1111111111111111111111111111111111111111/g" "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'does not match CORE_COMMIT' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: a release for another core revision is rejected without changing package inputs"

sed -i 's/^HONK_HASH_AARCH64:=.*/HONK_HASH_AARCH64:=SKIP/' "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'no valid SHA256' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: skip markers cannot replace published SHA256 hashes"

printf '$(error unexpected make expression)\n' >> "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'invalid Honk release stage manifest' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: the manifest accepts only release asset and hash assignments"

printf '{"core":{"commit":"1111111111111111111111111111111111111111"}}\n' \
    > "$test_dir/release/generated-provenance.json"
assert_invalid_metadata
grep -q 'provenance does not match CORE_COMMIT' "$test_dir/error"
echo "PASS: mismatched provenance is rejected"

printf '{"core":{"commit":"%s"}}\n' "$core_revision" > "$test_dir/release/generated-provenance.json"
printf 'PKG_SOURCE_URL:=https://example.invalid/untrusted/\n' >> "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'invalid Honk release stage manifest' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: duplicate or foreign source URLs are rejected"

curl_retry() { return 22; }
assert_invalid_metadata
grep -q 'failed to fetch Honk release metadata' "$test_dir/error"
echo "PASS: metadata download failure stops preparation without installing partial files"
