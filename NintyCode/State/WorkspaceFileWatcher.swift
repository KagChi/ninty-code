import CoreServices
import Foundation
import NintyCore

/// Watches workspace roots for file changes (FSEvents) and fires a
/// debounced callback. Feeds GraphSyncService so the code graph stays
/// current when files change OUTSIDE the app (user's editor, git pulls) —
/// previously only agent-made edits and app launches refreshed the index.
final class WorkspaceFileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var debounceTask: Task<Void, Never>?
    private var onChange: (@MainActor () async -> Void)?
    private let debounce: TimeInterval

    init(debounce: TimeInterval = 5) {
        self.debounce = debounce
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        debounceTask?.cancel()
    }

    func start(roots: [URL], onChange: @escaping @MainActor () async -> Void) {
        lock.lock()
        self.onChange = onChange
        if let old = stream {
            FSEventStreamStop(old)
            FSEventStreamInvalidate(old)
            FSEventStreamRelease(old)
            stream = nil
        }
        debounceTask?.cancel()

        let paths = roots.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handle(eventPaths: eventPaths)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // coalesce bursts; the debounce below does the real throttling
            UInt32(kFSEventStreamCreateFlagFileEvents)
        ) else {
            lock.unlock()
            return
        }
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stop() {
        lock.lock()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        onChange = nil
        lock.unlock()
    }

    private func handle(eventPaths: UnsafeMutableRawPointer) {
        let array = Unmanaged<NSMutableArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let paths = array as? [String] else { return }
        // Ignore noise: skipped build/dep dirs (GraphExtractor never indexes them).
        let relevant = paths.contains { path in
            !path.split(separator: "/").contains {
                GraphExtractor.skippedDirectories.contains(String($0))
            }
        }
        guard relevant else { return }

        // Snapshot under the lock; the async debounce task must never touch it.
        lock.lock()
        debounceTask?.cancel()
        let interval = debounce
        let callback = onChange
        lock.unlock()
        guard let callback else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, self != nil else { return }
            await callback()
        }
    }
}
