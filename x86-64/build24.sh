#!/bin/bash

set -e

# ==============================
# 🛠️ 配置区（按需修改）
# ==============================
PROFILE=${PROFILE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}

# 可选：启用 GitHub 加速代理（如 proxy.6866686.xyz）
# 如果 nightly.link 在国内访问慢，可尝试加代理；一般不需要
USE_PROXY=false
ACCEL_URL="https://proxy.6866686.xyz"

WORK_DIR="/tmp/build"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ==============================
# 📁 初始化配置文件
# ==============================
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=false
pppoe_account=
pppoe_password=
EOF

# ==============================
# 📥 下载 OpenClash（固定版本）
# ==============================
echo "📥 下载 OpenClash v0.47.028..."
OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v0.47.028/luci-app-openclash_0.47.028_all.ipk"
if [ "$USE_PROXY" = true ]; then
    OPENCLASH_URL="$ACCEL_URL/$OPENCLASH_URL"
fi

curl -L --connect-timeout 30 --retry 3 -k -o luci-app-openclash.ipk "$OPENCLASH_URL"
if [ ! -s luci-app-openclash.ipk ] || [ $(stat -c%s luci-app-openclash.ipk) -lt 10240 ]; then
    echo "❌ OpenClash 文件无效"
    head -c 200 luci-app-openclash.ipk
    exit 1
fi
echo "✅ OpenClash 已就绪"

# ==============================
# 🧠 自动获取并下载最新 Clash.Meta 内核（无 jq 版）
# ==============================
echo "🔍 查询 OpenClash 最新 Meta 内核..."

# Step 1: 获取最近一次成功的 build-meta.yml 工作流运行 ID
RUN_ID=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/actions/workflows/build-meta.yml/runs?status=success&per_page=1" \
    | grep '"id":' | head -n1 | sed -E 's/.*"id":[[:space:]]*([0-9]+).*/\1/')

if ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
    echo "❌ 无法获取工作流运行 ID，请检查 GitHub API 是否可达"
    exit 1
fi
echo "✅ 工作流运行 ID: $RUN_ID"

# Step 2: 获取该运行中名为 'clash.meta-linux-amd64' 的 Artifact ID
ARTIFACT_JSON=$(curl -sL "https://api.github.com/repos/vernesong/OpenClash/actions/runs/$RUN_ID/artifacts")
ARTIFACT_ID=$(echo "$ARTIFACT_JSON" | awk '
BEGIN { id = ""; name = ""; in_artifact = 0 }
/"id":/ && !in_artifact {
    gsub(/[^0-9]/, "", $0); id = $0; in_artifact = 1
}
/"name":/ && in_artifact {
    match($0, /"name"[^"]*"([^"]+)"/, arr); name = arr[1]
}
/}/ && in_artifact {
    if (name == "clash.meta-linux-amd64") {
        print id; exit
    }
    in_artifact = 0; id = ""; name = ""
}
')

if ! [[ "$ARTIFACT_ID" =~ ^[0-9]+$ ]]; then
    echo "❌ 未找到名为 'clash.meta-linux-amd64' 的 Artifact"
    echo "返回的 Artifacts 列表："
    echo "$ARTIFACT_JSON" | grep -A5 -B5 clash
    exit 1
fi
echo "✅ Artifact ID: $ARTIFACT_ID"

# Step 3: 构造下载链接
META_URL="https://nightly.link/vernesong/OpenClash/actions/artifacts/${ARTIFACT_ID}.zip"
if [ "$USE_PROXY" = true ]; then
    META_URL="$ACCEL_URL/$META_URL"
fi

echo "📥 下载 Clash.Meta 内核..."
curl -L --connect-timeout 60 --retry 3 -k -o clash.meta.zip "$META_URL"

# Step 4: 验证并解压
if file clash.meta.zip | grep -q "Zip archive"; then
    mkdir -p clash-core
    unzip -p clash.meta.zip clash.meta > clash-core/clash.meta
    chmod +x clash-core/clash.meta
    META_VERSION=$($clash-core/clash.meta -v 2>&1 | head -n1 | cut -d' ' -f3)
    echo "✅ Clash.Meta [$META_VERSION] 就绪"
else
    echo "❌ Clash.Meta 文件无效（非 zip 格式）"
    echo "前 200 字节："
    head -c 200 clash.meta.zip
    exit 1
fi

# ==============================
# 🌍 下载 Geo 规则（使用 jsDelivr CDN，国内快）
# ==============================
echo "🌍 下载 GeoIP 和 GeoSite 规则..."
curl -L -k -o GeoIP.dat "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
curl -L -k -o GeoSite.dat "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
echo "✅ 规则准备完毕"

# ==============================
# 📦 准备软件包列表
# ==============================
PACKAGES="curl wget ca-certificates"
PACKAGES="$PACKAGES luci-theme-argon luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# ==============================
# 📁 准备 generic 固件文件
# ==============================
cp -r files generic-files
mkdir -p generic-files/packages generic-files/etc/openclash/core
cp luci-app-openclash.ipk generic-files/packages/
cp clash-core/clash.meta generic-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat generic-files/etc/openclash/

# ==============================
# 📁 准备 efi 固件文件
# ==============================
cp -r files efi-files
mkdir -p efi-files/packages efi-files/etc/openclash/core
cp luci-app-openclash.ipk efi-files/packages/
cp clash-core/clash.meta efi-files/etc/openclash/core/
cp GeoIP.dat GeoSite.dat efi-files/etc/openclash/

# ==============================
# 🏗️ 开始构建
# ==============================
echo "📦 构建 generic 固件 (PROFILE=generic)..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="./generic-files" ROOTFS_PARTSIZE="$PROFILE"

echo "📦 构建 efi 固件 (PROFILE=x86-64-efi)..."
make image PROFILE="x86-64-efi" PACKAGES="$PACKAGES" FILES="./efi-files" ROOTFS_PARTSIZE="$PROFILE"

# ==============================
# 📤 输出结果
# ==============================
OUTPUT_DIR="bin/targets/x86/64"
GENERIC_IMG=$(find "$OUTPUT_DIR" -name "*generic*ext4-combined.img.gz" | head -n1)
EFI_IMG=$(find "$OUTPUT_DIR" -name "*x86-64-efi*ext4-combined.img.gz" | head -n1)

mkdir -p /builder
cp "$GENERIC_IMG" "/builder/"
cp "$EFI_IMG" "/builder/"

cat > "/builder/build-info.txt" << EOF
构建成功！
固件:
- $(basename "$GENERIC_IMG")
- $(basename "$EFI_IMG")
Clash.Meta 版本: $META_VERSION
构建时间: $(date)
EOF

echo "🎉 构建完成！固件已保存到 /builder/"
