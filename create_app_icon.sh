#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RESET='\033[0m'

echo -e "${BLUE}==========================================${RESET}"
echo -e "${BLUE}  CryptoStatusBar 应用图标生成工具${RESET}"
echo -e "${BLUE}==========================================${RESET}"

# 检查命令行参数
if [ $# -ne 1 ]; then
    echo -e "${RED}错误：请提供一个1024x1024像素的PNG图像作为参数${RESET}"
    echo -e "用法: $0 <图标文件.png>"
    echo -e "例如: $0 myicon.png"
    exit 1
fi

SOURCE_ICON="$1"

# 检查文件是否存在
if [ ! -f "$SOURCE_ICON" ]; then
    echo -e "${RED}错误：文件 '$SOURCE_ICON' 不存在${RESET}"
    exit 1
fi

# 检查是否为PNG文件
if [[ "$SOURCE_ICON" != *.png ]]; then
    echo -e "${YELLOW}警告：输入文件不是PNG格式，结果可能不如预期${RESET}"
fi

# 检查sips工具是否可用
if ! command -v sips &> /dev/null; then
    echo -e "${RED}错误：找不到'sips'工具，此脚本需要macOS系统${RESET}"
    exit 1
fi

# 检查图像分辨率
IMAGE_SIZE=$(sips -g pixelWidth -g pixelHeight "$SOURCE_ICON" | grep -E 'pixel(Width|Height):' | awk '{print $2}')
WIDTH=$(echo "$IMAGE_SIZE" | head -1)
HEIGHT=$(echo "$IMAGE_SIZE" | tail -1)

echo -e "${BLUE}[INFO]${RESET} 检测到图像尺寸: ${WIDTH}x${HEIGHT} 像素"

if [ "$WIDTH" -ne 1024 ] || [ "$HEIGHT" -ne 1024 ]; then
    echo -e "${YELLOW}警告：图像不是1024x1024像素，将自动调整大小${RESET}"
    # 创建临时文件
    TMP_ICON="icon_1024_temp.png"
    sips -z 1024 1024 "$SOURCE_ICON" --out "$TMP_ICON"
    SOURCE_ICON="$TMP_ICON"
    echo -e "${BLUE}[INFO]${RESET} 已调整图像大小为1024x1024像素"
fi

# 创建图标集目录
echo -e "${BLUE}[INFO]${RESET} 创建AppIcon.iconset目录..."
mkdir -p AppIcon.iconset

# 生成各种尺寸的图标
echo -e "${BLUE}[INFO]${RESET} 生成不同尺寸的图标..."

# 16x16
echo -e "${BLUE}[INFO]${RESET} 生成 16x16 图标..."
sips -z 16 16 "$SOURCE_ICON" --out AppIcon.iconset/icon_16x16.png

# 32x32 (@2x for 16x16)
echo -e "${BLUE}[INFO]${RESET} 生成 32x32 图标..."
sips -z 32 32 "$SOURCE_ICON" --out AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 "$SOURCE_ICON" --out AppIcon.iconset/icon_32x32.png

# 64x64 (@2x for 32x32)
echo -e "${BLUE}[INFO]${RESET} 生成 64x64 图标..."
sips -z 64 64 "$SOURCE_ICON" --out AppIcon.iconset/icon_32x32@2x.png

# 128x128
echo -e "${BLUE}[INFO]${RESET} 生成 128x128 图标..."
sips -z 128 128 "$SOURCE_ICON" --out AppIcon.iconset/icon_128x128.png

# 256x256 (@2x for 128x128)
echo -e "${BLUE}[INFO]${RESET} 生成 256x256 图标..."
sips -z 256 256 "$SOURCE_ICON" --out AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 "$SOURCE_ICON" --out AppIcon.iconset/icon_256x256.png

# 512x512 (@2x for 256x256)
echo -e "${BLUE}[INFO]${RESET} 生成 512x512 图标..."
sips -z 512 512 "$SOURCE_ICON" --out AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 "$SOURCE_ICON" --out AppIcon.iconset/icon_512x512.png

# 1024x1024 (@2x for 512x512)
echo -e "${BLUE}[INFO]${RESET} 生成 1024x1024 图标..."
sips -z 1024 1024 "$SOURCE_ICON" --out AppIcon.iconset/icon_512x512@2x.png

# 检查是否有临时文件需要清理
if [ -f "icon_1024_temp.png" ]; then
    rm "icon_1024_temp.png"
fi

echo -e "${GREEN}[SUCCESS]${RESET} 图标集已生成到 AppIcon.iconset 目录"

# 检查iconutil命令是否可用
if command -v iconutil &> /dev/null; then
    echo -e "${BLUE}[INFO]${RESET} 正在从图标集创建 .icns 文件..."
    
    # 生成.icns文件
    if iconutil -c icns AppIcon.iconset; then
        echo -e "${GREEN}[SUCCESS]${RESET} 已成功创建 AppIcon.icns 文件"
        echo -e "${GREEN}[INFO]${RESET} 现在你可以运行 ./build_app.sh 重新构建应用"
    else
        echo -e "${RED}[ERROR]${RESET} 创建 .icns 文件失败"
    fi
else
    echo -e "${YELLOW}[WARNING]${RESET} 找不到 iconutil 命令，无法创建 .icns 文件"
    echo -e "${BLUE}[INFO]${RESET} 请使用 iconutil -c icns AppIcon.iconset 命令手动创建 .icns 文件"
fi

echo -e "${BLUE}==========================================${RESET}"
echo -e "${GREEN}[NEXT STEPS]${RESET} 要将图标应用到应用程序："
echo -e "1. 运行 ./build_app.sh 重新构建应用"
echo -e "2. 启动应用查看新图标是否已应用"
echo -e "${BLUE}==========================================${RESET}"

exit 0 