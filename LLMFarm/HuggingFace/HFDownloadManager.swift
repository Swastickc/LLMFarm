//
//  HFDownloadManager.swift
//  LLMFarm
//
//  Background download manager for GGUF model files from HuggingFace.
//  Uses URLSession background configuration so downloads survive app suspension.
//  Files are saved to Documents/models/ where LLMFarm auto-discovers them.
//

import Foundation
import SwiftUI

// MARK: - Download State

enum DownloadState: Equatable {
    case idle
    case downloading(progress: Double)
    case completed
    case failed(error: String)

    var isActive: Bool {
        if case .downloading = self { return true }
        return false
    }
}

// MARK: - Download Info

struct DownloadInfo: Identifiable {
    let id: String               // same as LLMModel.id
    let model: LLMModel
    var state: DownloadState
    var bytesDownloaded: Int64
    var totalBytes: Int64

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var progressLabel: String {
        let downloadedMB = Double(bytesDownloaded) / (1024 * 1024)
        let totalMB = Double(totalBytes) / (1024 * 1024)
        if totalMB >= 1024 {
            return String(format: "%.1f / %.1f GB", downloadedMB / 1024, totalMB / 1024)
        }
        return String(format: "%.0f / %.0f MB", downloadedMB, totalMB)
    }
}

// MARK: - HFDownloadManager

final class HFDownloadManager: NSObject, ObservableObject {

    static let shared = HFDownloadManager()

    /// Active and recently completed downloads, keyed by LLMModel.id
    @Published var downloads: [String: DownloadInfo] = [:]

    // Maps URLSessionTask identifiers → LLMModel for delegate callbacks.
    // Accessed from URLSession delegate queue — guarded by lock.
    private var taskModelMap: [Int: LLMModel] = [:]
    private let lock = NSLock()

    private static let sessionIdentifier = "com.llmfarm.hf-downloads"

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// The directory where LLMFarm looks for model files.
    var modelsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Init

    private override init() {
        super.init()
        // Reconnect to any in-progress tasks from a previous launch.
        reconnectExistingTasks()
    }

    /// Restores download state for tasks that survived app relaunch.
    private func reconnectExistingTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            for task in tasks where task.state == .running || task.state == .suspended {
                // We can't fully restore LLMModel metadata here without persistence.
                // The task will continue downloading; progress updates fire normally
                // once the delegate reconnects.
                _ = self // keep reference alive
            }
        }
    }

    // MARK: - Public API

    /// Starts downloading a model file. No-op if already downloading.
    @MainActor
    func startDownload(model: LLMModel) {
        if case .downloading = downloads[model.id]?.state { return }
        if isModelDownloaded(filename: model.filename) {
            downloads[model.id] = DownloadInfo(
                id: model.id,
                model: model,
                state: .completed,
                bytesDownloaded: 0,
                totalBytes: 0
            )
            return
        }

        let task = backgroundSession.downloadTask(with: model.downloadURL)
        lock.withLock {
            taskModelMap[task.taskIdentifier] = model
        }

        downloads[model.id] = DownloadInfo(
            id: model.id,
            model: model,
            state: .downloading(progress: 0),
            bytesDownloaded: 0,
            totalBytes: Int64(model.sizeGB * 1024 * 1024 * 1024)
        )

        task.resume()
    }

    /// Cancels an in-progress download and removes its tracking entry.
    func cancelDownload(modelId: String) {
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks {
                let mapped: LLMModel? = self.lock.withLock { self.taskModelMap[task.taskIdentifier] }
                if mapped?.id == modelId {
                    task.cancel()
                    self.lock.withLock { self.taskModelMap.removeValue(forKey: task.taskIdentifier) }
                }
            }
            Task { @MainActor in
                self.downloads.removeValue(forKey: modelId)
            }
        }
    }

    /// Deletes a downloaded model file from disk.
    @MainActor
    func deleteModel(model: LLMModel) -> Bool {
        let filePath = modelsDirectory.appendingPathComponent(model.filename)
        do {
            try FileManager.default.removeItem(at: filePath)
            downloads.removeValue(forKey: model.id)
            return true
        } catch {
            print("Delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Checks whether a GGUF file exists in the models directory.
    func isModelDownloaded(filename: String) -> Bool {
        FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent(filename).path
        )
    }

    /// Returns the on-disk size of a downloaded model, or nil if not present.
    func modelFileSize(filename: String) -> UInt64? {
        let path = modelsDirectory.appendingPathComponent(filename).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return size
    }

    /// Formatted disk usage string for a model file.
    func modelDiskUsage(filename: String) -> String {
        guard let bytes = modelFileSize(filename: filename) else { return "–" }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.0f MB", gb * 1024)
    }

    /// Current download state for a model, or .idle if not tracked.
    func downloadState(for modelId: String) -> DownloadState {
        downloads[modelId]?.state ?? .idle
    }

    /// Returns all downloaded GGUF model filenames.
    func allDownloadedFilenames() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .map { $0.lastPathComponent }
            .filter { $0.hasSuffix(".gguf") }
    }

    /// Total disk space used by all downloaded models.
    func totalDiskUsage() -> String {
        let filenames = allDownloadedFilenames()
        var total: UInt64 = 0
        for name in filenames {
            total += modelFileSize(filename: name) ?? 0
        }
        let gb = Double(total) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.0f MB", gb * 1024)
    }
}

// MARK: - URLSessionDownloadDelegate

extension HFDownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let model: LLMModel? = lock.withLock { taskModelMap[downloadTask.taskIdentifier] }
        guard let model else { return }

        let destination = modelsDirectory.appendingPathComponent(model.filename)

        do {
            // Remove any existing file at destination (e.g. partial from a prior attempt)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            Task { @MainActor in
                self.downloads[model.id]?.state = .completed
                self.downloads[model.id]?.bytesDownloaded = self.downloads[model.id]?.totalBytes ?? 0
            }
        } catch {
            Task { @MainActor in
                self.downloads[model.id]?.state = .failed(error: "Save failed: \(error.localizedDescription)")
            }
        }

        lock.withLock { taskModelMap.removeValue(forKey: downloadTask.taskIdentifier) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let model: LLMModel? = lock.withLock { taskModelMap[downloadTask.taskIdentifier] }
        guard let model else { return }

        let progress: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        Task { @MainActor in
            self.downloads[model.id]?.state = .downloading(progress: progress)
            self.downloads[model.id]?.bytesDownloaded = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                self.downloads[model.id]?.totalBytes = totalBytesExpectedToWrite
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        let model: LLMModel? = lock.withLock { taskModelMap[task.taskIdentifier] }
        guard let model else { return }

        // Cancellation is intentional — don't surface as an error
        if (error as NSError).code == NSURLErrorCancelled { return }

        Task { @MainActor in
            self.downloads[model.id]?.state = .failed(error: error.localizedDescription)
        }

        lock.withLock { taskModelMap.removeValue(forKey: task.taskIdentifier) }
    }
}
