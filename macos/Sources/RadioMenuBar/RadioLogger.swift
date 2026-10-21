import Foundation

final class RadioLogger {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MPV Radio Tray", isDirectory: true)
    }
    private let queue = DispatchQueue(label: "radio.logging")
    private var handle: FileHandle?
    private var size = 0
    private let formatter = ISO8601DateFormatter()
    private let limit = 512 * 1024

    init() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try open()
        } catch { NSLog("Radio log unavailable: %@", (error as NSError).domain) }
    }

    private func open() throws {
        let url = Self.directory.appendingPathComponent("radio.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let opened = try FileHandle(forWritingTo: url)
        size = Int(try opened.seekToEnd())
        handle = opened
    }

    func write(_ message: String) {
        NSLog("%@", message)
        queue.async {
            do {
                if self.size >= self.limit {
                    try self.handle?.close()
                    self.handle = nil
                    let previous = Self.directory.appendingPathComponent("radio.previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: Self.directory.appendingPathComponent("radio.log"), to: previous)
                    try self.open()
                }
                let data = Data("\(self.formatter.string(from: Date())) \(message)\n".utf8)
                try self.handle?.write(contentsOf: data)
                self.size += data.count
            } catch { NSLog("Radio log write failed") }
        }
    }

    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }
}
