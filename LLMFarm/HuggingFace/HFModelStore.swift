//
//  HFModelStore.swift
//  LLMFarm
//
//  HuggingFace model browser — ViewModel + API service.
//  Fetches GGUF models from HF Hub, filters by size for iPhone safety,
//  and maintains a curated list of verified starter models.
//

import Foundation
import SwiftUI

// MARK: - Data Model

struct LLMModel: Identifiable, Hashable {
    let id: String              // unique, e.g. "Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf"
    let name: String            // display name
    let repoId: String          // HF repo, e.g. "Qwen/Qwen2.5-0.5B-Instruct-GGUF"
    let filename: String        // .gguf filename
    let sizeGB: Double          // download size in GB
    let ramRequiredGB: Double   // approx sizeGB * 1.3
    let description: String
    let tags: [String]
    let quantization: String    // Q4_K_M, Q8_0, etc.

    var downloadURL: URL {
        // HF direct file download URL
        URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(filename)")!
    }

    var tier: ModelTier {
        if sizeGB < 1.0 { return .ultraLight }
        else if sizeGB < 2.0 { return .light }
        else { return .medium }
    }

    var sizeLabel: String {
        if sizeGB < 1.0 {
            return String(format: "%.0f MB", sizeGB * 1024)
        }
        return String(format: "%.1f GB", sizeGB)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LLMModel, rhs: LLMModel) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Tier & Filter Enums

enum ModelTier: String, CaseIterable {
    case ultraLight = "Ultra Light"
    case light = "Light"
    case medium = "Medium"

    var emoji: String {
        switch self {
        case .ultraLight: return "🪶"
        case .light: return "⚡"
        case .medium: return "🔥"
        }
    }

    var badge: String { "\(emoji) \(rawValue)" }
}

enum ModelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case ultraLight = "🪶 Ultra Light"
    case light = "⚡ Light"
    case medium = "🔥 Medium"
    case downloaded = "Downloaded"

    var id: String { rawValue }
}

// MARK: - HuggingFace API Response Types (private)

private struct HFModelResponse: Decodable {
    let id: String
    let author: String?
    let tags: [String]?
    let likes: Int?
    let downloads: Int?
    let siblings: [HFSibling]?
}

private struct HFSibling: Decodable {
    let rfilename: String
    let size: Int64?
    let lfs: HFLFSInfo?

    var effectiveSize: Int64? {
        lfs?.size ?? size
    }
}

private struct HFLFSInfo: Decodable {
    let size: Int64
    let sha256: String?
    let pointerSize: Int?
}

// MARK: - HFModelStore

@MainActor
final class HFModelStore: ObservableObject {

    @Published var models: [LLMModel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var activeFilter: ModelFilter = .all

    private let maxSizeGB: Double = 3.5
    private let apiBaseURL = "https://huggingface.co/api/models"

    /// Cancels in-flight search when a new one starts.
    private var searchTask: Task<Void, Never>?

    /// Simple response cache keyed by URL string — avoids re-fetching identical queries.
    private var responseCache: [String: [LLMModel]] = [:]
    private let cacheLimit = 20

    // MARK: - Filtered output

    var filteredModels: [LLMModel] {
        var result = models

        switch activeFilter {
        case .all:
            break
        case .ultraLight:
            result = result.filter { $0.sizeGB < 1.0 }
        case .light:
            result = result.filter { $0.sizeGB >= 1.0 && $0.sizeGB < 2.0 }
        case .medium:
            result = result.filter { $0.sizeGB >= 2.0 && $0.sizeGB <= maxSizeGB }
        case .downloaded:
            let downloaded = downloadedModelFilenames()
            result = result.filter { downloaded.contains($0.filename) }
        }

        if !searchText.isEmpty {
            let query = searchText
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.repoId.localizedCaseInsensitiveContains(query) ||
                $0.quantization.localizedCaseInsensitiveContains(query)
            }
        }

        return result
    }

    // MARK: - Curated starter models (verified iPhone-compatible)

