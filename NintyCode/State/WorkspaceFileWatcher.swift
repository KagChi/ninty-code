import CoreServices
import Foundation
import NintyCore

/// Watches workspace roots for file changes via FSEvents. All operations run on
/// DispatchQueue.main; debounce throttles rapid bursts so indexing is cheap.
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
            DispatchQueue.main.async { FSEventStreamRelease(stream) }
        }
    }

    func start(roots: [URL], onChange: @escaping @MainActor () async -> Void) {
        lock.lock()
        self.onChange = onChange
        let paths = roots.map(\.path)
        
        // Skip if already watching same paths.
        if stream != nil, paths == watchedPaths {
            lock.unlock()
            return
        }
        watchedPaths = paths

        // Stop existing stream first, setting nil immediately.
        if let old = stream {
            stream = nil
            FSEventStreamStop(old)
            FSEventStreamInvalidate(old)
            DispatchQueue.main.async { FSEventStreamRelease(old) }
        }
        debounceTask?.cancel()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // Use explicit FSEventStreamCallback type for proper calling convention.
        let callback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
            guard let info = clientInfo else { return }
            let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handle(eventPathsPtr: eventPaths)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
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
        var oldStream: FSEventStreamRef?
        if let s = stream {
            oldStream = s
            self.stream = nil
        }
        onChange = nil
        debounceTask?.cancel()
        debounceTask = nil
        lock.unlock()

        if let oldStream {
            FSEventStreamStop(oldStream)
            FSEventStreamInvalidate(oldStream)
            DispatchQueue.main.async { FSEventStreamRelease(oldStream) }
        }
    }

    private func handle(eventPathsPtr: UnsafeMutableRawPointer?) {
        lock.lock()
        let current = stream
        let interval = debounce
        guard let callback = onChange else { return }
        lock.unlock()

        guard let ptr = eventPathsPtr, current != nil else { return }

        // Decode eventPaths as CFArray<CFString> (paths that changed).
        // takeRetainedValue transfers ownership to ARC — released automatically.
        let cfArray = Unmanaged<CFArray>.fromOpaque(ptr).takeRetainedValue()

        var paths: [String] = []
        let count = CFArrayGetCount(cfArray)
        paths.reserveCapacity(count)
        for index in 0..<count {
            guard let item = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            
            // Filter build artifacts / skipped dirs.
            let cfString = unsafeBitCast(item, to: CFString.self)
            if let str = cfString as? String {
                if !str.split(separator: "/").contains(where: { GraphExtractor.skippedDirectories.contains(String($0)) }) {
                    paths.append(str)
                }
            }
        }
        guard !paths.isEmpty else { return }
        guard !paths.isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self = self, self.onChange != nil else { return }
            await callback()
        }
    }
}
