#!/bin/bash

set -e

ACCEL_URL="https://proxy.6866686.xyz"
echo "🌐 使用 GitHub 加速代理: $ACCEL_URL"

PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}

WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=false
pppoe_account=
pppoe_password=
EOF

# ==============================
# OpenClash（保持不变）
# ==============================
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_URL="$ACCEL_URL/https://github.com/vernesong/OpenClash/releases/download/v0.47.028/luci-app-openclash_0.47.028_all.ipk"
curl -L -k -o luci-app-openclash.ipk "$OPENCLASH_URL"
if [ ! -s luci-app-openclash.ipk ] || [ $(stat -c%s luci-app-openclash.ipk) -lt 10240 ]; then
    echo "❌ OpenClash 无效"; head -c200 luci-app-openclash.ipk; exit 1
fi
echo "✅ OpenClash 已就绪"

# ==============================
# ✅ 添加 Clash.Meta 内核（mihomo）
# ==============================
MIHOMO_VERSION="v1.18.9"
echo "📥 下载 Clash.Meta 内核 (mihomo $MIHOMO_VERSION) ..."
META_URL="$ACCEL_URL/https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/mihomo-linux-amd64-compatible.tar.gz"

curl -L --connect-timeout 60 --retry 3 -k -o mihomo.tar.gz "$META_URL"

if file mihomo.tar.gz | grep -q "gzip compressed"; then
    mkdir -p clash-core
    tar -xz -C clash-core -f mihomo.tar.gz mihomo
    mv clash-core/mihomo clash-core/clash.meta  # OpenClash 要求名为 clash.meta
    chmod +x clash-core/clash.meta
    META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
    echo "✅ Clash.Meta (mihomo) [$META_VERSION] 就绪"
else
    echo "❌ 内核无效（非 gzip 格式）"
    echo "前 200 字节："
    head -c 200 mihomo.tar.gz
    exit 1
fi

# ==============================
# Geo 规则（继续用你的代理）
# ==============================
echo "🌍 下载 Geo 规则..."
curl -L -k -o GeoIP.dat "$ACCEL_URL/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
curl -L -k -o GeoSite.dat "$ACCEL_URL/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
echo "✅ 规则准备完毕"

# ==============================
# 构建部分（保持不变）
# ==============================
PACKAGES="curl wget ca-certificates luci-theme-argon luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
[ "$INCLUDE_DOCKER" = "yes" ] && PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"

cp -r files generic-files
mkdir -p generic-files/packages generic-files/etc/openclash/core
cp luci-app-openclash.ipk generic-files/packages/
cp clash-core/clash.meta generic-files/etc/openclash/core/   # 👈 复制内核
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

cp -r files efi-files
mkdir -p efi-files/packages efi-files/etc/openclash/core
cp luci-app-openclash.ipk efi-files/packages/
cp clash-core/clash.meta efi-files/etc/openclash/core/      # 👈 复制内核
cp GeoIP.dat GeoSite.dat efi-files/etc/openclash/

echo "📦 构建 generic 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

echo "📦 构建 efi 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

OUTPUT_DIR="bin/targets/x86/64"
GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*ext4-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*ext4-combined.img.gz" | head -n1)

cp "$GENERIC_IMG" "/builder/"
cp "$EFI_IMG" "/builder/"

cat > "/builder/build-info.txt" << EOF
构建成功！
固件:
- $(basename "$GENERIC_IMG")
- $(basename "$EFI_IMG")
Clash.Meta: $META_VERSION
加速代理: $ACCEL_URL
EOF

echo "🎉 构建完成！"
