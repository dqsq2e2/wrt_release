#!/usr/bin/env bash

# 精确追踪：找出哪个已启用的包导致 iptables 被拉入

set -e

BUILD_DIR="${1:-.}"

if [ ! -f "$BUILD_DIR/.config" ]; then
    echo "错误：未找到 .config 文件"
    exit 1
fi

cd "$BUILD_DIR"

echo "=========================================="
echo "精确追踪：iptables 模块的罪魁祸首"
echo "=========================================="
echo ""

# 第一步：列出所有已启用的包
echo "第一步：提取所有已启用的包..."
ENABLED_PACKAGES=$(grep "^CONFIG_PACKAGE_.*=y$" .config | sed 's/CONFIG_PACKAGE_//g' | sed 's/=y//g')
ENABLED_COUNT=$(echo "$ENABLED_PACKAGES" | wc -l)
echo "找到 $ENABLED_COUNT 个已启用的包"
echo ""

# 第二步：检查每个已启用的包是否依赖 iptables 模块
echo "第二步：检查哪些已启用的包依赖 iptables 模块..."
echo "=========================================="

CULPRITS=()

for pkg in $ENABLED_PACKAGES; do
    # 查找这个包的 Makefile
    makefile=$(find feeds package -path "*/${pkg}/Makefile" -type f 2>/dev/null | head -1)
    
    if [ -z "$makefile" ]; then
        continue
    fi
    
    # 检查 DEPENDS 字段
    if grep -q "DEPENDS.*+kmod-ipt-" "$makefile" 2>/dev/null || \
       grep -q "DEPENDS.*+kmod-nf-ipt" "$makefile" 2>/dev/null || \
       grep -q "DEPENDS.*+iptables-mod-" "$makefile" 2>/dev/null; then
        
        echo "✗ 找到罪魁祸首: $pkg"
        echo "  Makefile: $makefile"
        echo "  依赖:"
        grep "DEPENDS" "$makefile" | head -3 | sed 's/^/    /'
        echo ""
        CULPRITS+=("$pkg")
    fi
    
    # 检查 Kconfig 中的 select 语句
    if grep -E "select PACKAGE_kmod-ipt-|select PACKAGE_kmod-nf-ipt|select PACKAGE_iptables-mod-" "$makefile" 2>/dev/null | grep -v "^#" > /dev/null; then
        if [[ ! " ${CULPRITS[@]} " =~ " ${pkg} " ]]; then
            echo "✗ 找到罪魁祸首 (通过 select): $pkg"
            echo "  Makefile: $makefile"
            echo "  Select 语句:"
            grep -E "select PACKAGE_kmod-ipt-|select PACKAGE_kmod-nf-ipt|select PACKAGE_iptables-mod-" "$makefile" | grep -v "^#" | head -5 | sed 's/^/    /'
            echo ""
            CULPRITS+=("$pkg")
        fi
    fi
done

echo ""
echo "=========================================="
echo "第三步：分析罪魁祸首"
echo "=========================================="

if [ ${#CULPRITS[@]} -eq 0 ]; then
    echo "⚠️  未找到直接依赖 iptables 的已启用包"
    echo ""
    echo "可能的原因："
    echo "1. 默认包列表（target 的 Makefile 中定义）"
    echo "2. 间接依赖（A 依赖 B，B 依赖 iptables）"
    echo "3. Kconfig 的 default y if 条件"
    echo ""
    
    # 检查 target 的默认包
    echo "检查 target 默认包..."
    TARGET_MAKEFILE=$(find target -name "Makefile" -path "*/mediatek/filogic/*" 2>/dev/null | head -1)
    if [ -n "$TARGET_MAKEFILE" ]; then
        echo "Target Makefile: $TARGET_MAKEFILE"
        if grep -q "kmod-ipt-\|kmod-nf-ipt" "$TARGET_MAKEFILE" 2>/dev/null; then
            echo "✗ Target 默认包中包含 iptables 模块！"
            grep "kmod-ipt-\|kmod-nf-ipt" "$TARGET_MAKEFILE" | sed 's/^/  /'
        fi
    fi
else
    echo "找到 ${#CULPRITS[@]} 个罪魁祸首包："
    for culprit in "${CULPRITS[@]}"; do
        echo "  - $culprit"
    done
    echo ""
    
    echo "建议："
    echo "1. 禁用这些包（如果不需要）"
    echo "2. 或者修改这些包的 Makefile，移除对 iptables 的依赖"
    echo "3. 或者接受冲突，尝试编译（可能会失败）"
fi

echo ""
echo "=========================================="
echo "第四步：检查 OpenClash 的条件依赖"
echo "=========================================="

# 特别检查 OpenClash
if grep -q "^CONFIG_PACKAGE_luci-app-openclash=y" .config; then
    echo "OpenClash 已启用，检查其条件依赖..."
    
    OC_MAKEFILE=$(find feeds -path "*/luci-app-openclash/Makefile" 2>/dev/null | head -1)
    if [ -n "$OC_MAKEFILE" ]; then
        echo ""
        echo "OpenClash Makefile: $OC_MAKEFILE"
        echo ""
        echo "条件配置:"
        sed -n '/define Package.*config/,/endef/p' "$OC_MAKEFILE" | grep -E "config|default" | sed 's/^/  /'
        echo ""
        
        # 检查 firewall4 状态
        if grep -q "^CONFIG_PACKAGE_firewall4=y" .config; then
            echo "✓ firewall4 已启用"
            echo "  → OpenClash 应该使用 kmod-nft-tproxy (nftables)"
            echo "  → OpenClash 不应该启用 kmod-ipt-nat (iptables)"
        else
            echo "✗ firewall4 未启用"
            echo "  → OpenClash 会启用 kmod-ipt-nat (iptables)"
        fi
        
        # 检查实际配置
        echo ""
        echo "实际配置:"
        echo "  kmod-nft-tproxy: $(grep '^CONFIG_PACKAGE_kmod-nft-tproxy=' .config || echo '未设置')"
        echo "  kmod-ipt-nat: $(grep '^CONFIG_PACKAGE_kmod-ipt-nat=' .config || echo '未设置')"
    fi
fi

echo ""
echo "=========================================="
echo "第五步：检查 .config 生成时间线"
echo "=========================================="

# 检查配置文件中 firewall4 的位置
echo "在 .config 中搜索 firewall4 相关配置..."
grep -n "firewall4" .config | head -5

echo ""
echo "在 .config 中搜索 kmod-ipt-nat 相关配置..."
grep -n "kmod-ipt-nat" .config | head -5

echo ""
echo "=========================================="
echo "分析完成"
echo "=========================================="
