#!/bin/bash
set -e

# ==============================
# 📦 加载自定义包配置
# ==============================
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build at $(date)" >> "$LOGFILE"
echo "编译固件大小为: ${PROFILE:-1024} MB"
echo "Include Docker: ${INCLUDE_DOCKER:-no}"

# ==============================
# 1️⃣ 创建 PPPoE 配置文件
# ==============================
mkdir -p /home/build/immortalwrt/files/etc/config
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE:-no}
pppoe_account=${PPPOE_ACCOUNT:-}
pppoe_password=${PPPOE_PASSWORD:-}
EOF
echo "PPPoE 配置已写入"

# ==============================
# 2️⃣ 同步第三方插件（store）
# ==============================
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 正在同步第三方软件仓库..."
    git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    [ -f shell/prepare-packages.sh ] && sh shell/prepare-packages.sh
else
    echo "⚪ 未启用第三方插件"
fi

# ==============================
# 3️⃣ 定义基础软件包列表（保留 luci-app-openclash）
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
PACKAGES="$PACKAGES luci-app-openclash"          # ← 关键：保留此项
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
# 4️⃣ 【核心】替换官方 openclash 为 GitHub 最新版
# ==============================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 检测到 luci-app-openclash，准备替换为最新版..."

    # --- 可靠获取最新 tag ---
    LATEST_TAG=""
    
    # 方法1: 使用 GitHub API（推荐）
    if LATEST_TAG=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | grep '"tag_name"' | cut -d'"' -f4) && [ -n "$LATEST_TAG" ]; then
        echo "✅ 通过 API 获取版本: $LATEST_TAG"
    else
        # 方法2: 页面 fallback（谨慎使用）
        echo "⚠️ API 失败，尝试从页面解析..."
        LATEST_TAG=$(curl -s "https://github.com/vernesong/OpenClash/releases" | grep -o 'href="/vernesong/OpenClash/releases/tag/v[0-9][^"]*"' | head -n1 | cut -d'/' -f6 | cut -d'"' -f1)
        if [ -n "$LATEST_TAG" ]; then
            echo "✅ 通过页面获取版本: $LATEST_TAG"
        fi
    fi

    # 最终 fallback
    if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG="v0.47.028"
        echo "⚠️ 使用 fallback 版本: $LATEST_TAG"
    fi

    VERSION_NUM="${LATEST_TAG#v}"
    IPK_NAME="luci-app-openclash_${VERSION_NUM}_all.ipk"
    DOWNLOAD_URL="https://proxy.6866686.xyz/https://github.com/vernesong/OpenClash/releases/download/${LATEST_TAG}/${IPK_NAME}"

    echo "📥 下载地址: $DOWNLOAD_URL"
    if wget -q --timeout=30 --tries=3 "$DOWNLOAD_URL" -O "/tmp/$IPK_NAME" && [ -s "/tmp/$IPK_NAME" ]; then
        echo "✅ 下载成功！"

        # 替换官方包：放入本地 packages 目录
        PKG_DIR="/home/build/immortalwrt/packages"
        mkdir -p "$PKG_DIR"
        cp "/tmp/$IPK_NAME" "$PKG_DIR/"

        # 预置 Clash Meta 内核 + Geo 规则
        CORE_DIR="/home/build/immortalwrt/files/etc/openclash/core"
        RULES_DIR="/home/build/immortalwrt/files/etc/openclash"
        mkdir -p "$CORE_DIR" "$RULES_DIR/{backup,config,secret,yaml}"

        echo "⚙️ 下载 Clash Meta 内核..."
        if wget -qO- "https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz" | tar xOvz > "$CORE_DIR/clash_meta"; then
            chmod +x "$CORE_DIR/clash_meta"
            echo "✅ Meta 内核预置成功"
        else
            echo "❌ Meta 内核下载失败（不影响安装，但需手动更新）"
        fi

        echo "🌍 下载 GeoIP & GeoSite..."
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$RULES_DIR/GeoIP.dat"
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$RULES_DIR/GeoSite.dat"

        echo "🎉 OpenClash $LATEST_TAG 已成功集成到固件！"
    else
        echo "❌ 下载失败！URL: $DOWNLOAD_URL"
        echo "⚠️ 将回退到 ImmortalWrt 官方旧版（功能可能受限）"
    fi
else
    echo "⚪ 未启用 OpenClash"
fi

# ==============================
# 5️⃣ 构建固件
# ==============================
echo "🚀 开始构建 UEFI 固件..."
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE="${PROFILE:-1024}"

echo "✅ 构建完成！固件已生成。"
