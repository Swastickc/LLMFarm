//
//  ModelLibraryView.swift
//  LLMFarm
//
//  Shows downloaded GGUF models — disk usage, delete, load actions.
//  Presented as a sheet from HFModelPickerView or directly.
//

import SwiftUI

struct ModelLibraryView: View {

    @ObservedObject private var downloadManager = HFDownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var downloadedFiles: [DownloadedModelFile] = []
    @State private var deleteTarget: DownloadedModelFile?
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if downloadedFiles.isEmpty {
                    emptyState
                } else {
                    List {
                        diskUsageHeader
                        ForEach(downloadedFiles) { file in
                            DownloadedModelRow(file: file) {
                                deleteTarget = file
                                showDeleteAlert = true
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("My Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { refreshList() }
            .alert("Delete Model?", isPresented: $showDeleteAlert, presenting: deleteTarget) { file in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteFile(file)
                }
            } message: { file in
                Text("Remove \(file.filename) (\(file.sizeLabel)) from this device? This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var diskUsageHeader: some View {
        Section {
            HStack {
                Label("Total disk usage", systemImage: "externaldrive")
                Spacer()
                Text(downloadManager.totalDiskUsage())
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)
            }
            HStack {
                Label("Models downloaded", systemImage: "square.stack.3d.up")
                Spacer()
                Text("\(downloadedFiles.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No models downloaded yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Browse the Hub to find models for your device.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func refreshList() {
        let filenames = downloadManager.allDownloadedFilenames()
        downloadedFiles = filenames.map { filename in
            let bytes = downloadManager.modelFileSize(filename: filename) ?? 0
            let quant = HFModelStore.extractQuantization(from: filename)
            return DownloadedModelFile(
                filename: filename,
                sizeBytes: bytes,
                quantization: quant
            )
        }
        .sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    private func deleteFile(_ file: DownloadedModelFile) {
        let path = downloadManager.modelsDirectory.appendingPathComponent(file.filename)
        try? FileManager.default.removeItem(at: path)
        refreshList()
    }
}

// MARK: - Data model for a downloaded file on disk

struct DownloadedModelFile: Identifiable {
    var id: String { filename }
    let filename: String
    let sizeBytes: UInt64
    let quantization: String

    var sizeLabel: String {
        let gb = Double(sizeBytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.0f MB", gb * 1024)
    }

    var tier: ModelTier {
        let gb = Double(sizeBytes) / (1024 * 1024 * 1024)
        if gb < 1.0 { return .ultraLight }
        else if gb < 2.0 { return .light }
        else { return .medium }
    }
}

// MARK: - Row view for a downloaded model

struct DownloadedModelRow: View {
    let file: DownloadedModelFile
    let onDelete: () -> Void

    @State private var showChatSettings = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.filename)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(file.tier.badge)
                        .font(.caption2)
                    Text(file.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if file.quantization != "Unknown" {
                        Text(file.quantization)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Load & Chat
            Button {
                showChatSettings = true
            } label: {
                Label("Load", systemImage: "message")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)

            // Delete button
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showChatSettings) {
            LoadAndChatSheet(modelFilename: file.filename)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ModelLibraryView_Previews: PreviewProvider {
    static var previews: some View {
        ModelLibraryView()
    }
}
#endif
