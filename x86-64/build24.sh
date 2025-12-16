#!/bin/bash
set -e

# 加载自定义包配置（如存在）
if [ -f shell/custom-packages.sh ]; then
    source shell/custom-packages.sh
else
    CUSTOM_PACKAGES=""
fi

echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# 可配置的 OpenClash fallback 版本
OPENCLASH_FALLBACK_VERSION="${OPENCLASH_FALLBACK_VERSION:-0.47.028}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"
mkdir -p "$FILES_DIR/packages"

# === 1. PPPoE 配置 ===
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF

echo "当前 PPPoE 配置："
cat "$FILES_DIR/etc/config/pppoe-settings"

# === 2. 第三方插件（通过代理）===
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 正在通过代理同步第三方仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    if [ -f shell/prepare-packages.sh ]; then
        sh shell/prepare-packages.sh
    fi
else
    echo "⚪️ 未选择任何第三方软件包"
fi

# === 3. 基础软件包列表 ===
PACKAGES=""
PACKAGES="$PACKAGES curl ca-certificates wget"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "${INCLUDE_DOCKER:-no}" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 已启用 Docker 支持"
fi

# === 4. 下载 OpenClash .ipk（仅一次）===
echo "✅ 正在尝试获取最新 OpenClash 版本..."
LATEST_TAG=""
if LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases/latest" | \
    grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) && [ -n "$LATEST_TAG" ]; then
    echo "🔍 检测到最新版本: $LATEST_TAG"
    VERSION_NUM="${LATEST_TAG#v}"
    IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    IPK_URL="https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}/${IPK_FILENAME}"
else
    echo "⚠️ 无法获取最新版本，使用 fallback: v${OPENCLASH_FALLBACK_VERSION}"
    LATEST_TAG="v${OPENCLASH_FALLBACK_VERSION}"
    VERSION_NUM="${OPENCLASH_FALLBACK_VERSION}"
    IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    IPK_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_FALLBACK_VERSION}/${IPK_FILENAME}"
fi

PROXIED_URL="https://proxy.6866686.xyz/$IPK_URL"
if wget -q --timeout=30 --tries=3 "$PROXIED_URL" -O "$FILES_DIR/packages/$IPK_FILENAME" && [ -s "$FILES_DIR/packages/$IPK_FILENAME" ]; then
    echo "✅ 成功集成 OpenClash $LATEST_TAG"
else
    echo "❌ 下载失败！请检查网络或版本是否存在"
    echo "   尝试 URL: $PROXIED_URL"
    exit 1
fi

# === 5. 预置 Clash Meta 内核和规则 ===
mkdir -p "$FILES_DIR/etc/openclash/core"
wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"

wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"

mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

# === 6. 构建 UEFI 固件（支持现代主板）===
echo
echo "🚀 开始构建 UEFI 固件（支持 UEFI 启动）..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

# === 7. 构建 BIOS 固件（支持老设备 Legacy 启动）===
echo
echo "🚀 开始构建 BIOS 固件（支持传统 BIOS 启动）..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=0 \
    TARGET_IMAGES="combined"

# === 8. 重命名输出文件（区分 uefi / bios）===
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"

# UEFI 镜像
UEFI_SRC="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined-efi.img.gz"
if [ -f "$UEFI_SRC" ]; then
    mv "$UEFI_SRC" "${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined-uefi.img.gz"
    echo "✅ 生成 UEFI 固件"
else
    echo "❌ UEFI 镜像未生成！"
    ls -l "${OUTPUT_DIR}/"
    exit 1
fi

# BIOS 镜像（关键：必须显式生成 combined）
BIOS_SRC="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined.img.gz"
if [ -f "$BIOS_SRC" ]; then
    mv "$BIOS_SRC" "${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined-bios.img.gz"
    echo "✅ 生成 BIOS 固件"
else
    echo "❌ BIOS 镜像未生成！请检查是否启用了 EFI_IMAGES=0 和 TARGET_IMAGES=combined"
    ls -l "${OUTPUT_DIR}/"
    exit 1
fi

# 清理不需要的 squashfs 镜像
find "$OUTPUT_DIR" -name "*squashfs*" -delete && echo "🗑️ 已删除 squashfs 镜像"

echo
echo "🎉 双固件构建成功！"
echo "📁 输出文件："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-*
