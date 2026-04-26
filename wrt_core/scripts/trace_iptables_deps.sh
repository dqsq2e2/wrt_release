#!/usr/bin/env bash

# 依赖追踪脚本 - 找出哪些包依赖了 iptables 模块

set -e

BUILD_DIR="${1:-.}"

if [ ! -f "$BUILD_DIR/.config" ]; then
    echo "错误：未找到 .config 文件"
    echo "用法: $0 [BUILD_DIR]"
    exit 1
fi

echo "=========================================="
echo "iptables 依赖追踪分析"
echo "=========================================="
echo ""

# 冲突的 iptables 包列表
CONFLICT_PACKAGES=(
    "kmod-ipt-nat"
    "kmod-ipt-nat6"
    "kmod-ipt-physdev"
    "kmod-nf-ipt"
    "kmod-nf-ipt6"
    "kmod-ipt-core"
    "kmod-ipt-conntrack"
    "kmod-ipt-extra"
    "kmod-nft-compat"
    "iptables-mod-extra"
)

echo "第一步：检查哪些冲突包被启用"
echo "=========================================="
ENABLED_CONFLICTS=()
for pkg in "${CONFLICT_PACKAGES[@]}"; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$BUILD_DIR/.config"; then
        echo "✗ $pkg (已启用)"
        ENABLED_CONFLICTS+=("$pkg")
    fi
done
echo ""

if [ ${#ENABLED_CONFLICTS[@]} -eq 0 ]; then
    echo "✓ 没有冲突的 iptables 包被启用"
    exit 0
fi

echo "第二步：分析依赖关系"
echo "=========================================="
echo "正在生成依赖图..."
echo ""

cd "$BUILD_DIR"

# 使用 make 的依赖追踪功能
for conflict_pkg in "${ENABLED_CONFLICTS[@]}"; do
    echo "----------------------------------------"
    echo "追踪: $conflict_pkg"
    echo "----------------------------------------"
    
    # 方法1：搜索 Makefile 中的 DEPENDS
    echo ">> 搜索直接依赖此包的 Makefile..."
    find feeds package -name "Makefile" -type f 2>/dev/null | while read makefile; do
        if grep -q "DEPENDS.*+${conflict_pkg}" "$makefile" 2>/dev/null; then
            pkg_name=$(dirname "$makefile" | xargs basename)
            echo "   - $pkg_name (Makefile: $makefile)"
            
            # 检查这个包是否被启用
            if grep -q "^CONFIG_PACKAGE_${pkg_name}=y" .config 2>/dev/null; then
                echo "     └─> ✗ $pkg_name 已启用"
            fi
        fi
    done
    
    # 方法2：搜索 Kconfig 中的 select 和 default
    echo ">> 搜索 Kconfig 中的 select/default 语句..."
    find feeds package -name "Config.in" -o -name "Makefile" -type f 2>/dev/null | while read kconfig; do
        if grep -E "(select|default y if).*${conflict_pkg}" "$kconfig" 2>/dev/null | grep -v "^#"; then
            echo "   - 发现于: $kconfig"
            grep -B5 -A2 -E "(select|default y if).*${conflict_pkg}" "$kconfig" 2>/dev/null | grep -v "^--$"
        fi
    done
    
    echo ""
done

echo ""
echo "第三步：检查可能的根源包"
echo "=========================================="

# 检查常见的可能导致 iptables 依赖的包
SUSPECT_PACKAGES=(
    "luci-app-openclash"
    "luci-app-firewall"
    "firewall"
    "firewall4"
    "luci-app-turboacc"
    "luci-app-turboacc-mtk"
    "luci-app-dockerman"
    "docker"
    "dockerd"
)

for pkg in "${SUSPECT_PACKAGES[@]}"; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" .config 2>/dev/null; then
        echo "✓ $pkg 已启用"
        
        # 查找这个包的 Makefile
        makefile=$(find feeds package -path "*/${pkg}/Makefile" -type f 2>/dev/null | head -1)
        if [ -n "$makefile" ]; then
            echo "  Makefile: $makefile"
            echo "  依赖列表:"
            grep "DEPENDS" "$makefile" 2>/dev/null | head -5 || echo "    (未找到 DEPENDS)"
            
            # 检查是否有条件配置
            if grep -q "define Package.*config" "$makefile" 2>/dev/null; then
                echo "  条件配置:"
                sed -n '/define Package.*config/,/endef/p' "$makefile" 2>/dev/null | grep -E "(config|default)" | head -10
            fi
        fi
        echo ""
    fi
done

echo ""
echo "第四步：检查 .config 中的选择器"
echo "=========================================="
echo "搜索可能触发 iptables 的配置选项..."
echo ""

# 检查 firewall 相关配置
echo ">> Firewall 配置:"
grep -E "CONFIG_PACKAGE_firewall" .config | grep -v "^#" || echo "   (无)"
echo ""

# 检查是否有包通过 select 强制启用了 iptables
echo ">> 检查 .config 中的注释（可能包含依赖信息）:"
for conflict_pkg in "${ENABLED_CONFLICTS[@]}"; do
    echo "   $conflict_pkg:"
    grep -B2 "CONFIG_PACKAGE_${conflict_pkg}=y" .config | head -3
done

echo ""
echo "=========================================="
echo "分析完成"
echo "=========================================="
echo ""
echo "建议："
echo "1. 检查上述列出的包的 Makefile"
echo "2. 查看是否有 'default y if ! PACKAGE_firewall4' 这样的条件"
echo "3. 确认 firewall4 是否在 .config 中被正确启用"
echo "4. 考虑禁用导致冲突的根源包"
echo ""
