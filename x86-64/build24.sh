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

# ============= 移除 wukongdaily/store 依赖（改用官方源） ============
# 不再使用 store 的静态 .ipk，而是通过 feeds 编译最新源码
echo "🔄 跳过 wukongdaily/store，改用官方插件源..."

# ============= 添加官方插件源（PassWall2 + OpenClash） ============
echo "🔧 添加官方 feeds 源..."

# 进入 immortalwrt 目录（假设当前已在 /home/build/immortalwrt）
cd /home/build/immortalwrt || { echo "❌ Failed to enter immortalwrt dir"; exit 1; }

# 备份原 feeds.conf
cp feeds.conf.default feeds.conf.default.bak 2>/dev/null

# 移除可能存在的旧 store 源
sed -i '/wukongdaily\/store/d' feeds.conf.default

# 添加官方源
cat << 'EOF' >> feeds.conf.default
src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git;main
src-git passwall_luci https://github.com/xiaorouju/openwrt-passwall.git;main
src-git openclash https://github.com/vernesong/OpenClash.git;master
EOF

# 更新 feeds 并安装插件
./scripts/feeds update -a
./scripts/feeds install -a -p passwall_packages
./scripts/feeds install -a -p passwall_luci
./scripts/feeds install -a -p openclash

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
# --- 使用 PassWall2（最新版） ---
PACKAGES="$PACKAGES luci-app-passwall2"
PACKAGES="$PACKAGES luci-i18n-passwall2-zh-cn"
# --- OpenClash（从 feeds 安装）---
PACKAGES="$PACKAGES luci-app-openclash"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# 静态文件服务器 dufs
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"

# 合并 custom-packages.sh 中的额外包
if [ -n "$CUSTOM_PACKAGES" ]; then
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# Docker 支持
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ============= 下载 OpenClash 内核（linux-amd64-v3） ============
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，下载 clash.meta (linux-amd64-v3) 内核..."
    mkdir -p files/etc/openclash/core

    # 获取最新 release 中 linux-amd64-v3.tar.gz 的 URL
    CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
        grep "browser_download_url.*linux-amd64-v3.tar.gz" | head -1 | cut -d '"' -f 4)

    if [ -n "$CLASH_META_URL" ]; then
        echo "Downloading: $CLASH_META_URL"
        wget -qO- "$CLASH_META_URL" | tar -xz -C files/etc/openclash/core clash.meta
        chmod +x files/etc/openclash/core/clash.meta
        echo "✅ Clash.Meta (v3) installed."
    else
        echo "❌ v3 内核未找到，尝试通用 amd64 版本..."
        CLASH_META_URL=$(curl -s "https://api.github.com/repos/MetaCubeX/Clash.Meta/releases/latest" | \
            grep "browser_download_url.*linux-amd64.tar.gz" | head -1 | cut -d '"' -f 4)
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
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ============= 构建固件 ============
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE="$PROFILE"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - ✅ Build completed successfully."
