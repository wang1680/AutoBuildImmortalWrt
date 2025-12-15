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

echo "🚀 开始构建双版本固件（generic + efi）"
echo "固件大小: ${PROFILE}MB | Docker: $INCLUDE_DOCKER"

# ====== 使用容器内临时目录，避免挂载冲突 ======
WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ====== 创建基础配置文件 ======
mkdir -p files/etc/config

cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=$ENABLE_PPPOE
pppoe_account=$PPPOE_ACCOUNT
pppoe_password=$PPPOE_PASSWORD
EOF

# ====== 【关键修正】下载 OpenClash v0.47.028（注意：使用 _all.ipk 命名）======
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_VERSION="0.47.028"
# ⚠️ 从 v0.47 开始，文件名格式为 luci-app-openclash_X.X.X_all.ipk（下划线）
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/luci-app-openclash_${OPENCLASH_VERSION}_all.ipk"

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

echo "✅ OpenClash v${OPENCLASH_VERSION} 已就绪"

# ====== 下载 Clash.Meta 内核（v3 优先）======
echo "📥 下载 Clash.Meta 内核..."
mkdir -p clash-core

# 尝试 v3
META_URL=$(curl -H "User-Agent: Mozilla/5.0 (AutoBuild)" -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
    grep -o 'https://[^"]*linux-amd64-v3\.tar\.gz' | head -n1)

if [ -z "$META_URL" ]; then
    # 回退到通用 amd64
    META_URL=$(curl -H "User-Agent: Mozilla/5.0 (AutoBuild)" -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
        grep -o 'https://[^"]*linux-amd64\.tar\.gz' | head -n1)
fi

if [ -z "$META_URL" ]; then
    echo "⚠️ 无法获取最新内核，使用兜底版本..."
    META_URL="https://github.com/MetaCubeX/Clash.Meta/releases/download/Prerelease-Alpha/clash.meta-linux-amd64-v3.tar.gz"
fi

if ! wget -q --timeout=60 --tries=3 -L --retry-connrefused -O- "$META_URL" | tar -xz -C clash-core clash.meta; then
    echo "❌ Clash.Meta 内核下载或解压失败"
    exit 1
fi

chmod +x clash-core/clash.meta

# GeoIP / GeoSite
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O GeoIP.dat
wget -q --timeout=30 --tries=2 -L --retry-connrefused \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O GeoSite.dat

echo "✅ 内核与规则已准备完毕"

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

# ====== 准备 generic 版本 ======
echo "🔧 准备 generic (BIOS) 版本..."
cp -r files generic-files
mkdir -p generic-files/packages
cp luci-app-openclash.ipk generic-files/packages/
mkdir -p generic-files/etc/openclash/core
cp clash-core/clash.meta generic-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

# ====== 准备 efi 版本 ======
echo "🔧 准备 efi (UEFI) 版本..."
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

# ====== 输出结果到挂载目录（/builder）======
OUTPUT_DIR="bin/targets/x86/64"

GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*squashfs-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*squashfs-combined.img.gz" | head -n1)

if [ -z "$GENERIC_IMG" ] || [ ! -f "$GENERIC_IMG" ]; then
    echo "❌ generic 固件未生成"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

if [ -z "$EFI_IMG" ] || [ ! -f "$EFI_IMG" ]; then
    echo "❌ efi 固件未生成"
    ls -la "$OUTPUT_DIR"
    exit 1
fi

# 复制到挂载点（宿主机可见）
cp "$GENERIC_IMG" "/builder/${BASE_NAME}-generic-${DATE_STR}.img.gz"
cp "$EFI_IMG" "/builder/${BASE_NAME}-efi-${DATE_STR}.img.gz"

# 生成版本说明
cat > "/builder/version-${DATE_STR}.txt" << EOF
固件名称: $BASE_NAME
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
架构: x86-64
包含:
  - ${BASE_NAME}-generic-${DATE_STR}.img.gz （传统 BIOS/MBR 启动）
  - ${BASE_NAME}-efi-${DATE_STR}.img.gz （UEFI/GPT 启动）
插件: OpenClash v${OPENCLASH_VERSION} + Clash.Meta (v3)
说明: 未设置 root 密码，首次登录请通过 Web 界面设置
EOF

echo "🎉 双版本构建成功！"
echo "📁 输出文件位于宿主机当前目录。"
