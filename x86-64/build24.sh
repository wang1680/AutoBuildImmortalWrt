#!/bin/bash

set -e

# ==============================
# 🔑 使用你提供的新代理
# ==============================
PROXY_URL="http://wchenhong.cn:6996"

echo "🌐 设置代理: $PROXY_URL"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"

# ==============================
# 🔍 测试代理是否能访问 GitHub
# ==============================
echo "🔍 测试代理连通性（访问 GitHub）..."
if ! curl -s --connect-timeout 15 --max-time 30 --proxy "$PROXY_URL" -k https://github.com/ > /dev/null; then
    echo "❌ 代理无法访问 GitHub，请确认 wchenhong.cn:7557 在公网可被 GitHub Actions 访问！"
    echo "建议检查："
    echo "1. 服务器防火墙是否开放 6996 端口（TCP）"
    echo "2. 代理服务是否监听 0.0.0.0:6996（不是 127.0.0.1）"
    echo "3. 云服务商安全组是否放行入站 7557"
    exit 1
else
    echo "✅ 代理连通性测试通过"
fi

# ==============================
# 初始化
# ==============================
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
# 📥 下载 OpenClash（通过代理）
# ==============================
echo "📥 通过代理下载 OpenClash v0.47.028..."
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v0.47.028/luci-app-openclash_0.47.028_all.ipk"

if ! curl -L --connect-timeout 30 --retry 3 --retry-delay 2 \
    --proxy "$PROXY_URL" -k -o luci-app-openclash.ipk "$OPENCLASH_URL"; then
    echo "❌ OpenClash 下载失败"
    exit 1
fi

# 验证是否为 IPK 文件（至少 10KB）
if [ ! -s luci-app-openclash.ipk ] || [ $(stat -c%s luci-app-openclash.ipk) -lt 10240 ]; then
    echo "❌ OpenClash 文件无效（可能返回了 HTML 错误页）"
    head -c 200 luci-app-openclash.ipk
    exit 1
fi
echo "✅ OpenClash 已就绪"

# ==============================
# 📥 下载 Clash.Meta 内核（通过代理）
# ==============================
echo "📥 通过代理下载 Clash.Meta 内核..."
META_URL="https://github.com/vernesong/OpenClash/raw/meta/clash.meta-linux-amd64.tar.gz"

if ! curl -L --connect-timeout 60 --retry 3 --retry-delay 2 \
    --proxy "$PROXY_URL" -k -o clash.meta.tgz "$META_URL"; then
    echo "❌ Clash.Meta 下载失败"
    exit 1
fi

# 验证是否为 gzip 文件
if file clash.meta.tgz | grep -q "gzip compressed"; then
    mkdir -p clash-core
    tar -xz -C clash-core -f clash.meta.tgz clash.meta
    chmod +x clash-core/clash.meta
    META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
    echo "✅ Clash.Meta [$META_VERSION] 就绪"
else
    echo "❌ Clash.Meta 文件无效（非 gzip 格式）"
    echo "前 200 字节："
    head -c 200 clash.meta.tgz
    exit 1
fi

# ==============================
# 🌍 下载 Geo 规则（也走代理，确保一致性）
# ==============================
echo "🌍 下载 GeoIP 和 GeoSite..."
curl -L --connect-timeout 30 --retry 2 --proxy "$PROXY_URL" -k -o GeoIP.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
curl -L --connect-timeout 30 --retry 2 --proxy "$PROXY_URL" -k -o GeoSite.dat \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
echo "✅ 规则准备完毕"

# ==============================
# 构建配置
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

# ==============================
# 开始构建
# ==============================
echo "📦 构建 generic (ext4) 固件..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

echo "📦 构建 efi (ext4) 固件..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# 输出结果
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
代理: $PROXY_URL
EOF

echo "🎉 构建完成！"
