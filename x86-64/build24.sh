#!/bin/bash

set -e  # 遇错立即退出

# ====== 环境变量（由 CI 传入）======
PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}
ENABLE_PPPOE=${ENABLE_PPPOE:-"false"}
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

DATE_STR=$(date +%Y%m%d)
BASE_NAME="ImmortalWrt-24.10-OpenClash"

echo "🚀 开始构建双版本固件（generic + efi）"
echo "固件大小: ${PROFILE}MB | Docker: $INCLUDE_DOCKER"

# ====== 清理并准备 files 目录 ======
rm -rf files generic-files efi-files
mkdir -p files/etc/config

# 公共配置（PPPoE）
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ====== 下载 OpenClash .ipk（公共）======
echo "📥 下载 OpenClash .ipk..."
OPENCLASH_IPK_URL=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | \
    grep -o 'https://[^"]*luci-app-openclash[^"]*all\.ipk' | head -n1)

if [ -z "$OPENCLASH_IPK_URL" ]; then
    echo "❌ 无法获取 OpenClash .ipk"
    exit 1
fi

wget -qO /tmp/luci-app-openclash.ipk "$OPENCLASH_IPK_URL"

# ====== 下载 Clash.Meta 内核（公共）======
echo "📥 下载 Clash.Meta 内核..."
mkdir -p /tmp/clash-core

CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
    grep -o 'https://[^"]*linux-amd64-v3\.tar\.gz' | head -n1)

if [ -z "$CLASH_META_URL" ]; then
    echo "⚠️ v3 内核未找到，回退到通用 amd64..."
    CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
        grep -o 'https://[^"]*linux-amd64\.tar\.gz' | head -n1)
fi

if [ -z "$CLASH_META_URL" ]; then
    echo "❌ 无法下载内核"
    exit 1
fi

wget -qO- "$CLASH_META_URL" | tar -xz -C /tmp/clash-core clash.meta
chmod +x /tmp/clash-core/clash.meta

# GeoIP / GeoSite
wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O /tmp/GeoIP.dat
wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O /tmp/GeoSite.dat

# ====== 定义公共软件包 ======
PACKAGES=""
PACKAGES="$PACKAGES curl wget ca-certificates"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# ====== 准备 generic 版本的 files ======
echo "🔧 准备 generic (BIOS) 版本..."
cp -r files generic-files
mkdir -p generic-files/packages
cp /tmp/luci-app-openclash.ipk generic-files/packages/
mkdir -p generic-files/etc/openclash/core
cp /tmp/clash-core/clash.meta generic-files/etc/openclash/core/
cp /tmp/GeoIP.dat /tmp/GeoSite.dat generic-files/etc/openclash/

# ====== 准备 efi 版本的 files ======
echo "🔧 准备 efi (UEFI) 版本..."
cp -r files efi-files
mkdir -p efi-files/packages
cp /tmp/luci-app-openclash.ipk efi-files/packages/
mkdir -p efi-files/etc/openclash/core
cp /tmp/clash-core/clash.meta efi-files/etc/openclash/core/
cp /tmp/GeoIP.dat /tmp/GeoSite.dat efi-files/etc/openclash/

# ====== 构建 generic 版本 ======
echo "📦 构建 generic (BIOS) 固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="./generic-files" \
    ROOTFS_PARTSIZE="$PROFILE"

# ====== 构建 efi 版本 ======
echo "📦 构建 efi (UEFI) 固件..."
make image \
    PROFILE="x86-64-efi" \
    PACKAGES="$PACKAGES" \
    FILES="./efi-files" \
    ROOTFS_PARTSIZE="$PROFILE"

# ====== 收集输出文件 ======
OUTPUT_DIR="bin/targets/x86/64"

# Generic
GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*squashfs-combined.img.gz" | head -n1)
if [ -n "$GENERIC_IMG" ] && [ -f "$GENERIC_IMG" ]; then
    cp "$GENERIC_IMG" "./${BASE_NAME}-generic-${DATE_STR}.img.gz"
    echo "✅ 已生成: ${BASE_NAME}-generic-${DATE_STR}.img.gz （BIOS/MBR）"
else
    echo "❌ generic 固件生成失败！"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

# EFI
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*squashfs-combined.img.gz" | head -n1)
if [ -n "$EFI_IMG" ] && [ -f "$EFI_IMG" ]; then
    cp "$EFI_IMG" "./${BASE_NAME}-efi-${DATE_STR}.img.gz"
    echo "✅ 已生成: ${BASE_NAME}-efi-${DATE_STR}.img.gz （UEFI/GPT）"
else
    echo "❌ efi 固件生成失败！"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

# ====== 生成 version.txt ======
cat > "version-${DATE_STR}.txt" << EOF
固件名称: $BASE_NAME
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
架构: x86-64
版本:
  - ${BASE_NAME}-generic-${DATE_STR}.img.gz （传统 BIOS 启动）
  - ${BASE_NAME}-efi-${DATE_STR}.img.gz （UEFI 启动）
插件: OpenClash (官方 .ipk + Meta v3)
说明: 未预设 root 密码，首次登录请通过 Web 设置
EOF

echo "🎉 双版本构建完成！"
