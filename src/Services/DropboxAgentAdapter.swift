import Foundation

/// Agent adapter that monitors a drop-box directory for JSON event files.
public final class DropboxAgentAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "dropbox-agent-adapter"

    public let directoryURL: URL
    private let clock: @Sendable () -> Date
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var source: DispatchSourceFileSystemObject? = nil
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.bitz.agent.dropbox", qos: .utility)

    public static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bitz/agent-events")
    }

    public init(
        directoryURL: URL = DropboxAgentAdapter.defaultDirectoryURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL
        self.clock = clock
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.eventHandler = onEvent

        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        // Process any existing files right away
        processPendingFiles()

        // Setup DispatchSource to watch directory changes
        fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .link, .rename],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.processPendingFiles()
        }

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        eventHandler = nil
    }

    /// Public method to trigger directory scan, convenient for unit tests.
    public func processPendingFiles() {
        guard let handler = eventHandler else { return }

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        let now = clock()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension.lowercased() == "json" {
            defer {
                try? fileManager.removeItem(at: file)
            }

            guard let data = try? Data(contentsOf: file) else { continue }
            guard let event = try? decoder.decode(AgentEvent.self, from: data) else { continue }

            // Drop stale events older than 60s
            if now.timeIntervalSince(event.timestamp) <= 60.0 {
                handler(event)
            }
        }
    }
}
