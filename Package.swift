// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LectureCore", products: [.library(name: "LectureCore", targets: ["LectureCore"])], targets: [
    .target(name: "LectureCore", path: "Core"),
    .testTarget(name: "LectureCoreTests", dependencies: ["LectureCore"])
])
