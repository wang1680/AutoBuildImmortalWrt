#!/bin/bash
set -e

# ==============================
# 🔧 全局配置
# ==============================
PROXY="https://proxy.6866686.xyz"
OPENCLASH_REPO="https://github.com/vernesong/OpenClash"
OPENCLASH_LATEST_IPK="${PROXY}/${OPENCLASH_REPO}/releases/latest/download/luci-app-openclash_*.ipk"
FALLBACK_VERSION="v0.47.028"
FALLBACK_IPK_URL="${PROXY}/${OPENCLASH_REPO}/releases/download/${FALLBACK_VERSION}/luci-app-openclash_$(echo ${FALLBACK_VERSION} | tr -d 'v')-all.ipk"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/openclash/core" "$FILES_DIR/etc/config"

# ==============================
# 1. 加载自定义包 & 环境
# ==============================
source shell/custom-packages.sh

echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# ==============================
# 2. PPPoE 配置
# ==============================
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF

echo "当前 PPPoE 配置："
cat "$FILES_DIR/etc/config/pppoe-settings"

# ==============================
# 3. 第三方插件（Store）
# ==============================
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 正在通过代理同步第三方仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    sh shell/prepare-packages.sh
else
    echo "⚪️ 未选择任何第三方软件包"
fi

# ==============================
# 4. 基础软件包列表（不含 OpenClash）
# ==============================
PACKAGES=""
PACKAGES="$PACKAGES curl wget ca-certificates"
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
# 5. 【强制】集成 OpenClash（必须成功）
# ==============================
echo
echo "🔍 强制集成 OpenClash（开机即用）..."

TMP_OC="/tmp/openclash-download"
mkdir -p "$TMP_OC"
EXTRA_PKG_DIR="/home/build/immortalwrt/extra-packages"
mkdir -p "$EXTRA_PKG_DIR"

# 尝试下载最新版
if timeout 20 wget -q --tries=2 -O "$TMP_OC/latest.ipk" "$OPENCLASH_LATEST_IPK" 2>/dev/null && [ -s "$TMP_OC/latest.ipk" ]; then
    echo "✅ 使用最新版 OpenClash"
    cp "$TMP_OC/latest.ipk" "$EXTRA_PKG_DIR/"
else
    echo "⚠️ 最新版下载失败，回退到稳定版本 ${FALLBACK_VERSION}"
    if ! timeout 20 wget -q --tries=2 -O "$TMP_OC/fallback.ipk" "$FALLBACK_IPK_URL" 2>/dev/null || [ ! -s "$TMP_OC/fallback.ipk" ]; then
        echo "❌ FATAL: OpenClash 最新版和 fallback 版均下载失败！请检查代理或网络。"
        exit 1
    fi
    cp "$TMP_OC/fallback.ipk" "$EXTRA_PKG_DIR/"
fi

# 强制加入构建
PACKAGES="$PACKAGES luci-app-openclash"
echo "✅ OpenClash 已加入固件"

# ==============================
# 6. 预置 Meta 内核 + Geo 规则（确保开机即用）
# ==============================
echo "⚙️ 预置 Meta 内核与 Geo 规则..."

# Meta 内核
META_URL="${PROXY}/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
if timeout 20 wget -qO- "$META_URL" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta" 2>/dev/null; then
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    echo "✅ Meta 内核已预置"
else
    echo "⚠️ Meta 内核下载失败（首次启动时将自动下载）"
fi

# GeoIP & GeoSite
GEOIP_URL="${PROXY}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="${PROXY}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

if timeout 20 wget -q "$GEOIP_URL" -O "$FILES_DIR/etc/openclash/GeoIP.dat"; then
    echo "✅ GeoIP.dat 已预置"
else
    echo "⚠️ GeoIP.dat 下载失败"
fi

if timeout 20 wget -q "$GEOSITE_URL" -O "$FILES_DIR/etc/openclash/GeoSite.dat"; then
    echo "✅ GeoSite.dat 已预置"
else
    echo "⚠️ GeoSite.dat 下载失败"
fi

# 创建必要目录（避免首次启动报错）
mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

# ==============================
# 7. 构建固件（两次：ext4 + efi）
# ==============================
echo
echo "🚀 开始构建固件..."

# BIOS (ext4)
echo "🔧 构建 BIOS (ext4) 镜像..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}"

# UEFI (squashfs)
echo "🔧 构建 UEFI (squashfs) 镜像..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

echo "✅ 构建完成！"

# ==============================
# 8. 重命名输出（带秒级时间戳）
# ==============================
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"

# ext4 (BIOS)
EXT4_SRC="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined.img.gz"
if [ -f "$EXT4_SRC" ]; then
    mv "$EXT4_SRC" "${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-bios-ext4-combined.img.gz"
    echo "✅ BIOS (ext4): immortalwrt-x86-64-${TIMESTAMP}-bios-ext4-combined.img.gz"
else
    echo "❌ 错误：ext4 镜像未生成！"
    exit 1
fi

# squashfs-efi (UEFI)
EFI_SRC="${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined-efi.img.gz"
if [ -f "$EFI_SRC" ]; then
    mv "$EFI_SRC" "${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-efi-squashfs-combined.img.gz"
    echo "✅ UEFI (squashfs): immortalwrt-x86-64-${TIMESTAMP}-efi-squashfs-combined.img.gz"
else
    echo "⚠️ UEFI 镜像未生成（可能 ImageBuilder 未启用 EFI 支持）"
fi

# 清理不需要的镜像
rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz" 2>/dev/null || true

echo
echo "🎉 构建成功！最终输出："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到输出文件"
