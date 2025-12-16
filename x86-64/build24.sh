#!/bin/bash
set -e

# ==============================
# 🔧 配置区（可按需调整）
# ==============================
FALLBACK_OPENCLASH_VERSION="0.47.028"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"

mkdir -p "$FILES_DIR/packages" "$FILES_DIR/etc/openclash/core"
mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"
mkdir -p "$FILES_DIR/tmp"  # 用于存放 .ipk 供 init 脚本使用

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
# 2️⃣ 第三方插件仓库
# ==============================
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 同步第三方插件仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    [ -f shell/prepare-packages.sh ] && sh shell/prepare-packages.sh
else
    echo "⚪ 未启用第三方插件"
fi

# ==============================
# 3️⃣ 基础软件包列表
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
# ❌ 如果你不想要 PassWall，请注释或删除下一行：
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
# ✅ 如果你不想要 HomeProxy，也可以删除下一行：
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
# 4️⃣ 下载 OpenClash .ipk（带 fallback）
# ==============================
echo "🔍 获取 OpenClash 最新版本..."

LATEST_TAG=""
if LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases/latest" | \
    grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) && [ -n "$LATEST_TAG" ]; then
    VERSION_NUM="${LATEST_TAG#v}"
    echo "✅ 检测到最新版本: $LATEST_TAG"
else
    echo "⚠️ 使用 fallback 版本: v$FALLBACK_OPENCLASH_VERSION"
    LATEST_TAG="v$FALLBACK_OPENCLASH_VERSION"
    VERSION_NUM="$FALLBACK_OPENCLASH_VERSION"
fi

IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
PROXIED_URL="https://proxy.6866686.xyz/https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}/${IPK_FILENAME}"

echo "📥 下载 OpenClash 插件..."
if wget -q --timeout=30 --tries=3 "$PROXIED_URL" -O "$FILES_DIR/packages/$IPK_FILENAME" && [ -s "$FILES_DIR/packages/$IPK_FILENAME" ]; then
    echo "✅ 成功下载 OpenClash $LATEST_TAG"
else
    echo "❌ OpenClash 插件下载失败！"
    exit 1
fi

# ==============================
# 5️⃣ 预置 Meta 内核（使用你验证有效的地址）
# ==============================
echo "⚙️ 预置 Clash Meta 内核..."

META_KERNEL_URL="https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"

if wget -qO- "$META_KERNEL_URL" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta" 2>/dev/null; then
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    echo "✅ Meta 内核预置成功"
else
    echo "❌ Meta 内核下载失败！"
    exit 1
fi

# ==============================
# 6️⃣ 预置 GeoIP & GeoSite
# ==============================
echo "🌍 预置 Geo 规则..."
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"

# ==============================
# 7️⃣ 【关键】创建 OpenClash 自动安装脚本
# ==============================
echo "🔧 创建 OpenClash 自动安装脚本..."

# 将 .ipk 复制到 /tmp（会被打包进固件）
cp "$FILES_DIR/packages/$IPK_FILENAME" "$FILES_DIR/tmp/$IPK_FILENAME"

# 创建 init.d 脚本（开机自动安装）
cat << 'EOF' > "$FILES_DIR/etc/init.d/openclash-install"
#!/bin/sh /etc/rc.common
START=99

start() {
    logger "[OpenClash] 开始自动安装..."
    if [ -f "/tmp/luci-app-openclash_*.ipk" ]; then
        opkg install /tmp/luci-app-openclash_*.ipk
        rm -f /tmp/luci-app-openclash_*.ipk
        logger "[OpenClash] 安装完成！"
    else
        logger "[OpenClash] .ipk 文件未找到，跳过安装。"
    fi
}
EOF

chmod +x "$FILES_DIR/etc/init.d/openclash-install"

echo "✅ OpenClash 将在首次启动时自动安装！"

# ==============================
# 8️⃣ 构建固件
# ==============================
echo "🚀 开始构建 UEFI 固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

# ==============================
# 9️⃣ 重命名输出
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

echo "🎉 构建成功！"
echo "📁 输出文件："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-*
