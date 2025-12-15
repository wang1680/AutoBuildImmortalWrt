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
# 下载 OpenClash（优先 jsDelivr，备用 ghproxy）
# ==============================
echo "📥 尝试从 jsDelivr 下载 OpenClash v0.47.028..."
if ! curl -L --connect-timeout 30 --retry 2 \
    -o luci-app-openclash.ipk \
    "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@v0.47.028/luci-app-openclash_0.47.028_all.ipk"; then
    echo "⚠️ jsDelivr 失败，尝试 ghproxy（跳过 SSL 验证）..."
    if ! curl -L --connect-timeout 30 --retry 2 -k \
        -o luci-app-openclash.ipk \
        "https://mirror.ghproxy.com/https://github.com/vernesong/OpenClash/releases/download/v0.47.028/luci-app-openclash_0.47.028_all.ipk"; then
        echo "❌ OpenClash 下载失败"
        exit 1
    fi
fi

# ==============================
# 下载 Clash.Meta 内核
# ==============================
echo "📥 下载 Clash.Meta 内核..."
if ! curl -L --connect-timeout 30 --retry 2 \
    -o clash.meta.tgz \
    "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@meta/clash.meta-linux-amd64.tar.gz"; then
    echo "⚠️ jsDelivr 失败，尝试 ghproxy（跳过 SSL 验证）..."
    if ! curl -L --connect-timeout 30 --retry 2 -k \
        -o clash.meta.tgz \
        "https://mirror.ghproxy.com/https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"; then
        echo "❌ Clash.Meta 下载失败"
        exit 1
    fi
fi

# 解压
mkdir -p clash-core
tar -xz -C clash-core -f clash.meta.tgz clash.meta
chmod +x clash-core/clash.meta
META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
echo "✅ Clash.Meta [$META_VERSION] 就绪"

# ==============================
# GeoIP / GeoSite（使用 jsDelivr，证书安全）
# ==============================
echo "🌍 下载 Geo 规则..."
curl -L --connect-timeout 30 --retry 2 \
    -o GeoIP.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat
curl -L --connect-timeout 30 --retry 2 \
    -o GeoSite.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
echo "✅ 规则准备完毕"

# ==============================
# 软件包 & 构建
# ==============================
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

# 准备文件系统
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
