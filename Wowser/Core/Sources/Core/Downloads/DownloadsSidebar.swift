import SwiftUI

public struct DownloadsSidebar: View {
    let windowID: ID<WindowState>
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            DownloadsSnapshot(
                windowID: windowID,
                downloads: state.windows[windowID]?.downloads ?? [:]
            )
        } main: { snapshot in
            DownloadsSidebarContent(
                snapshot: snapshot,
                windowID: windowID
            )
        }
    }
}

private struct DownloadsSnapshot: Equatable {
    let windowID: ID<WindowState>
    let downloads: [ID<Download>: Download]
}

private struct DownloadsSidebarContent: View {
    let snapshot: DownloadsSnapshot
    let windowID: ID<WindowState>
    
    var body: some View {
        if snapshot.downloads.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Downloads")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(spacing: 4) {
                    ForEach(downloadsArray) { download in
                        DownloadRow(
                            download: download,
                            windowID: windowID
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
    
    private var downloadsArray: [Download] {
        snapshot.downloads.values
            .sorted { $0.startDate > $1.startDate }
    }
}

private struct DownloadRow: View {
    let download: Download
    let windowID: ID<WindowState>
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon
            downloadIcon
                .foregroundStyle(iconColor)
                .font(.system(size: 16))
                .frame(width: 24)
            
            // Filename and progress
            VStack(alignment: .leading, spacing: 2) {
                Text(download.suggestedFilename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if download.status == .inProgress {
                    ProgressView(value: download.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 4)
                } else if download.status == .failed, let error = download.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if download.status == .completed {
                    // Show file size if available
                    Text(fileSizeString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                        
            // Close/remove button
            Button {
                removeDownload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(6)
            }
            .buttonStyle(CircleButtonStyle())
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.1 : 0.05))
        )
        .contextMenu {
            downloadContextMenu
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if download.status == .completed {
                openDownload()
            }
        }
    }
    
    @ViewBuilder
    private var downloadIcon: some View {
        switch download.status {
        case .inProgress:
            Image(systemName: "arrow.down.circle")
        case .completed:
            Image(systemName: "doc")
        case .failed:
            Image(systemName: "exclamationmark.circle")
        case .cancelled:
            Image(systemName: "xmark.circle")
        }
    }
    
    private var iconColor: Color {
        switch download.status {
        case .inProgress:
            return .blue
        case .completed:
            return .primary
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
    
    private var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: download.currentSize)
    }
    
    @ViewBuilder
    private var downloadContextMenu: some View {
        if download.status == .completed {
            Button("Open") {
                openDownload()
            }
            
            Button("Show in Finder") {
                showInFinder()
            }
            
            Divider()
            
            Button("Remove from List") {
                removeDownload()
            }
            
            Button("Delete File") {
                deleteDownload()
            }
        } else if download.status == .inProgress {
            Button("Cancel Download") {
                cancelDownload()
            }
            
            Button("Remove from List") {
                cancelDownload()
                removeDownload()
            }
        } else {
            Button("Remove from List") {
                removeDownload()
            }
        }
    }
    
    private func openDownload() {
        DownloadManager.shared.openDownloadedFile(id: download.id, windowID: windowID)
    }
    
    private func showInFinder() {
        #if os(macOS)
        NSWorkspace.shared.selectFile(download.destinationURL.path, inFileViewerRootedAtPath: "")
        #endif
    }
    
    private func removeDownload() {
        DownloadManager.shared.removeDownload(id: download.id, windowID: windowID)
    }
    
    private func cancelDownload() {
        DownloadManager.shared.cancelDownload(id: download.id, windowID: windowID)
    }
    
    private func deleteDownload() {
        DownloadManager.shared.deleteDownloadedFile(id: download.id, windowID: windowID)
    }
}
