#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# 获取当前时间戳
TIMESTAMP=$(date +%Y%m%d-%H%M)

# 定义要构建的固件配置：(描述, PROFILE值, 文件名后缀)
declare -A FIRMWARES
FIRMWARES["ext4"]="x86/64-generic-ext4-combined"
FIRMWARES["efi"]="x86/64-generic-efi-combined"

# 公共配置目录（PPPoE、OpenClash 等）
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR/etc/config"

# 创建 pppoe 配置（只需一次）
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat "$FILES_DIR/etc/config/pppoe-settings"

# 同步第三方插件（只需一次）
if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 via proxy..."
  git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  echo "✅ Run files copied:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 构建包列表（不含 Samba）
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argin-config"
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
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核（通过代理下载）
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，正在通过代理下载内核..."
    mkdir -p "$FILES_DIR/etc/openclash/core"
    META_URL="https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    wget -qO- "$META_URL" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 开始构建每种固件
for type in "${!FIRMWARES[@]}"; do
    PROFILE_VAL="${FIRMWARES[$type]}"
    IMAGE_NAME="immortalwrt-x86-64-${type}-${TIMESTAMP}"

    echo
    echo "=============================================="
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建 ${type} 固件 (PROFILE=${PROFILE_VAL})"
    echo "输出文件名前缀: ${IMAGE_NAME}"
    echo "=============================================="

    make image \
        PROFILE="$PROFILE_VAL" \
        PACKAGES="$PACKAGES" \
        FILES="$FILES_DIR" \
        ROOTFS_PARTSIZE="$PROFILE" \
        IMAGE_NAME="$IMAGE_NAME"

    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ 构建失败: ${type} 固件"
        exit 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - ✅ ${type} 固件构建成功！"
done

echo
echo "🎉 所有固件构建完成！"
echo "📁 输出路径示例: /home/build/immortalwrt/bin/targets/x86/64/"
echo "   - 包含 ext4 和 efi 两个版本，均带时间戳，不会互相覆盖。"
