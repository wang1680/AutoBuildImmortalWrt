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
mkdir -p "$FILES_DIR/packages"  # 用于存放 .ipk 包

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

# === 3. 软件包列表（已移除 Samba 和 openclash）===
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
# 注意：不再通过 PACKAGES 安装 openclash，改用 .ipk
# PACKAGES="$PACKAGES luci-app-openclash"  <-- 移除这行
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

# === 4. 下载最新版 luci-app-openclash .ipk（通过代理 + API）===
if [ "${INCLUDE_OPENCLASH:-yes}" = "yes" ]; then
    echo "✅ 正在获取最新版 luci-app-openclash .ipk..."

    # 使用 GitHub API 获取最新 release 的 asset 名称（匹配 x86_64 或 all）
    # 注意：OpenClash 的 ipk 是 architecture-independent (all)
    LATEST_IPK_URL=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | \
        grep "browser_download_url.*luci-app-openclash.*_all\.ipk" | \
        head -n 1 | \
        cut -d '"' -f 4)

    if [ -z "$LATEST_IPK_URL" ]; then
        echo "❌ 无法获取最新 openclash .ipk 下载地址"
        exit 1
    fi

    echo "📥 下载地址: $LATEST_IPK_URL"
    PROXIED_URL="https://proxy.6866686.xyz/$LATEST_IPK_URL"
    IPK_NAME="luci-app-openclash-latest.ipk"
    wget -q "$PROXIED_URL" -O "$FILES_DIR/packages/$IPK_NAME"

    if [ ! -s "$FILES_DIR/packages/$IPK_NAME" ]; then
        echo "❌ 下载失败或文件为空"
        exit 1
    fi

    echo "✅ 成功下载 openclash .ipk 到 files/packages/"

    # 同时下载 Meta 内核和 Geo 数据（保持原有逻辑）
    mkdir -p "$FILES_DIR/etc/openclash/core"
    wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"
else
    echo "⚪️ 跳过 OpenClash 安装（可通过 INCLUDE_OPENCLASH=yes 启用）"
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
fi

echo
echo "🎉 构建成功！最终输出："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到输出文件"
