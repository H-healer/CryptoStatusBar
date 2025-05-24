// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "CryptoStatusBar",
    platforms: [.macOS(.v12)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CryptoStatusBar",
            path: ".",
            exclude: [
                "build_app.sh",
                "launch.sh",
                "使用说明.md",
                "CryptoStatusBar.app",
                "Sources.txt",
                "Info.plist",
                "create_app_icon.sh",
                "AppIcon.icns",
                "AppIcon.iconset",
                "如何添加应用图标.md",
                "README.md",
                "README_EN.md",
                "img"
            ]
        )
    ]
) 