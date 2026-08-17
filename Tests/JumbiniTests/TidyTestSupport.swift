import Foundation

final class TemporaryDirectory {
    let url: URL

    private init(url: URL) {
        self.url = url
    }

    static func make() throws -> TemporaryDirectory {
        var template = FileManager.default.temporaryDirectory
            .appendingPathComponent("JumbiniTests.XXXXXX").path.utf8CString
        let url = try template.withUnsafeMutableBufferPointer { buffer in
            guard let path = mkdtemp(buffer.baseAddress) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return TemporaryDirectory(url: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func writeFixture(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}
