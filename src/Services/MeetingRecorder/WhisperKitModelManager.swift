import Foundation
import WhisperKit

public enum WhisperModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(sizeBytes: Int64)
    case failed(String)

    public var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

public enum WhisperModelManagerError: Error, LocalizedError, Equatable, Sendable {
    case invalidModelBundle(String)
    case downloadCancelled

    public var errorDescription: String? {
        switch self {
        case .invalidModelBundle(let variant):
            return "Downloaded Whisper AI model '\(variant)' failed integrity verification."
        case .downloadCancelled:
            return "Whisper AI model download was cancelled."
        }
    }
}

/// Manages on-demand download, integrity verification, and local caching of WhisperKit CoreML models (#204).
@MainActor
public final class WhisperKitModelManager: ObservableObject {
    public typealias ModelDownloader = @Sendable (
        _ variant: WhisperModelVariant,
        _ downloadBase: URL,
        _ onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    nonisolated public static let requiredModelComponents = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "config.json"
    ]

    nonisolated public static var defaultModelsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Bitz", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
    }

    @Published public private(set) var states: [WhisperModelVariant: WhisperModelState] = [:]

    public let modelsRootURL: URL
    private let downloader: ModelDownloader
    private var activeDownloadTasks: [WhisperModelVariant: Task<URL, Error>] = [:]

    public init(
        modelsRootURL: URL = WhisperKitModelManager.defaultModelsRootURL,
        downloader: ModelDownloader? = nil
    ) {
        self.modelsRootURL = modelsRootURL
        self.downloader = downloader ?? { variant, downloadBase, onProgress in
            try await WhisperKit.download(
                variant: variant.rawValue,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                progressCallback: { progress in
                    onProgress(progress.fractionCompleted)
                }
            )
        }
        refreshAllStatuses()
    }

    public func state(for variant: WhisperModelVariant) -> WhisperModelState {
        states[variant] ?? .notDownloaded
    }

    nonisolated public func modelFolderURL(for variant: WhisperModelVariant) -> URL {
        modelsRootURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    nonisolated public static func isModelValid(at folderURL: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        for component in requiredModelComponents {
            let componentURL = folderURL.appendingPathComponent(component)
            guard fileManager.fileExists(atPath: componentURL.path) else {
                return false
            }
            if component.hasSuffix(".mlmodelc") {
                let contents = (try? fileManager.contentsOfDirectory(atPath: componentURL.path)) ?? []
                if contents.isEmpty { return false }
            }
        }
        return true
    }

    nonisolated public static func directorySizeBytes(at url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    public func refreshAllStatuses() {
        for variant in WhisperModelVariant.allCases {
            refreshStatus(for: variant)
        }
    }

    public func refreshStatus(for variant: WhisperModelVariant) {
        if activeDownloadTasks[variant] != nil { return }
        let folderURL = modelFolderURL(for: variant)
        if Self.isModelValid(at: folderURL) {
            let size = Self.directorySizeBytes(at: folderURL)
            states[variant] = .downloaded(sizeBytes: size)
        } else {
            states[variant] = .notDownloaded
        }
    }

    public func ensureModelDownloaded(
        _ variant: WhisperModelVariant,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let localURL = modelFolderURL(for: variant)
        if Self.isModelValid(at: localURL) {
            let size = Self.directorySizeBytes(at: localURL)
            states[variant] = .downloaded(sizeBytes: size)
            onProgress?(1.0)
            return localURL
        }

        if let existingTask = activeDownloadTasks[variant] {
            return try await existingTask.value
        }

        try FileManager.default.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
        states[variant] = .downloading(progress: 0.0)

        let rootURL = modelsRootURL
        let downloadFn = downloader
        let progressCallback: @MainActor @Sendable (Double) -> Void = { [weak self] clamped in
            guard let self, self.activeDownloadTasks[variant] != nil else { return }
            self.states[variant] = .downloading(progress: clamped)
            onProgress?(clamped)
        }
        let task = Task<URL, Error> {
            let downloadedURL = try await downloadFn(variant, rootURL) { fraction in
                let clamped = min(max(fraction, 0.0), 1.0)
                Task { @MainActor in
                    progressCallback(clamped)
                }
            }
            try Task.checkCancellation()
            return downloadedURL
        }

        activeDownloadTasks[variant] = task
        defer { activeDownloadTasks[variant] = nil }

        do {
            let downloadedURL = try await task.value
            let resolvedURL = Self.isModelValid(at: downloadedURL) ? downloadedURL : localURL
            guard Self.isModelValid(at: resolvedURL) else {
                try? FileManager.default.removeItem(at: resolvedURL)
                let error = WhisperModelManagerError.invalidModelBundle(variant.rawValue)
                states[variant] = .failed(error.localizedDescription)
                throw error
            }
            let size = Self.directorySizeBytes(at: resolvedURL)
            states[variant] = .downloaded(sizeBytes: size)
            onProgress?(1.0)
            return resolvedURL
        } catch where Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (error as? WhisperModelManagerError) == .downloadCancelled {
            states[variant] = .notDownloaded
            throw WhisperModelManagerError.downloadCancelled
        } catch {
            states[variant] = .failed(error.localizedDescription)
            throw error
        }
    }

    public func cancelDownload(for variant: WhisperModelVariant) {
        activeDownloadTasks[variant]?.cancel()
        activeDownloadTasks[variant] = nil
        refreshStatus(for: variant)
    }

    public func deleteModel(_ variant: WhisperModelVariant) throws {
        cancelDownload(for: variant)
        let folderURL = modelFolderURL(for: variant)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
        states[variant] = .notDownloaded
    }
}
