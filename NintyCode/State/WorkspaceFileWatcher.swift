import CoreServices
import Foundation
import NintyCore

/// Watches workspace roots for file changes (FSEvents) and fires a
/// debounced callback. Feeds GraphSyncService so the code graph stays
/// current when files change OUTSIDE the app (user's editor, git pulls) —
/// previously only agent-made edits and app launches refreshed the index.
///
/// Threading: callbacks AND start/stop both run on the main queue, so all
/// state handoffs are serialized. Stream teardown defers FSEventStreamRelease
/// so already-enqueued callbacks never touch a freed stream (that raced and
/// crashed with EXC_BAD_ACCESS on the eventPaths cast).
final class WorkspaceFileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let lock = NSLock()
    private var debounceTask: Task<Void, Never>?
    private var onChange: (@MainActor () async -> Void)?
    private let debounce: TimeInterval

    init(debounce: TimeInterval = 5) {
        self.debounce = debounce
    }

    deinit {
        debounceTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Deferred like start()/stop(): main-queue callbacks enqueued
            // before invalidate must finish before the stream is freed.
            DispatchQueue.main.async { FSEventStreamRelease(stream) }
        }
    }

    func start(roots: [URL], onChange: @escaping @MainActor () async -> Void) {
        lock.lock()
        self.onChange = onChange
        let paths = roots.map(\.path)
        // openWorkspace runs on every tab activation — same roots must NOT
        // tear down the stream (recreate churn is what raced callbacks).
        if stream != nil, paths == watchedPaths {
            lock.unlock()
            return
        }
        watchedPaths = paths
        if let old = stream {
            FSEventStreamStop(old)
            FSEventStreamInvalidate(old)
            // Deferred: callbacks already on the main queue still reference
            // this stream's eventPaths buffer.
            DispatchQueue.main.async { FSEventStreamRelease(old) }
            stream = nil
        }
        debounceTask?.cancel()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { streamRef, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handle(stream: streamRef, eventPaths: eventPaths)
            },
            &context,
            paths as CFArray,
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
        watchedPaths = []
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            DispatchQueue.main.async { FSEventStreamRelease(stream) }
            self.stream = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        onChange = nil
        lock.unlock()
    }

    private func handle(stream streamRef: FSEventStreamRef, eventPaths: UnsafeMutableRawPointer) {
        // Stale callback from a superseded stream — drop it.
        lock.lock()
        let isCurrent = streamRef == stream
        lock.unlock()
        guard isCurrent else { return }

        // eventPaths is a CFArray of CFStrings. Extract element-by-element
        // via plain C APIs — never bridge the whole array blindly (a freed
        // buffer once reached that cast and took the app down).
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let count = CFArrayGetCount(cfArray)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for index in 0..<count {
            guard let item = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            // Elements are CFStrings; macOS 26 imports the accessors typed.
            let cfString = unsafeBitCast(item, to: CFString.self)
            if let cString = CFStringGetCStringPtr(cfString, CFStringBuiltInEncodings.UTF8.rawValue) {
                paths.append(String(cString: cString))
                continue
            }
            var buffer = [CChar](repeating: 0, count: 4096) // PATH_MAX × max UTF-8 width
            if CFStringGetCString(cfString, &buffer, CFIndex(buffer.count), CFStringBuiltInEncodings.UTF8.rawValue) {
                paths.append(String(cString: buffer))
            }
        }
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
