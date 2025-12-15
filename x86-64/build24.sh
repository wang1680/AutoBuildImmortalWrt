#!/bin/bash
set -e  # 出错立即退出

source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

TIMESTAMP=$(date +%Y%m%d-%H%M)
OUTPUT_DIR="bin/targets/x86/64"

FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"

# PPPoE 配置
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

# 第三方插件（代理）
if [ -n "$CUSTOM_PACKAGES" ]; then
  echo "🔄 同步第三方仓库 via proxy..."
  git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  sh shell/prepare-packages.sh
fi

# 包列表（无 Samba）
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

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 下载 OpenClash 内核 via proxy..."
    mkdir -p "$FILES_DIR/etc/openclash/core"
    wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"
fi

# 构建（使用默认命名）
echo "🚀 开始构建固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="$PROFILE"

# 等待构建完成
echo "✅ 构建完成，开始重命名..."

# 定义原始文件名模式（ImmortalWrt 24.10.4 固定格式）
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
EXT4_SRC="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined.img.gz"
EFI_SRC="${OUTPUT_DIR}/${BASE_NAME}-efi-combined.img.gz"

# 检查文件是否存在
if [ ! -f "$EXT4_SRC" ] && [ ! -f "$EFI_SRC" ]; then
    echo "❌ 错误：未找到任何固件镜像！"
    ls -l "$OUTPUT_DIR/"
    exit 1
fi

# 重命名为带时间戳的版本
EXT4_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined.img.gz"
EFI_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-efi-combined.img.gz"

if [ -f "$EXT4_SRC" ]; then
    mv "$EXT4_SRC" "$EXT4_DST"
    echo "✅ 重命名 ext4 镜像: $(basename "$EXT4_DST")"
fi

if [ -f "$EFI_SRC" ]; then
    mv "$EFI_SRC" "$EFI_DST"
    echo "✅ 重命名 efi 镜像: $(basename "$EFI_DST")"
fi

# 删除 squashfs（如果存在）
SQFS="${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz"
[ -f "$SQFS" ] && rm -f "$SQFS" && echo "🗑️ 已删除 squashfs 镜像"

echo
echo "🎉 所有操作完成！最终镜像："
ls -1 "$OUTPUT_DIR"/immortalwrt-x86-64-"${TIMESTAMP}"-* 2>/dev/null || echo "❌ 未找到时间戳镜像"
