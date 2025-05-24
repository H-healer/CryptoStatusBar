#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# 定义文件路径
EXECUTABLE_NAME="CryptoStatusBar"
APP_DIR="${EXECUTABLE_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="Info.plist"
PLIST_DEST="${CONTENTS_DIR}/${INFO_PLIST}"

echo -e "${BLUE}==========================================${RESET}"
echo -e "${BLUE}  ${EXECUTABLE_NAME} 应用程序构建脚本${RESET}"
echo -e "${BLUE}==========================================${RESET}"

# 检查必要的工具
echo -e "${BLUE}[INFO]${RESET} 检查构建环境..."
if ! command -v swift &> /dev/null; then
    echo -e "${RED}[ERROR]${RESET} 找不到Swift编译器。请确保已安装Xcode或Swift命令行工具。"
    exit 1
fi

echo -e "${GREEN}[SUCCESS]${RESET} 环境检查通过"

# 构建应用
echo -e "${BLUE}[INFO]${RESET} 正在构建应用程序..."

# 清理旧的构建文件
echo -e "${BLUE}[INFO]${RESET} 清理旧的构建文件..."
rm -rf .build

# 使用Sources.txt中的文件列表进行编译
echo -e "${BLUE}[INFO]${RESET} 使用Sources.txt中指定的源文件列表构建..."
if swift build --configuration release; then
    echo -e "${GREEN}[SUCCESS]${RESET} 应用程序构建成功"
else
    echo -e "${RED}[ERROR]${RESET} 构建失败。请检查上面的错误信息。"
    exit 1
fi

# 创建应用程序包目录结构
echo -e "${BLUE}[INFO]${RESET} 正在创建应用程序包..."

# 删除旧的应用程序包
echo -e "${BLUE}[INFO]${RESET} 正在删除旧的应用程序包..."
rm -rf "${APP_DIR}"

# 创建必要的目录
echo -e "${BLUE}[INFO]${RESET} 正在创建应用程序包目录结构..."
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 复制可执行文件
echo -e "${BLUE}[INFO]${RESET} 正在复制可执行文件..."
cp -f ".build/release/${EXECUTABLE_NAME}" "${MACOS_DIR}/"

# 复制Info.plist
echo -e "${BLUE}[INFO]${RESET} 正在复制Info.plist..."
cp -f "${INFO_PLIST}" "${PLIST_DEST}"

# 创建PkgInfo文件
echo -e "${BLUE}[INFO]${RESET} 正在创建PkgInfo..."
echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# 检查并复制应用图标
echo -e "${BLUE}[INFO]${RESET} 正在检查应用图标..."
if [ -d "AppIcon.iconset" ]; then
    echo -e "${BLUE}[INFO]${RESET} 正在处理应用图标..."
    if command -v iconutil &> /dev/null; then
        iconutil -c icns AppIcon.iconset -o "${RESOURCES_DIR}/AppIcon.icns"
        echo -e "${GREEN}[SUCCESS]${RESET} 应用图标已生成并复制"
    else
        echo -e "${YELLOW}[WARNING]${RESET} 找不到iconutil工具，尝试直接复制图标文件..."
        cp -f AppIcon.icns "${RESOURCES_DIR}/" 2>/dev/null || echo -e "${YELLOW}[WARNING]${RESET} 无法复制AppIcon.icns"
    fi
else
    echo -e "${YELLOW}[WARNING]${RESET} 未找到AppIcon.iconset目录，应用将使用默认图标"
    # 检查是否有直接的icns文件
    if [ -f "AppIcon.icns" ]; then
        cp -f AppIcon.icns "${RESOURCES_DIR}/"
        echo -e "${GREEN}[SUCCESS]${RESET} 已复制AppIcon.icns到Resources目录"
    fi
fi

# 设置文件权限
echo -e "${BLUE}[INFO]${RESET} 正在设置权限..."
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod -R 755 "${APP_DIR}"

echo -e "${GREEN}[SUCCESS]${RESET} 应用程序包创建成功"

# 尝试应用签名
echo -e "${BLUE}[INFO]${RESET} 正在尝试对应用程序进行签名..."
if codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${RESET} 应用程序签名成功"
else
    echo -e "${YELLOW}[WARNING]${RESET} 签名失败，但这不影响应用程序使用"
fi

# 移除隔离属性
echo -e "${BLUE}[INFO]${RESET} 正在移除应用程序的隔离属性..."
if xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${RESET} 隔离属性移除成功"
else
    echo -e "${YELLOW}[WARNING]${RESET} 尝试移除隔离属性时出错，但这可能不会影响应用程序"
fi

# 检查并创建启动脚本
echo -e "${BLUE}[INFO]${RESET} 正在检查启动脚本..."
if [ -f "launch.sh" ]; then
    echo -e "${BLUE}[INFO]${RESET} 启动脚本已存在，跳过创建"
else
    cat > launch.sh << 'EOF'
#!/bin/bash

# 定义应用程序路径
APP_DIR="CryptoStatusBar.app"
EXEC_PATH="${APP_DIR}/Contents/MacOS/CryptoStatusBar"

# 检查应用程序是否存在
if [ ! -f "${EXEC_PATH}" ]; then
    echo "错误：找不到应用程序，请先运行 build_app.sh 构建应用程序。"
    exit 1
fi

# 设置执行权限
chmod +x "${EXEC_PATH}"

# 移除隔离属性（如果有）
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null

# 直接运行可执行文件
echo "正在启动CryptoStatusBar应用程序..."
nohup "${EXEC_PATH}" > /dev/null 2>&1 &

echo "应用程序已启动，请检查屏幕顶部菜单栏是否显示BTC价格。"
echo "如果需要退出应用程序，请点击菜单栏图标，选择'退出'选项。" 
EOF
    chmod +x launch.sh
    echo -e "${GREEN}[SUCCESS]${RESET} 启动脚本创建成功"
fi

echo -e "${BLUE}==========================================${RESET}"
echo -e "${GREEN}[SUCCESS]${RESET} 应用程序打包完成：${APP_DIR}"
echo -e "现在可以使用以下方式启动应用程序："
echo -e "1. 执行 ./launch.sh"
echo -e "2. 双击 ${APP_DIR} 图标"
echo -e "3. 在终端执行 open ${APP_DIR}"
echo -e "${BLUE}==========================================${RESET}"
echo -e "如果看到'应用程序已损坏'的错误提示，请尝试以下方法："
echo -e "1. 右键点击(或Control+点击)应用程序，选择'打开'，然后在弹出的对话框中再次选择'打开'"
echo -e "2. 或者在终端执行：xattr -dr com.apple.quarantine ${APP_DIR}"
echo -e "3. 或者使用 ./launch.sh 脚本启动，它会自动处理这些问题"
echo -e "${BLUE}==========================================${RESET}" 