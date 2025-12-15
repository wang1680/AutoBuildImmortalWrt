#!/bin/bash

set -e

# ====== 配置参数（可通过环境变量覆盖）======
PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}
ENABLE_PPPOE=${ENABLE_PPPOE:-"false"}
PPPOE_ACCOUNT=${PPPOE_ACCOUNT:-""}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-""}

DATE_STR=$(date +%Y%m%d)
BASE_NAME="ImmortalWrt-24.10-OpenClash"

echo "🚀 开始构建双版本 ext4 固件（generic + efi）"
echo "固件大小: ${PROFILE}MB | Docker: $INCLUDE_DOCKER"

WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ====== 基础配置文件 ======
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ====== 下载 OpenClash v0.47.028 ======
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_VERSION="0.47.028"
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/luci-app-openclash_${OPENCLASH_VERSION}_all.ipk"

if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused \
    -O luci-app-openclash.ipk "$OPENCLASH_URL"; then
    echo "⚠️ 官方源失败，尝试通过 ghproxy.com 镜像下载..."
    MIRROR_URL="https://ghproxy.com/${OPENCLASH_URL}"
    if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused \
        -O luci-app-openclash.ipk "$MIRROR_URL"; then
        echo "❌ OpenClash 下载失败！"
        exit 1
    fi
fi
echo "✅ OpenClash v${OPENCLASH_VERSION} 已就绪"

# ====== 下载 Clash.Meta 内核（v3, alpha-gxxxxxxx）======
echo "📥 从 OpenClash 新官方源下载最新 Clash.Meta 内核（v3）..."

mkdir -p clash-core

META_URL="https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"

if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused -O- "$META_URL" | tar -xz -C clash-core clash.meta; then
    echo "⚠️ 官方源失败，尝试镜像..."
    MIRROR_URL="https://ghproxy.com/https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"
    if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused -O- "$MIRROR_URL" | tar -xz -C clash-core clash.meta; then
        echo "❌ Clash.Meta 内核下载失败！"
        echo "请手动验证链接是否有效：$META_URL"
        exit 1
    fi
fi

chmod +x clash-core/clash.meta
META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
echo "✅ Clash.Meta 内核 [$META_VERSION] 已就绪"

# ====== 下载 GeoIP / GeoSite ======
echo "🌍 下载 GeoIP 和 GeoSite 规则..."
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O GeoIP.dat
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O GeoSite.dat
echo "✅ 规则准备完毕"

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

# ====== 准备 generic 文件系统 ======
echo "🔧 准备 generic (BIOS) 文件系统..."
cp -r files generic-files
mkdir -p generic-files/packages
cp luci-app-openclash.ipk generic-files/packages/
mkdir -p generic-files/etc/openclash/core
cp clash-core/clash.meta generic-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

# ====== 准备 efi 文件系统 ======
echo "🔧 准备 efi (UEFI) 文件系统..."
cp -r files efi-files
mkdir -p efi-files/packages
cp luci-app-openclash.ipk efi-files/packages/
mkdir -p efi-files/etc/openclash/core
cp clash-core/clash.meta efi-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat efi-files/etc/openclash/

# ====== 构建 generic (ext4) ======
echo "📦 构建 generic (ext4) 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

# ====== 构建 efi (ext4) ======
echo "📦 构建 efi (ext4) 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# ====== 查找并输出 ext4 固件 ======
OUTPUT_DIR="bin/targets/x86/64"

GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*ext4-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*ext4-combined.img.gz" | head -n1)

if [ -z "$GENERIC_IMG" ] || [ ! -f "$GENERIC_IMG" ]; then
    echo "❌ 未找到 generic ext4 固件！检查输出目录："
    ls -la "$OUTPUT_DIR"
    exit 1
fi

if [ -z "$EFI_IMG" ] || [ ! -f "$EFI_IMG" ]; then
    echo "❌ 未找到 efi ext4 固件！"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

# 复制到挂载目录（宿主机可见）
cp "$GENERIC_IMG" "/builder/${BASE_NAME}-generic-ext4-${DATE_STR}.img.gz"
cp "$EFI_IMG" "/builder/${BASE_NAME}-efi-ext4-${DATE_STR}.img.gz"

# 生成版本说明
cat > "/builder/version-${DATE_STR}.txt" << EOF
固件名称: $BASE_NAME (ext4 版本)
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
架构: x86-64
文件系统: ext4（完全可读写，适合软路由长期使用）
包含:
  - ${BASE_NAME}-generic-ext4-${DATE_STR}.img.gz （传统 BIOS 启动）
  - ${BASE_NAME}-efi-ext4-${DATE_STR}.img.gz （UEFI 启动）
插件: OpenClash v${OPENCLASH_VERSION}
内核: Clash.Meta ($META_VERSION, v3 架构)
说明:
  - 首次登录请通过 Web 界面设置 root 密码
  - 支持直接安装软件（如 Docker、Alist、AdGuard Home 等）
  - 配置永久保存，无需担心 overlay 满
EOF

echo "🎉 双版本 ext4 固件构建成功！"