    static let curatedModels: [LLMModel] = [
        LLMModel(
            id: "HuggingFaceTB/SmolLM2-135M-Instruct-GGUF/smollm2-135m-instruct-q8_0.gguf",
            name: "SmolLM2 135M Q8",
            repoId: "HuggingFaceTB/SmolLM2-135M-Instruct-GGUF",
            filename: "smollm2-135m-instruct-q8_0.gguf",
            sizeGB: 0.15,
            ramRequiredGB: 0.20,
            description: "Tiny but capable — great for testing",
            tags: ["smollm", "instruct", "gguf"],
            quantization: "Q8_0"
        ),
        LLMModel(
            id: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF/smollm2-360m-instruct-q8_0.gguf",
            name: "SmolLM2 360M Q8",
            repoId: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF",
            filename: "smollm2-360m-instruct-q8_0.gguf",
            sizeGB: 0.38,
            ramRequiredGB: 0.49,
            description: "Small and fast, good quality for size",
            tags: ["smollm", "instruct", "gguf"],
            quantization: "Q8_0"
        ),
        LLMModel(
            id: "Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf",
            name: "Qwen 2.5 0.5B Q4_K_M",
            repoId: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
            filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            sizeGB: 0.40,
            ramRequiredGB: 0.52,
            description: "Alibaba's compact multilingual model",
            tags: ["qwen", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            name: "TinyLlama 1.1B Q4_K_M",
            repoId: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
            filename: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            sizeGB: 0.67,
            ramRequiredGB: 0.87,
            description: "Popular tiny model, good all-rounder",
            tags: ["llama", "chat", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "bartowski/Llama-3.2-1B-Instruct-GGUF/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            name: "Llama 3.2 1B Q4_K_M",
            repoId: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            sizeGB: 0.75,
            ramRequiredGB: 0.98,
            description: "Meta's latest small Llama — excellent quality",
            tags: ["llama", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            name: "Qwen 2.5 1.5B Q4_K_M",
            repoId: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            sizeGB: 1.0,
            ramRequiredGB: 1.3,
            description: "Strong multilingual, great bang-for-buck",
            tags: ["qwen", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "bartowski/gemma-2-2b-it-GGUF/gemma-2-2b-it-Q4_K_M.gguf",
            name: "Gemma 2 2B Q4_K_M",
            repoId: "bartowski/gemma-2-2b-it-GGUF",
            filename: "gemma-2-2b-it-Q4_K_M.gguf",
            sizeGB: 1.6,
            ramRequiredGB: 2.1,
            description: "Google's Gemma 2 — punches above its weight",
            tags: ["gemma", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "bartowski/Llama-3.2-3B-Instruct-GGUF/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            name: "Llama 3.2 3B Q4_K_M",
            repoId: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            sizeGB: 1.9,
            ramRequiredGB: 2.5,
            description: "Best small Llama — strong reasoning",
            tags: ["llama", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
        LLMModel(
            id: "bartowski/Phi-3.5-mini-instruct-GGUF/Phi-3.5-mini-instruct-Q4_K_M.gguf",
            name: "Phi-3.5 Mini 3.8B Q4_K_M",
            repoId: "bartowski/Phi-3.5-mini-instruct-GGUF",
            filename: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
            sizeGB: 2.2,
            ramRequiredGB: 2.9,
            description: "Microsoft Phi — top quality at this size",
            tags: ["phi", "instruct", "gguf"],
            quantization: "Q4_K_M"
        ),
    ]

    // MARK: - Load & API

    func loadInitialModels() async {
        models = Self.curatedModels
        await fetchTrendingModels()
    }

    func fetchTrendingModels() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = buildAPIURL(search: nil) else {
            errorMessage = "Invalid API URL"
            return
        }

        do {
            let parsed = try await cachedFetchAndParse(url: url)
            // Merge: curated first (stable order), then API models (deduplicated)
            let curatedIds = Set(Self.curatedModels.map { $0.id })
            let apiModels = parsed.filter { !curatedIds.contains($0.id) }
            models = Self.curatedModels + apiModels
        } catch is CancellationError {
            // Task cancelled — no error to show
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
        }
    }

    func searchHuggingFace(query: String) async {
        // Cancel any in-flight search
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadInitialModels()
            return
        }

        let task = Task { @MainActor in
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }

            guard let url = buildAPIURL(search: query) else { return }

            do {
                try Task.checkCancellation()
                let parsed = try await cachedFetchAndParse(url: url)
                try Task.checkCancellation()
                models = parsed
            } catch is CancellationError {
                // Cancelled by newer search — ignore
            } catch {
                errorMessage = "Search failed: \(error.localizedDescription)"
            }
        }
        searchTask = task
        await task.value
    }

    // MARK: - Private API helpers

    private func buildAPIURL(search: String?) -> URL? {
        var components = URLComponents(string: apiBaseURL)
        var queryItems = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "likes"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "full", value: "true"),
        ]
        if let search, !search.isEmpty {
            queryItems.insert(URLQueryItem(name: "search", value: search), at: 0)
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func fetchAndParse(url: URL) async throws -> [LLMModel] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let hfModels = try JSONDecoder().decode([HFModelResponse].self, from: data)
        return parseHFResponses(hfModels)
    }

    /// Returns cached results if available, otherwise fetches and caches.
    private func cachedFetchAndParse(url: URL) async throws -> [LLMModel] {
        let key = url.absoluteString
        if let cached = responseCache[key] {
            return cached
        }
        let result = try await fetchAndParse(url: url)
        // Evict oldest entries when cache is full
        if responseCache.count >= cacheLimit {
            responseCache.removeAll()
        }
        responseCache[key] = result
        return result
    }

    private func parseHFResponses(_ responses: [HFModelResponse]) -> [LLMModel] {
        var result: [LLMModel] = []

        for response in responses {
            guard let siblings = response.siblings else { continue }

            let ggufFiles = siblings.filter { $0.rfilename.hasSuffix(".gguf") }

            for file in ggufFiles {
                guard let fileSize = file.effectiveSize, fileSize > 0 else { continue }
                let sizeGB = Double(fileSize) / (1024.0 * 1024.0 * 1024.0)

                // iPhone safety: skip files > 3.5 GB
                guard sizeGB > 0 && sizeGB <= maxSizeGB else { continue }

                let quantization = Self.extractQuantization(from: file.rfilename)
                let displayName = Self.buildDisplayName(repoId: response.id, filename: file.rfilename, quant: quantization)

                let model = LLMModel(
                    id: "\(response.id)/\(file.rfilename)",
                    name: displayName,
                    repoId: response.id,
                    filename: file.rfilename,
                    sizeGB: (sizeGB * 100).rounded() / 100,
                    ramRequiredGB: (sizeGB * 1.3 * 100).rounded() / 100,
                    description: "By \(response.author ?? "unknown") · \(response.likes ?? 0) ❤️",
                    tags: response.tags ?? [],
                    quantization: quantization
                )
                result.append(model)
            }
        }

        return result
    }

    // MARK: - Parsing helpers

    static func extractQuantization(from filename: String) -> String {
        // Match patterns: IQ4_XS, Q4_K_M, Q8_0, Q5_K_S, F16, F32, etc.
        let patterns = [
            "IQ[0-9]_[A-Z]+",        // IQ4_XS
            "Q[0-9]+_K_[A-Z]+",      // Q4_K_M, Q5_K_S
            "Q[0-9]+_[0-9]+",        // Q8_0
            "Q[0-9]+_K",             // Q4_K
            "F[0-9]+",               // F16, F32
        ]
        let combined = patterns.joined(separator: "|")
        if let range = filename.range(of: combined, options: .regularExpression) {
            return String(filename[range])
        }
        return "Unknown"
    }

    static func buildDisplayName(repoId: String, filename: String, quant: String) -> String {
        let repoName = repoId.components(separatedBy: "/").last ?? repoId
        let cleaned = repoName
            .replacingOccurrences(of: "-GGUF", with: "")
            .replacingOccurrences(of: "-gguf", with: "")
            .replacingOccurrences(of: "_GGUF", with: "")
            .replacingOccurrences(of: "-", with: " ")
        return "\(cleaned) \(quant)"
    }

    // MARK: - Downloaded model state

    func downloadedModelFilenames() -> Set<String> {
        let modelsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return Set(files.map { $0.lastPathComponent }.filter { $0.hasSuffix(".gguf") })
    }

    func isDownloaded(_ model: LLMModel) -> Bool {
        downloadedModelFilenames().contains(model.filename)
    }
}
