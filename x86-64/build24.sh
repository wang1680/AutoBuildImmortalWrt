#!/bin/bash

set -e

PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}
ENABLE_PPPOE=${ENABLE_PPPOE:-"false"}
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

DATE_STR=$(date +%Y%m%d)
BASE_NAME="ImmortalWrt-24.10-OpenClash"

echo "🚀 开始构建双版本固件（generic + efi）"
echo "固件大小: ${PROFILE}MB | Docker: $INCLUDE_DOCKER"

# ====== 关键修改：使用 /tmp/build 而非当前目录 ======
WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ====== 创建公共 files ======
mkdir -p files/etc/config

cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ====== 下载 OpenClash .ipk ======
echo "📥 下载 OpenClash .ipk..."
OPENCLASH_IPK_URL=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | \
    grep -o 'https://[^"]*luci-app-openclash[^"]*all\.ipk' | head -n1)

if [ -z "$OPENCLASH_IPK_URL" ]; then
    echo "❌ 无法获取 OpenClash .ipk"
    exit 1
fi

wget -qO luci-app-openclash.ipk "$OPENCLASH_IPK_URL"

# ====== 下载 Clash.Meta 内核 ======
echo "📥 下载 Clash.Meta 内核..."
mkdir -p clash-core
CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
    grep -o 'https://[^"]*linux-amd64-v3\.tar\.gz' | head -n1)

if [ -z "$CLASH_META_URL" ]; then
    CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
        grep -o 'https://[^"]*linux-amd64\.tar\.gz' | head -n1)
fi

if [ -z "$CLASH_META_URL" ]; then
    echo "❌ 无法下载内核"
    exit 1
fi

wget -qO- "$CLASH_META_URL" | tar -xz -C clash-core clash.meta
chmod +x clash-core/clash.meta

wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O GeoIP.dat
wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O GeoSite.dat

# ====== 软件包列表 ======
PACKAGES="curl wget ca-certificates luci-theme-argon luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn openssh-sftp-server luci-i18n-homeproxy-zh-cn"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# ====== 准备 generic ======
echo "🔧 准备 generic 版本..."
cp -r files generic-files
mkdir -p generic-files/packages
cp luci-app-openclash.ipk generic-files/packages/
mkdir -p generic-files/etc/openclash/core
cp clash-core/clash.meta generic-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

# ====== 准备 efi ======
echo "🔧 准备 efi 版本..."
cp -r files efi-files
mkdir -p efi-files/packages
cp luci-app-openclash.ipk efi-files/packages/
mkdir -p efi-files/etc/openclash/core
cp clash-core/clash.meta efi-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat efi-files/etc/openclash/

# ====== 构建 generic ======
echo "📦 构建 generic 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

# ====== 构建 efi ======
echo "📦 构建 efi 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# ====== 复制输出到挂载目录（关键！）======
OUTPUT_DIR="bin/targets/x86/64"

GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*squashfs-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*squashfs-combined.img.gz" | head -n1)

if [ -z "$GENERIC_IMG" ] || [ ! -f "$GENERIC_IMG" ]; then
    echo "❌ generic 固件缺失"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

if [ -z "$EFI_IMG" ] || [ ! -f "$EFI_IMG" ]; then
    echo "❌ efi 固件缺失"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

# 复制到挂载点（通常是 /builder）
cp "$GENERIC_IMG" "/builder/${BASE_NAME}-generic-${DATE_STR}.img.gz"
cp "$EFI_IMG" "/builder/${BASE_NAME}-efi-${DATE_STR}.img.gz"

cat > "/builder/version-${DATE_STR}.txt" << EOF
固件名称: $BASE_NAME
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
包含:
  - ${BASE_NAME}-generic-${DATE_STR}.img.gz （BIOS）
  - ${BASE_NAME}-efi-${DATE_STR}.img.gz （UEFI）
说明: 无 root 密码，首次登录需设置
EOF

echo "🎉 双版本构建成功！"
