#!/bin/bash

set -e

# ==============================
# 🔑 强制使用你的代理（适用于 curl）
# ==============================
PROXY_URL="http://wchenhong.cn:5998"

echo "🌐 设置全局代理: $PROXY_URL"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"

# 测试代理（使用 curl）
echo "🔍 测试代理连通性..."
if ! curl -s --connect-timeout 10 --proxy "$PROXY_URL" https://github.com/ > /dev/null; then
    echo "❌ 代理无法访问 GitHub，请检查服务器状态！"
    exit 1
else
    echo "✅ 代理工作正常"
fi

# ==============================
# 配置
# ==============================
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

# 基础配置
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ==============================
# 下载 OpenClash（使用 curl）
# ==============================
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_VERSION="0.47.028"
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/luci-app-openclash_${OPENCLASH_VERSION}_all.ipk"

if ! curl -L --connect-timeout 30 --retry 3 --retry-delay 2 \
    --proxy "$PROXY_URL" -o luci-app-openclash.ipk "$OPENCLASH_URL"; then
    echo "❌ OpenClash 下载失败"
    exit 1
fi
echo "✅ OpenClash v${OPENCLASH_VERSION} 已就绪"

# ==============================
# 下载 Clash.Meta 内核（使用 curl + 文件验证）
# ==============================
echo "📥 下载 Clash.Meta 内核（v3）..."

mkdir -p clash-core
META_URL="https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"
TEMP_TGZ="/tmp/clash.meta.tgz"

if ! curl -L --connect-timeout 60 --retry 3 --retry-delay 2 \
    --proxy "$PROXY_URL" -o "$TEMP_TGZ" "$META_URL"; then
    echo "❌ Clash.Meta 下载失败"
    exit 1
fi

# 验证是否为 gzip 文件
if file "$TEMP_TGZ" | grep -q "gzip compressed"; then
    tar -xz -C clash-core -f "$TEMP_TGZ" clash.meta
    rm -f "$TEMP_TGZ"
else
    echo "❌ 下载内容无效（可能是 HTML 错误页）"
    echo "前 200 字节内容："
    head -c 200 "$TEMP_TGZ"
    rm -f "$TEMP_TGZ"
    exit 1
fi

chmod +x clash-core/clash.meta
META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
echo "✅ Clash.Meta 内核 [$META_VERSION] 已就绪"

# ==============================
# 下载 GeoIP / GeoSite（使用 curl）
# ==============================
echo "🌍 下载 GeoIP 和 GeoSite 规则..."
curl -L --connect-timeout 30 --retry 2 --proxy "$PROXY_URL" \
    -o GeoIP.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
curl -L --connect-timeout 30 --retry 2 --proxy "$PROXY_URL" \
    -o GeoSite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
echo "✅ 规则准备完毕"

# ==============================
# 软件包列表（确保包含 curl）
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

# ==============================
# 准备文件系统
# ==============================
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

# ==============================
# 构建
# ==============================
echo "📦 构建 generic (ext4) 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

echo "📦 构建 efi (ext4) 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# ==============================
# 输出原始命名固件
# ==============================
OUTPUT_DIR="bin/targets/x86/64"

GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*ext4-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*ext4-combined.img.gz" | head -n1)

if [ -z "$GENERIC_IMG" ] || [ ! -f "$GENERIC_IMG" ]; then
    echo "❌ generic ext4 固件未生成"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

if [ -z "$EFI_IMG" ] || [ ! -f "$EFI_IMG" ]; then
    echo "❌ efi ext4 固件未生成"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

cp "$GENERIC_IMG" "/builder/"
cp "$EFI_IMG" "/builder/"

cat > "/builder/build-info.txt" << EOF
构建成功！
固件文件：
- $(basename "$GENERIC_IMG")
- $(basename "$EFI_IMG")
内核版本: $META_VERSION
OpenClash: v${OPENCLASH_VERSION}
代理地址: $PROXY_URL
EOF

echo "🎉 构建完成！固件已保存。"
