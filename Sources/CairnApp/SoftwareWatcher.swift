import CoreServices
import Foundation

/// Notices apps and packages being installed or removed while Cairn runs: watches
/// the Applications folders and Homebrew's Cellar and Caskroom, and calls back a
/// while after the last change (an install touches many files).
final class SoftwareWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void
    /// Wait this long after the last file change before checking.
    let settle: TimeInterval

    init(settle: TimeInterval = 45, onChange: @escaping @MainActor () -> Void) {
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    static var paths: [String] {
        let home = NSHomeDirectory()
        return ["/Applications", home + "/Applications",
                "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/Cellar", "/usr/local/Caskroom"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard stream == nil, !Self.paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SoftwareWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, Self.paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// On the main queue (the stream's queue).
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in MainActor.assumeIsolated { onChange() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
