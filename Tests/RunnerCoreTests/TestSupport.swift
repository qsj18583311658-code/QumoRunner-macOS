import Foundation
import Testing

enum TestSupport {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func fakeLibTV() throws -> URL {
        let source = try #require(Bundle.module.url(
                forResource: "fake-libtv",
                withExtension: "sh",
                subdirectory: "Resources"
            ))
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("libtv")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }
}
