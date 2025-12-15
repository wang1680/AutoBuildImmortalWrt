#!/bin/bash

set -e

echo "🚀 开始构建双版本 ext4 固件（generic + efi）"
PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}

WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 基础配置
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=false
pppoe_account=
pppoe_password=
EOF

# ==============================
# 使用国内镜像下载（无需代理）
# ==============================
echo "📥 从镜像站下载 OpenClash v0.47.028..."
curl -L --connect-timeout 30 --retry 3 \
    -o luci-app-openclash.ipk \
    "https://mirror.ghproxy.com/https://github.com/vernesong/OpenClash/releases/download/v0.47.028/luci-app-openclash_0.47.028_all.ipk"

echo "📥 从镜像站下载 Clash.Meta 内核..."
curl -L --connect-timeout 30 --retry 3 \
    -o clash.meta.tgz \
    "https://mirror.ghproxy.com/https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"

# 解压内核
mkdir -p clash-core
tar -xz -C clash-core -f clash.meta.tgz clash.meta
chmod +x clash-core/clash.meta
META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
echo "✅ Clash.Meta [$META_VERSION] 就绪"

# 下载 Geo 规则（也用镜像）
curl -L --connect-timeout 30 --retry 2 \
    -o GeoIP.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat
curl -L --connect-timeout 30 --retry 2 \
    -o GeoSite.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat

# 软件包
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

# 准备文件
cp -r files generic-files
mkdir -p generic-files/packages
cp luci-app-openclash.ipk generic-files/packages/
mkdir -p generic-files/etc/openclash/core
cp clash-core/clash.meta generic-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

cp -r files efi-files
mkdir -p efi-files/packages
cp luci-app-openclash.ipk efi-files/packages/
mkdir -p efi-files/etc/openclash/core
cp clash-core/clash.meta efi-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat efi-files/etc/openclash/

# 构建
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# 输出
OUTPUT_DIR="bin/targets/x86/64"
GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*ext4-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*ext4-combined.img.gz" | head -n1)

cp "$GENERIC_IMG" "/builder/"
cp "$EFI_IMG" "/builder/"

cat > "/builder/build-info.txt" << EOF
构建成功！
固件文件：
- $(basename "$GENERIC_IMG")
- $(basename "$EFI_IMG")
Clash.Meta: $META_VERSION
EOF

echo "🎉 构建完成！"
