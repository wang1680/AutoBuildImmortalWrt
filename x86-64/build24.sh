#!/bin/bash
set -e  # 遇到错误立即退出

echo "🔧 开始后处理镜像..."

# === 配置区 ===
OUTPUT_DIR="/home/build/immortalwrt/bin/targets/x86/64"
BASE_NAME="immortalwrt-24.10.4-x86-64-generic"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# === 清理 squashfs 镜像（可选）===
echo "🧹 清理 squashfs 镜像..."
rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined.img.gz"
rm -f "${OUTPUT_DIR}/${BASE_NAME}-squashfs-combined-efi.img.gz"
echo "✅ SquashFS 镜像已清理。"

# === 定义期望的镜像文件 ===
declare -A EXPECTED_IMAGES=(
    ["bios"]="${BASE_NAME}-ext4-combined.img.gz"
    ["efi"]="${BASE_NAME}-ext4-combined-efi.img.gz"
)

# === 处理并重命名 ===
found_any=false
for type in "${!EXPECTED_IMAGES[@]}"; do
    src_file="${OUTPUT_DIR}/${EXPECTED_IMAGES[$type]}"
    dst_file="${OUTPUT_DIR}/immortalwrt-x86-64-${TIMESTAMP}-${type}-ext4-combined.img.gz"

    if [ -f "$src_file" ]; then
        mv "$src_file" "$dst_file"
        echo "✅ 已生成: $(basename "$dst_file")"
        found_any=true
    else
        echo "⚠️  未找到 ${type} 镜像: $src_file"
    fi
done

# === 最终验证 ===
if [ "$found_any" = false ]; then
    echo "❌ 错误：ext4 镜像未生成！请检查 .config 是否启用了以下选项："
    echo "   CONFIG_TARGET_ROOTFS_EXT4FS=y"
    echo "   CONFIG_GRUB_IMAGES=y          # BIOS 支持"
    echo "   CONFIG_GRUB_EFI_IMAGES=y      # UEFI 支持"
    ls -l "${OUTPUT_DIR}/"
    exit 1
fi

echo "🎉 镜像后处理完成！"
