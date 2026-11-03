import SwiftUI
import AppKit

/// Settings subview for managing user-selected local Git repositories to monitor for commit activity (`FR-012`).
public struct GitReposPickerView: View {
    @ObservedObject public var settingsStore: PersonalitySettingsStore

    public init(settingsStore: PersonalitySettingsStore) {
        self.settingsStore = settingsStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watched Repositories")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    openDirectoryPicker()
                } label: {
                    Label("Add Repository...", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if settingsStore.watchedRepoPaths.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No repositories configured.")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("Bitz will not query local git commits or spawn background processes.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .separatorColor).opacity(0.1))
                .cornerRadius(8)
            } else {
                VStack(spacing: 6) {
                    ForEach(settingsStore.watchedRepoPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folderName(for: path))
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                settingsStore.removeWatchedRepoPath(path)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop monitoring this repository")
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private func folderName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Select"
        panel.message = "Select local Git repositories for Bitz to monitor"

        if panel.runModal() == .OK {
            for url in panel.urls {
                settingsStore.addWatchedRepoPath(url.path)
            }
        }
    }
}
