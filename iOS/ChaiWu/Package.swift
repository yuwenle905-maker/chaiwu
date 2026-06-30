// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChaiWu",
    platforms: [.iOS(.v16)],
    dependencies: [
        // OOXML 读取（可选，当前使用内置解析器）
        // .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
    ],
    targets: [
        .target(name: "ChaiWu", dependencies: [])
    ]
)
