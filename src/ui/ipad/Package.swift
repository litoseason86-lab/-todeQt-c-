// swift-tools-version: 6.0
import PackageDescription

// 数据层在 macOS 上测试；界面层由 CMake 仅在 iOS 编译，避免测试包依赖 UIKit。
let package = Package(
    name: "IPadFrontend",
    platforms: [.macOS(.v14)],
    products: [.library(name: "IPadCore", targets: ["IPadCore"])],
    targets: [
        .target(name: "IPadCore"),
        .testTarget(name: "IPadCoreTests", dependencies: ["IPadCore"],
                    resources: [.copy("Fixtures")])
    ]
)
