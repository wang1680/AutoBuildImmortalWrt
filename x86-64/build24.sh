#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# ==============================
# 路径与时间定义（新增）
# ==============================
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="bin/targets/x86/64"
FILES_DIR="/home/build/immortalwrt/files"
mkdir -p "$FILES_DIR"

# ==============================
# 1️⃣ 创建 pppoe-settings
# ==============================
echo "Create pppoe-settings"
mkdir -p "$FILES_DIR/etc/config"

cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat "$FILES_DIR/etc/config/pppoe-settings"

# ==============================
# 2️⃣ 第三方插件（store）
# ==============================
if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://proxy.6866686.xyz/https://github.com/wukongdaily/store.git /tmp/store-run-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  sh shell/prepare-packages.sh
fi

# ==============================
# 3️⃣ 定义基础软件包列表
# ==============================
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"          # ← 保留此项！关键
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# 静态文件服务器dufs(推荐)
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
# 合并第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ==============================
# 4️⃣ 【核心修复】替换官方 openclash 为 GitHub 最新版
# ==============================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，准备替换为最新版..."

    # --- 可靠获取最新 tag ---
    LATEST_TAG=""
    
    # 方法1: 使用 GitHub API（最可靠）
    if LATEST_TAG=$(curl -s "https://api.github.com/repos/vernesong/OpenClash/releases/latest" | grep '"tag_name"' | cut -d'"' -f4) && [ -n "$LATEST_TAG" ]; then
        echo "✅ 通过 API 获取版本: $LATEST_TAG"
    else
        # 方法2: 页面 fallback（谨慎）
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
        echo "✅ 下载成功，替换官方包..."

        # 放入本地 packages 目录（ImageBuilder 会优先使用）
        PKG_DIR="/home/build/immortalwrt/packages"
        mkdir -p "$PKG_DIR"
        cp "/tmp/$IPK_NAME" "$PKG_DIR/"

        # 预置内核和规则
        mkdir -p "$FILES_DIR/etc/openclash/core"
        mkdir -p "$FILES_DIR/etc/openclash/{backup,config,secret,yaml}"

        # Meta 内核
        META_URL="https://proxy.6866686.xyz/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
        if wget -qO- "$META_URL" | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"; then
            chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
            echo "✅ Meta 内核预置成功"
        else
            echo "❌ Meta 内核下载失败（不影响安装）"
        fi

        # Geo 规则
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "$FILES_DIR/etc/openclash/GeoIP.dat"
        wget -q "https://proxy.6866686.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "$FILES_DIR/etc/openclash/GeoSite.dat"

        echo "🎉 OpenClash $LATEST_TAG 已成功集成！"
    else
        echo "❌ 下载失败！URL: $DOWNLOAD_URL"
        echo "⚠️ 将使用 ImmortalWrt 官方旧版（不推荐）"
    fi
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ==============================
# 5️⃣ 构建镜像（保留你的完整参数）
# ==============================
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    ROOTFS_PARTSIZE="$PROFILE" \
    EFI_IMAGES=1

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."

# ==============================
# 6️⃣ 重命名输出（完全保留你的逻辑）
# ==============================
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
SRC_IMG="${OUTPUT_DIR}/${BASE_NAME}-ext4-combined-efi.img.gz"

if [ ! -f "$SRC_IMG" ]; then
    echo "❌ 未生成镜像！"
    ls -l "$OUTPUT_DIR/"
    exit 1
fi

MAIN_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined.img.gz"
EFI_DST="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-ext4-combined-efi.img.gz"

mv "$SRC_IMG" "$MAIN_DST"
cp "$MAIN_DST" "$EFI_DST"
rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined-efi.img.gz" 2>/dev/null

echo "🎉 构建成功！"
echo "📁 输出文件："
ls -1 "${OUTPUT_DIR}"/immortalwrt-x86-64-"${TIMESTAMP}"-*
