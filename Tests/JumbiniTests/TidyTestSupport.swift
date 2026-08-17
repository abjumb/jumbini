import Foundation
@testable import Jumbini

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

extension TidyPlan {
    static func fixture(moveCount: Int) -> TidyPlan {
        let root = URL(fileURLWithPath: "/tmp/JumbiniTidyFixture", isDirectory: true)
        let ruleID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_000_000)
        let moves = (0..<moveCount).map { index in
            let name = "file \(index + 1).png"
            return TidyPlannedMove(
                id: UUID(),
                source: root.appendingPathComponent(name),
                destination: root.appendingPathComponent("Images/\(name)"),
                sourceID: TidyFileID(device: 1, inode: UInt64(index + 1)),
                modifiedAt: modifiedAt,
                ruleID: ruleID,
                ruleName: "Images"
            )
        }
        return TidyPlan(root: root, movable: moves, skipped: [])
    }
}

extension TidyCompletedMove {
    static func fixture(index: Int) -> TidyCompletedMove {
        let root = URL(fileURLWithPath: "/tmp/JumbiniTidyFixture", isDirectory: true)
        let name = "file \(index + 1).png"
        return TidyCompletedMove(
            source: root.appendingPathComponent(name),
            destination: root.appendingPathComponent("Images/\(name)"),
            fileID: TidyFileID(device: 1, inode: UInt64(index + 1)),
            ruleID: UUID(uuidString: "A7ACEE7D-5CB0-4C6E-A17E-B43E3EFD12A4")!,
            ruleName: "Images"
        )
    }

    static func fixture(source: String, destination: String) -> TidyCompletedMove {
        let fixture = fixture(index: 0)
        return TidyCompletedMove(
            source: URL(fileURLWithPath: source),
            destination: URL(fileURLWithPath: destination),
            fileID: fixture.fileID,
            ruleID: fixture.ruleID,
            ruleName: fixture.ruleName
        )
    }
}
