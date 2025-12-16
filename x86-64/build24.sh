#!/bin/bash
set -e

# ==============================
# 🔧 配置区（可按需调整）
# ==============================
FALLBACK_OPENCLASH_VERSION="0.47.028"  # 稳定回退版本
TIMESTAMP=$(date +%Y%m%d-%H%M%S)       # 秒级时间戳，确保永不覆盖
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"

# 创建必要目录
mkdir -p "$FILES_DIR/packages" "$FILES_DIR/etc/openclash/core"
mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

# 加载自定义包配置（必须存在）
source shell/custom-packages.sh

echo "📦 第三方软件包: $CUSTOM_PACKAGES"
echo "💾 固件大小: ${PROFILE:-1024} MB"
echo "🐳 Docker 支持: ${INCLUDE_DOCKER:-no}"

# ==============================
# 1️⃣ PPPoE 配置
# ==============================
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF

echo "📄 当前 PPPoE 配置："
cat "$FILES_DIR/etc/config/pppoe-settings"

# ==============================
# 2️⃣ 第三方插件仓库（通过代理）
# ==============================
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 通过代理同步第三方插件仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    [ -f shell/prepare-packages.sh ] && sh shell/prepare-packages.sh
else
    echo "⚪ 未启用第三方插件"
fi

# ==============================
# 3️⃣ 基础软件包列表（不含 luci-app-openclash，由 .ipk 替代）
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
    echo "✅ 已启用 Docker 支持"
fi

# ==============================
# 4️⃣ 下载最新 OpenClash .ipk（带 fallback）
# ==============================
echo "🔍 尝试获取 OpenClash 最新 Release 版本..."

LATEST_TAG=""
if LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases/latest" | \
    grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) && [ -n "$LATEST_TAG" ]; then
    VERSION_NUM="${LATEST_TAG#v}"
    echo "✅ 检测到最新版本: $LATEST_TAG"
else
    echo "⚠️ 无法获取最新版本，使用 fallback: v$FALLBACK_OPENCLASH_VERSION"
    LATEST_TAG="v$FALLBACK_OPENCLASH_VERSION"
    VERSION_NUM="$FALLBACK_OPENCLASH_VERSION"
fi

IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
PROXIED_IPK_URL="https://proxy.6866686.xyz/https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}/${IPK_FILENAME}"

echo "📥 下载 OpenClash 插件: $PROXIED_IPK_URL"
if wget -q --timeout=30 --tries=3 "$PROXIED_IPK_URL" -O "$FILES_DIR/packages/$IPK_FILENAME" && [ -s "$FILES_DIR/packages/$IPK_FILENAME" ]; then
    echo "✅ 成功集成 OpenClash $LATEST_TAG（开箱即用）"
else
    echo "❌ OpenClash 插件下载失败！"
    exit 1
fi

# ==============================
# 5️⃣ 预置 Clash Meta 内核（使用你验证有效的地址）
# ==============================
echo "⚙️ 预置 Clash Meta 内核（使用 core/master 分支，你已验证有效）..."

META_KERNEL_URL="https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"

if wget -qO- "$META_KERNEL_URL" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta" 2>/dev/null; then
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    echo "✅ Meta 内核预置成功（来自 core/master）"
else
    echo "❌ Meta 内核下载失败！URL: $META_KERNEL_URL"
    exit 1
fi

# ==============================
# 6️⃣ 预置 GeoIP & GeoSite（可选但推荐）
# ==============================
echo "🌍 预置 GeoIP 和 GeoSite 规则..."

wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"

echo "✅ OpenClash 完整套件已预置（插件 + 内核 + 规则），开机即可使用！"

# ==============================
# 7️⃣ 构建固件（UEFI）
# ==============================
echo "🚀 开始构建 UEFI 固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

# ==============================
# 8️⃣ 重命名输出（双文件 + 时间戳）
# ==============================
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
SRC_IMG="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined-efi.img.gz"

if [ ! -f "$SRC_IMG" ]; then
    echo "❌ 未生成镜像！检查构建过程。"
    ls -l "$OUTPUT_DIR/"
    exit 1
fi

MAIN_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined.img.gz"
EFI_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined-efi.img.gz"

mv "$SRC_IMG" "$MAIN_DST"
cp "$MAIN_DST" "$EFI_DST"

# 清理 squashfs（如存在）
rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined-efi.img.gz" 2>/dev/null

echo "🎉 构建成功！"
echo "📁 输出文件："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-*
