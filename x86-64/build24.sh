#!/bin/bash
set -e  # 出错立即退出

# 加载自定义包配置（需提前设置环境变量）
source shell/custom-packages.sh

echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# 时间戳精确到秒，避免覆盖
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"
mkdir -p "$FILES_DIR/packages"  # .ipk 将放在这里，ImageBuilder 会自动安装

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
    sh shell/prepare-packages.sh
else
    echo "⚪️ 未选择任何第三方软件包"
fi

# === 3. 基础软件包列表（注意：不包含 luci-app-openclash）===
PACKAGES=""
PACKAGES="$PACKAGES curl ca-certificates"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
# ⚠️ 不要加 luci-app-openclash，由 .ipk 提供
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# Docker 支持
if [ "${INCLUDE_DOCKER:-no}" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 已启用 Docker 支持"
fi

# === 4. 【强制】下载并集成最新版 OpenClash .ipk ===
echo "✅ 正在自动下载最新版 OpenClash .ipk（来自官方 Release）..."

API_URL="https://api.github.com/repos/vernesong/OpenClash/releases/latest"
RESPONSE=$(curl -s "$API_URL")

# 优先匹配 _all.ipk，其次任意 .ipk
LATEST_IPK_URL=$(echo "$RESPONSE" | grep -o '"browser_download_url": "[^"]*luci-app-openclash[^"]*_all\.ipk"' | head -n1 | sed 's/.*": "//; s/"$//')
if [ -z "$LATEST_IPK_URL" ]; then
    LATEST_IPK_URL=$(echo "$RESPONSE" | grep -o '"browser_download_url": "[^"]*luci-app-openclash[^"]*\.ipk"' | head -n1 | sed 's/.*": "//; s/"$//')
fi

if [ -z "$LATEST_IPK_URL" ]; then
    echo "❌ 无法从 GitHub 提取 OpenClash .ipk 下载地址"
    echo "请检查 Release 是否包含 .ipk 文件（如 v0.47.028）"
    exit 1
fi

echo "📥 下载地址: $LATEST_IPK_URL"
PROXIED_URL="https://proxy.6866686.xyz/$LATEST_IPK_URL"
IPK_FILENAME=$(basename "$LATEST_IPK_URL")
wget -q "$PROXIED_URL" -O "$FILES_DIR/packages/$IPK_FILENAME"

if [ ! -s "$FILES_DIR/packages/$IPK_FILENAME" ]; then
    echo "❌ OpenClash .ipk 下载失败或为空"
    exit 1
fi

echo "✅ 成功集成 OpenClash .ipk: $IPK_FILENAME"

# 同时预置 Meta 内核和 Geo 规则（开机即用）
mkdir -p "$FILES_DIR/etc/openclash/core"
echo "⏳ 下载 Clash Meta 内核..."
wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"

echo "⏳ 下载 GeoIP 和 GeoSite..."
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"

# === 5. 构建固件（ext4 + EFI）===
echo
echo "🚀 开始构建固件（已集成最新 OpenClash）..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

echo "✅ 固件构建完成！"

# === 6. 重命名输出文件（带时间戳，永不覆盖）===
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

# 清理不需要的 squashfs
SQFS="${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz"
[ -f "$SQFS" ] && rm -f "$SQFS" && echo "🗑️ 已删除 squashfs 镜像"

echo
echo "🎉 构建成功！最终固件已集成最新 OpenClash，开机即可使用。"
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到输出文件"
