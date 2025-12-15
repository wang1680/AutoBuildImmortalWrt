#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# 时间戳用于唯一标识
TIMESTAMP=$(date +%Y%m%d-%H%M)
IMAGE_NAME="immortalwrt-x86-64-${TIMESTAMP}"

FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"

# PPPoE 配置
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat "$FILES_DIR/etc/config/pppoe-settings"

# 第三方插件（通过代理）
if [ -n "$CUSTOM_PACKAGES" ]; then
  echo "🔄 同步第三方仓库 via proxy..."
  git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  sh shell/prepare-packages.sh
else
  echo "⚪️ 未选择任何第三方软件包"
fi

# 包列表（已移除 Samba）
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
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核（通过代理下载）
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 下载 OpenClash 内核 via proxy..."
    mkdir -p "$FILES_DIR/etc/openclash/core"
    wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"
fi

# ✅ 构建一次，自动生成 ext4 + efi + squashfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="$PROFILE" \
    IMAGE_NAME="$IMAGE_NAME"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ 构建失败！"
    exit 1
fi

# ✅ 删除不需要的 squashfs 镜像
SQUASHFS_FILE="bin/targets/x86/64/${IMAGE_NAME}-generic-squashfs-combined.img.gz"
if [ -f "$SQUASHFS_FILE" ]; then
    echo "🗑️ 删除不需要的 squashfs 镜像: $(basename "$SQUASHFS_FILE")"
    rm -f "$SQUASHFS_FILE"
else
    echo "⚠️ 未找到 squashfs 镜像（可能未生成）"
fi

# 列出最终保留的镜像
echo
echo "✅ 构建完成！保留的固件："
ls -1 bin/targets/x86/64/${IMAGE_NAME}-generic-{ext4,efi}-combined.img.gz 2>/dev/null || echo "❌ 未找到 ext4 或 efi 镜像"
