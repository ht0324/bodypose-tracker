import Foundation

final class FileLog {
    private static let maxLogBytes = 5 * 1024 * 1024

    private let queue = DispatchQueue(label: "BodyPoseTracker.log")
    private let url: URL

    init(url: URL) {
        self.url = url
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingSize = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if !manager.fileExists(atPath: url.path) || existingSize > Self.maxLogBytes {
            manager.createFile(atPath: url.path, contents: nil)
        }
    }

    func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        print(message)
    }
}
