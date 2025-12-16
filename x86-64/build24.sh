#!/bin/bash
set -e

# ==============================
# 全局配置
# ==============================
PROXY="https://proxy.6866686.xyz"
OPENCLASH_REPO="https://github.com/vernesong/OpenClash"

# 加载自定义包
if [ -f shell/custom-packages.sh ]; then
    source shell/custom-packages.sh
else
    CUSTOM_PACKAGES=""
fi

echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# 可配置 fallback 版本（支持带或不带 'v'）
FALLBACK_VERSION_RAW="${OPENCLASH_FALLBACK_VERSION:-0.47.028}"
# 统一标准化：移除可能存在的 'v'
FALLBACK_VERSION_NUM="${FALLBACK_VERSION_RAW#v}"      # 如输入 v0.47.028 → 0.47.028
FALLBACK_TAG="v${FALLBACK_VERSION_NUM}"              # 强制加 v 用于 URL

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config" "$FILES_DIR/packages"

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
    git clone --depth=1 "${PROXY}/https://github.com/wukongdaily/store.git" /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    if [ -f shell/prepare-packages.sh ]; then
        sh shell/prepare-packages.sh
    fi
else
    echo "⚪️ 未选择任何第三方软件包"
fi

# === 3. 基础软件包列表（不包含 luci-app-openclash）===
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

# === 4. 智能下载 OpenClash .ipk（带代理 + 容错）===
echo "🔍 尝试获取最新 OpenClash 版本..."

LATEST_TAG=""
VERSION_NUM=""
IPK_FILENAME=""
IPK_URL=""

# 尝试通过代理获取最新 release tag
if LATEST_TAG=$(curl -s "${PROXY}/https://github.com/vernesong/OpenClash/releases/latest" | \
    grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) && [ -n "$LATEST_TAG" ]; then
    echo "✅ 检测到最新版本: $LATEST_TAG"
    VERSION_NUM="${LATEST_TAG#v}"
    IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    IPK_URL="${OPENCLASH_REPO}/releases/download/${LATEST_TAG}/${IPK_FILENAME}"
else
    echo "⚠️ 无法获取最新版本，使用 fallback: ${FALLBACK_TAG}"
    LATEST_TAG="${FALLBACK_TAG}"
    VERSION_NUM="${FALLBACK_VERSION_NUM}"
    IPK_FILENAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    IPK_URL="${OPENCLASH_REPO}/releases/download/${FALLBACK_TAG}/${IPK_FILENAME}"
fi

PROXIED_URL="${PROXY}/${IPK_URL}"
echo "📥 尝试下载: $PROXIED_URL"

# 下载 .ipk（带重试和超时）
if wget -q --timeout=30 --tries=3 "$PROXIED_URL" -O "$FILES_DIR/packages/$IPK_FILENAME" && [ -s "$FILES_DIR/packages/$IPK_FILENAME" ]; then
    echo "✅ 成功集成 OpenClash $LATEST_TAG"
else
    echo "❌ 下载失败！请检查以下信息："
    echo "   - 版本号: $VERSION_NUM"
    echo "   - 文件名: $IPK_FILENAME"
    echo "   - 尝试 URL: $PROXIED_URL"
    exit 1
fi

# === 5. 预置 Clash Meta 内核和规则 ===
mkdir -p "$FILES_DIR/etc/openclash/core"
echo "⏳ 下载 Clash Meta 内核..."
if wget -qO- "${PROXY}/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"; then
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    echo "✅ Meta 内核预置成功"
else
    echo "⚠️ Meta 内核下载失败（首次启动将自动下载）"
fi

echo "⏳ 下载 GeoIP 和 GeoSite..."
wget -q "${PROXY}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat" && echo "✅ GeoIP.dat" || echo "⚠️ GeoIP 失败"
wget -q "${PROXY}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat" && echo "✅ GeoSite.dat" || echo "⚠️ GeoSite 失败"

# 创建必要目录
mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

# === 6. 构建固件 ===
echo
echo "🚀 开始构建固件（已集成 OpenClash）..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

# === 7. 重命名输出文件（带秒级时间戳）===
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
for img_type in ext4 efi; do
    SRC="${OUTPUT_DIR}/${BASE_NAME}-${img_type}-combined.img.gz"
    if [ -f "$SRC" ]; then
        DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-${img_type}-combined.img.gz"
        mv "$SRC" "$DST"
        echo "✅ 生成: $(basename "$DST")"
    else
        if [ "$img_type" = "ext4" ]; then
            echo "❌ 错误：ext4 镜像未生成！"
            exit 1
        fi
        echo "⚠️ 警告：efi 镜像未生成"
    fi
done

# 清理不需要的 squashfs 镜像
SQFS="${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz"
[ -f "$SQFS" ] && rm -f "$SQFS" && echo "🗑️ 已删除 squashfs 镜像"

echo
echo "🎉 构建成功！固件已内置 OpenClash，开机即可使用。"
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到输出文件"
