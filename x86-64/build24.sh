#!/bin/bash
set -e

# ==============================
# 🔧 配置
# ==============================
FALLBACK_VERSION="0.47.028"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"

mkdir -p "$FILES_DIR/packages" "$FILES_DIR/etc/openclash/core"
mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

source shell/custom-packages.sh

echo "📦 第三方包: $CUSTOM_PACKAGES"
echo "💾 固件大小: ${PROFILE:-1024} MB"
echo "🐳 Docker: ${INCLUDE_DOCKER:-no}"

# ==============================
# 1️⃣ PPPoE 配置
# ==============================
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF

# ==============================
# 2️⃣ 获取 OpenClash 最新 Release（插件 + 内核）
# ==============================
echo "🔍 获取 OpenClash 最新 Release..."

LATEST_TAG=""
if LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases/latest" | \
    grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) && [ -n "$LATEST_TAG" ]; then
    VERSION_NUM="${LATEST_TAG#v}"
    echo "✅ 检测到最新版本: $LATEST_TAG"
else
    echo "⚠️ 使用 fallback 版本: v$FALLBACK_VERSION"
    LATEST_TAG="v$FALLBACK_VERSION"
    VERSION_NUM="$FALLBACK_VERSION"
fi

# 构造代理 URL
BASE_URL="https://proxy.6866686.xyz/https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}"

IPK_FILE="luci-app-openclash_${VERSION_NUM}_all.ipk"
KERNEL_FILE="clash-linux-amd64.tar.gz"

# 下载插件
echo "📥 下载 OpenClash 插件..."
if ! wget -q --timeout=30 --tries=3 "${BASE_URL}/${IPK_FILE}" -O "$FILES_DIR/packages/$IPK_FILE" || [ ! -s "$FILES_DIR/packages/$IPK_FILE" ]; then
    echo "❌ 插件下载失败！"
    exit 1
fi

# 下载 Meta 内核
echo "📥 下载 Clash Meta 内核..."
if ! wget -q --timeout=30 --tries=3 "${BASE_URL}/${KERNEL_FILE}" -O "/tmp/clash.tar.gz" || [ ! -s "/tmp/clash.tar.gz" ]; then
    echo "❌ Meta 内核下载失败！"
    exit 1
fi

# 解压内核
tar -xOzf "/tmp/clash.tar.gz" clash > "$FILES_DIR/etc/openclash/core/clash_meta"
chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
rm -f /tmp/clash.tar.gz

echo "✅ 成功集成 OpenClash $LATEST_TAG + Meta 内核（版本匹配，开机即用）"

# ==============================
# 3️⃣ 基础软件包（不重复添加 luci-app-openclash）
# ==============================
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
fi

# ==============================
# 4️⃣ 构建固件（UEFI）
# ==============================
echo "🚀 开始构建 UEFI 固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

# ==============================
# 5️⃣ 重命名输出（双文件 + 时间戳）
# ==============================
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
SRC_IMG="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined-efi.img.gz"

if [ ! -f "$SRC_IMG" ]; then
    echo "❌ 未生成镜像！"
    ls -l "$OUTPUT_DIR/"
    exit 1
fi

MAIN_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined.img.gz"
EFI_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined-efi.img.gz"

mv "$SRC_IMG" "$MAIN_DST"
cp "$MAIN_DST" "$EFI_DST"

rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined-efi.img.gz" 2>/dev/null

echo "🎉 构建成功！OpenClash $LATEST_TAG + Meta 内核已预置，开机即可使用！"
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-*
