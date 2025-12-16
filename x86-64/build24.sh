#!/bin/bash
set -e

source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build at $(date)" >> "$LOGFILE"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# ==============================
# 1️⃣ PPPoE 配置
# ==============================
mkdir -p /home/build/immortalwrt/files/etc/config
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF
echo "PPPoE 配置已写入"

# ==============================
# 2️⃣ 第三方插件（store）
# ==============================
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 同步第三方插件仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    [ -f shell/prepare-packages.sh ] && sh shell/prepare-packages.sh
else
    echo "⚪ 未启用第三方插件"
fi

# ==============================
# 3️⃣ 基础包列表（保留 luci-app-openclash）
# ==============================
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
PACKAGES="$PACKAGES luci-app-openclash"          # ← 保留这一行！关键
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "${INCLUDE_DOCKER:-no}" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# ==============================
# 4️⃣ 【核心】替换官方 openclash 为最新 GitHub 版本
# ==============================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 检测到 luci-app-openclash，准备替换为最新版..."

    # 获取最新版本号
    FALLBACK="0.47.028"
    LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases/latest" | grep -o 'releases/tag/[^"]*' | head -n1 | cut -d'/' -f3) || LATEST_TAG="v$FALLBACK"
    VERSION_NUM="${LATEST_TAG#v}"
    IPK_NAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    DOWNLOAD_URL="https://proxy.6866686.xyz/https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}/${IPK_NAME}"

    echo "📥 下载最新 OpenClash: $DOWNLOAD_URL"
    if wget -q --timeout=30 --tries=3 "$DOWNLOAD_URL" -O "/tmp/$IPK_NAME" && [ -s "/tmp/$IPK_NAME" ]; then
        echo "✅ 下载成功，替换官方包..."

        # 创建本地 packages 目录（覆盖官方包）
        PKG_DIR="/home/build/immortalwrt/packages"
        mkdir -p "$PKG_DIR"
        cp "/tmp/$IPK_NAME" "$PKG_DIR/"

        # 同时预置内核和规则（保持你原有的逻辑）
        CORE_DIR="/home/build/immortalwrt/files/etc/openclash/core"
        RULES_DIR="/home/build/immortalwrt/files/etc/openclash"
        mkdir -p "$CORE_DIR" "$RULES_DIR/{backup,config,secret,yaml}"

        # Meta 内核（你验证有效的地址）
        wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$CORE_DIR/clash_meta"
        chmod +x "$CORE_DIR/clash_meta"

        # Geo 规则
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$RULES_DIR/GeoIP.dat"
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$RULES_DIR/GeoSite.dat"

        echo "🎉 OpenClash $LATEST_TAG 已替换官方旧版！"
    else
        echo "❌ 最新版下载失败，将使用 ImmortalWrt 官方旧版（不推荐）"
    fi
else
    echo "⚪ 未启用 OpenClash"
fi

# ==============================
# 5️⃣ 构建固件
# ==============================
echo "🚀 开始构建固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}"

echo "✅ 构建完成！OpenClash 将像 PassWall 一样原生集成。"
