#!/bin/bash
set -e  # 出错立即退出

# 加载自定义包配置（需提前设置环境变量）
source shell/custom-packages.sh

echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

TIMESTAMP=$(date +%Y%m%d-%H%M)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"

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

# === 3. 软件包列表（已移除 Samba）===
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"
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

# === 4. OpenClash 内核（代理下载）===
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 正在通过代理下载 OpenClash Meta 内核..."
    mkdir -p "$FILES_DIR/etc/openclash/core"
    wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"
else
    echo "⚪️ 未启用 luci-app-openclash"
fi

# === 5. 构建固件（关键：启用 EFI_IMAGES=1）===
echo
echo "🚀 开始构建固件（同时生成 ext4 + EFI 版本）..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}" \
    EFI_IMAGES=1

echo "✅ 构建完成！"

# === 6. 重命名 + 清理 ===
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
EXT4_SRC="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined.img.gz"
EFI_SRC="${OUTPUT_DIR}/${BASE_NAME}-efi-combined.img.gz"
SQFS_SRC="${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz"

# 删除不需要的 squashfs
if [ -f "$SQFS_SRC" ]; then
    rm -f "$SQFS_SRC"
    echo "🗑️ 已删除 squashfs 镜像"
fi

# 重命名 ext4
if [ -f "$EXT4_SRC" ]; then
    EXT4_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined.img.gz"
    mv "$EXT4_SRC" "$EXT4_DST"
    echo "✅ 重命名 ext4 镜像 → $(basename "$EXT4_DST")"
else
    echo "❌ 错误：ext4 镜像未生成！"
    exit 1
fi

# 重命名 efi
if [ -f "$EFI_SRC" ]; then
    EFI_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-efi-combined.img.gz"
    mv "$EFI_SRC" "$EFI_DST"
    echo "✅ 重命名 efi 镜像 → $(basename "$EFI_DST")"
else
    echo "⚠️ 警告：efi 镜像未生成！请确认 ImageBuilder 支持 EFI"
    # 可选：exit 1 如果你要求必须有 efi
fi

echo
echo "🎉 构建成功！最终输出："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到输出文件"
