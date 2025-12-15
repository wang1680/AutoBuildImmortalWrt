#!/bin/bash

# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build script at $(date)" >> "$LOGFILE"
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p /home/build/immortalwrt/files/etc/config

# 创建 pppoe 配置文件（由 CI 环境变量传入）
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ============= 移除 wukongdaily/store 依赖 ============
echo "🔄 跳过 wukongdaily/store，改用官方插件源..."

# ============= 添加官方插件源（仅 PassWall2，OpenClash 改用 .ipk） ============
echo "🔧 添加官方 feeds 源（PassWall2）..."

cd /home/build/immortalwrt || { echo "❌ Failed to enter immortalwrt dir"; exit 1; }

cp feeds.conf.default feeds.conf.default.bak 2>/dev/null
sed -i '/wukongdaily\/store/d' feeds.conf.default

# 仅添加 PassWall 相关源（OpenClash 不再通过 feeds 编译）
cat << 'EOF' >> feeds.conf.default
src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git;main
src-git passwall_luci https://github.com/xiaorouji/openwrt-passwall.git;main
EOF

./scripts/feeds update -a
./scripts/feeds install -a -p passwall_packages
./scripts/feeds install -a -p passwall_luci

# ============= 定义要包含的软件包 ============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
# --- PassWall2 ---
PACKAGES="$PACKAGES luci-app-passwall2"
PACKAGES="$PACKAGES luci-i18n-passwall2-zh-cn"
# --- 注意：luci-app-openclash 不在此处声明（由 .ipk 打包）---
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"   # OpenClash 依赖的语言包可保留
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"

if [ -n "$CUSTOM_PACKAGES" ]; then
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ============= 下载 OpenClash 官方 .ipk 包（最新 release） ============
echo "📥 正在下载 OpenClash 最新 .ipk 包..."

mkdir -p files/packages/all

OPENCLASH_IPK_URL=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | \
    grep "browser_download_url.*luci-app-openclash.*all\.ipk" | head -1 | cut -d '"' -f 4)

if [ -n "$OPENCLASH_IPK_URL" ]; then
    echo "Downloading OpenClash .ipk: $OPENCLASH_IPK_URL"
    wget -qO "files/packages/all/luci-app-openclash.ipk" "$OPENCLASH_IPK_URL"
    echo "✅ OpenClash .ipk 已保存到 files/packages/all/"
else
    echo "❌ 无法获取 OpenClash .ipk 下载链接！"
    exit 1
fi

# ============= 下载 Clash.Meta 内核（linux-amd64-v3） ============
echo "✅ 下载 clash.meta (linux-amd64-v3) 内核..."
mkdir -p files/etc/openclash/core

CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
    grep "browser_download_url.*linux-amd64-v3\.tar\.gz" | head -1 | cut -d '"' -f 4)

if [ -n "$CLASH_META_URL" ]; then
    echo "Downloading: $CLASH_META_URL"
    wget -qO- "$CLASH_META_URL" | tar -xz -C files/etc/openclash/core clash.meta
    chmod +x files/etc/openclash/core/clash.meta
    echo "✅ Clash.Meta (v3) installed."
else
    echo "❌ v3 内核未找到，尝试通用 amd64 版本..."
    CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
        grep "browser_download_url.*linux-amd64\.tar\.gz" | head -1 | cut -d '"' -f 4)
    if [ -n "$CLASH_META_URL" ]; then
        wget -qO- "$CLASH_META_URL" | tar -xz -C files/etc/openclash/core clash.meta
        chmod +x files/etc/openclash/core/clash.meta
        echo "✅ 通用 amd64 内核已安装。"
    else
        echo "❌ 无法下载任何 clash.meta 内核！"
        exit 1
    fi
fi

# 下载 GeoIP 和 GeoSite
echo "📥 下载 GeoIP 和 GeoSite 规则..."
wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat

# ============= 构建固件 ============
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE="$PROFILE"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ Build failed!"
    exit 1
fi

# ============= 自动重命名固件文件（带时间戳） ============
echo "🔧 正在重命名固件文件..."

BASE_NAME="ImmortalWrt-24.10-OpenClash-PassWall2"
DATE_STR=$(date +%Y%m%d)
ARCH="x86-64"

IMG_FILE=$(find bin/targets/x86/64 -name "*generic*squashfs-combined.img" 2>/dev/null | head -1)
ISO_FILE=$(find bin/targets/x86/64 -name "*generic*.iso" 2>/dev/null | head -1)

if [ -n "$IMG_FILE" ] && [ -f "$IMG_FILE" ]; then
    NEW_IMG="${BASE_NAME}-${DATE_STR}-${ARCH}.img"
    cp "$IMG_FILE" "/home/build/immortalwrt/${NEW_IMG}"
    echo "✅ 固件已保存为: ${NEW_IMG}"
else
    echo "⚠️ 未找到 .img 固件文件"
fi

if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
    NEW_ISO="${BASE_NAME}-${DATE_STR}-${ARCH}.iso"
    cp "$ISO_FILE" "/home/build/immortalwrt/${NEW_ISO}"
    echo "✅ ISO 已保存为: ${NEW_ISO}"
else
    echo "ℹ️ 未生成 ISO 文件"
fi

# 生成 version.txt
cat > "/home/build/immortalwrt/version.txt" << EOF
固件名称: ${BASE_NAME}
构建日期: $(date '+%Y-%m-%d %H:%M:%S')
架构: ${ARCH}
包含插件: OpenClash (官方 .ipk + Meta v3), PassWall2
说明: 未预设 root 密码，首次登录请通过 Web 设置
EOF

echo "$(date '+%Y-%m-%d %H:%M:%S') - ✅ Build completed successfully."
