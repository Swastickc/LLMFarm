//
//  HFModelPickerView.swift
//  LLMFarm
//
//  HuggingFace model browser — search, filter, download GGUF models.
//  This is the main "Hub" screen users see.
//

import SwiftUI

struct HFModelPickerView: View {

    @StateObject private var store = HFModelStore()
    @ObservedObject private var downloadManager = HFDownloadManager.shared

    @State private var searchTask: Task<Void, Never>?
    @State private var showLibrary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                modelList
            }
            .navigationTitle("Model Hub")
            .searchable(text: $store.searchText, prompt: "Search HuggingFace models…")
            .onChange(of: store.searchText) { newValue in
                // Debounced live search
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000) // 400ms
                    guard !Task.isCancelled else { return }
                    await store.searchHuggingFace(query: newValue)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showLibrary = true
                    } label: {
                        Label("My Models", systemImage: "internaldrive")
                    }
                }
            }
            .sheet(isPresented: $showLibrary) {
                ModelLibraryView()
            }
            .task {
                await store.loadInitialModels()
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ModelFilter.allCases) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isSelected: store.activeFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.activeFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Model List

    private var modelList: some View {
        Group {
            if store.isLoading && store.filteredModels.isEmpty {
                loadingView
            } else if let error = store.errorMessage, store.filteredModels.isEmpty {
                errorView(error)
            } else if store.filteredModels.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(store.filteredModels) { model in
                        ModelCardView(
                            model: model,
                            downloadManager: downloadManager,
                            store: store
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await store.fetchTrendingModels()
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading models…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await store.fetchTrendingModels() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No models match your search")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model Card

struct ModelCardView: View {

    let model: LLMModel
    @ObservedObject var downloadManager: HFDownloadManager
    @ObservedObject var store: HFModelStore

    @State private var showDeleteConfirmation = false
    @State private var showChatSettings = false

    private var downloadState: DownloadState {
        // Check disk first for models downloaded in prior sessions
        if downloadManager.isModelDownloaded(filename: model.filename) {
            return .completed
        }
        return downloadManager.downloadState(for: model.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: name + tier badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(model.repoId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(model.tier.badge)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tierColor.opacity(0.15))
                    .foregroundStyle(tierColor)
                    .clipShape(Capsule())
            }

            // Description
            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Info row: size, RAM, quantization
            HStack(spacing: 12) {
                Label(model.sizeLabel, systemImage: "arrow.down.circle")
                Label(String(format: "%.1f GB RAM", model.ramRequiredGB), systemImage: "memorychip")
                Label(model.quantization, systemImage: "cube")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Tags
            if !model.tags.isEmpty {
                tagRow
            }

            // Action area: download / progress / load
            actionArea
        }
        .padding(.vertical, 4)
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                _ = downloadManager.deleteModel(model: model)
            }
        } message: {
            Text("This will remove \(model.filename) (\(downloadManager.modelDiskUsage(filename: model.filename))) from your device.")
        }
    }

    // MARK: - Sub-views

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tags.prefix(5), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch downloadState {
        case .idle:
            Button {
                downloadManager.startDownload(model: model)
            } label: {
                Label("Download \(model.sizeLabel)", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)

        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .tint(.blue)
                HStack {
                    if let info = downloadManager.downloads[model.id] {
                        Text(info.progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) {
                        downloadManager.cancelDownload(modelId: model.id)
                    }
                    .font(.caption2)
                }
            }

        case .completed:
            HStack(spacing: 12) {
                Button {
                    showChatSettings = true
                } label: {
                    Label("Load & Chat", systemImage: "bubble.left.and.text.bubble.right")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Spacer()

                Text(downloadManager.modelDiskUsage(filename: model.filename))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .sheet(isPresented: $showChatSettings) {
                LoadAndChatSheet(modelFilename: model.filename)
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") {
                    downloadManager.startDownload(model: model)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        }
    }

    // MARK: - Tier color

    private var tierColor: Color {
        switch model.tier {
        case .ultraLight: return .green
        case .light: return .orange
        case .medium: return .red
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Load & Chat Sheet

/// Wraps ChatSettingsView with the downloaded model pre-filled.
/// Uses local state bindings so it can be presented as a standalone sheet.
struct LoadAndChatSheet: View {
    let modelFilename: String

    @State private var addChatDialog = true
    @State private var editChatDialog = false
    @State private var toggleSettings = false
    @State private var afterChatEdit: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatSettingsView(
                add_chat_dialog: $addChatDialog,
                edit_chat_dialog: $editChatDialog,
                after_chat_edit: $afterChatEdit,
                toggleSettings: $toggleSettings,
                prefilledModelPath: modelFilename
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onChange(of: addChatDialog) { newValue in
            if !newValue { dismiss() }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct HFModelPickerView_Previews: PreviewProvider {
    static var previews: some View {
        HFModelPickerView()
    }
}
#endif
