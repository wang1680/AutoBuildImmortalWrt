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

WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ====== 基础配置 ======
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ====== 下载 OpenClash v0.47.028（最新稳定版）======
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_VERSION="0.47.028"
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/luci-app-openclash_${OPENCLASH_VERSION}-all.ipk"

if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused \
    -O luci-app-openclash.ipk "$OPENCLASH_URL"; then
    
    echo "⚠️ 官方源失败，尝试通过 ghproxy.com 镜像下载..."
    MIRROR_URL="https://ghproxy.com/${OPENCLASH_URL}"
    
    if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused \
        -O luci-app-openclash.ipk "$MIRROR_URL"; then
        
        echo "❌ 所有下载方式均失败！请检查版本是否存在。"
        exit 1
    fi
fi

echo "✅ OpenClash v${OPENCLASH_VERSION} 下载成功"

# ====== 下载 Clash.Meta 内核 ======
echo "📥 下载 Clash.Meta 内核..."
mkdir -p clash-core

META_URL_V3="https://github.com/MetaCubeX/Clash.Meta/releases/latest/download/clash.meta-linux-amd64-v3.tar.gz"
if wget -q --timeout=30 --tries=2 -L --retry-connrefused -O- "$META_URL_V3" | tar -xz -C clash-core clash.meta 2>/dev/null; then
    echo "✅ 使用 v3 内核"
else
    echo "⚠️ v3 内核下载失败，回退到通用版本..."
    META_URL="https://github.com/MetaCubeX/Clash.Meta/releases/latest/download/clash.meta-linux-amd64.tar.gz"
    if ! wget -q --timeout=30 --tries=2 -L --retry-connrefused -O- "$META_URL" | tar -xz -C clash-core clash.meta; then
        echo "❌ Clash.Meta 内核下载失败"
        exit 1
    fi
fi

chmod +x clash-core/clash.meta

# GeoIP / GeoSite
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O GeoIP.dat
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O GeoSite.dat

echo "✅ 内核与规则准备完毕"

# ====== 软件包列表 ======
PACKAGES="curl wget ca-certificates"
PACKAGES="$PACKAGES luci-theme-argon luci-app-argon-config"
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

# ====== 准备文件系统 ======
setup_files() {
    local type="$1"
    cp -r files "${type}-files"
    mkdir -p "${type}-files/packages"
    cp luci-app-openclash.ipk "${type}-files/packages/"
    mkdir -p "${type}-files/etc/openclash/core"
    cp clash-core/clash.meta "${type}-files/etc/openclash/core/"
    cp GeoIP.dat GeoSite.dat "${type}-files/etc/openclash/"
}

setup_files "generic"
setup_files "efi"

# ====== 构建 ======
echo "📦 构建 generic 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

echo "📦 构建 efi 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# ====== 输出 ======
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

cp "$GENERIC_IMG" "/builder/${BASE_NAME}-generic-${DATE_STR}.img.gz"
cp "$EFI_IMG" "/builder/${BASE_NAME}-efi-${DATE_STR}.img.gz"

cat > "/builder/version-${DATE_STR}.txt" << EOF
固件名称: $BASE_NAME
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
包含:
  - ${BASE_NAME}-generic-${DATE_STR}.img.gz （BIOS/MBR 启动）
  - ${BASE_NAME}-efi-${DATE_STR}.img.gz （UEFI/GPT 启动）
插件: OpenClash v${OPENCLASH_VERSION} + Clash.Meta (v3)
说明: 首次登录需通过 Web 设置 root 密码
EOF

echo "🎉 构建成功！"
