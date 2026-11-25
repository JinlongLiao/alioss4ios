// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "alioss4ios",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "alioss4ios", targets: ["alioss4ios"])],
    dependencies: [
        .package(url: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2.git", exact: "0.4.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.8.35"),
    ],
    targets: [
        .executableTarget(
            name: "alioss4ios",
            dependencies: [
                .product(name: "AlibabaCloudOSS", package: "alibabacloud-oss-swift-sdk-v2"),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            exclude: ["AppAssets.xcassets"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "alioss4iosTests", dependencies: ["alioss4ios"]),
    ]
)
