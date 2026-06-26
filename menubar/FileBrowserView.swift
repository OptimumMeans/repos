import SwiftUI
import AppKit

struct FileEntry: Identifiable {
    let url: URL
    var id: String { url.path }
    let name: String
    let isDir: Bool
    let size: Int?
}

func listDir(_ url: URL) -> [FileEntry] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
    return items.map { u -> FileEntry in
        let v = try? u.resourceValues(forKeys: keys)
        let isDir = v?.isDirectory ?? false
        return FileEntry(url: u, name: u.lastPathComponent, isDir: isDir, size: isDir ? nil : v?.fileSize)
    }.sorted { a, b in
        a.isDir == b.isDir ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : a.isDir
    }
}

struct FileBrowserView: View {
    @EnvironmentObject var model: ReposModel
    let path: URL

    var body: some View {
        let entries = listDir(path)
        ScrollView {
            LazyVStack(spacing: 0) {
                if entries.isEmpty {
                    Text("Empty folder").foregroundStyle(.secondary)
                        .padding(28).frame(maxWidth: .infinity)
                } else {
                    ForEach(entries) { entry in
                        FileRow(entry: entry)
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .frame(maxHeight: 420)
    }
}

struct FileRow: View {
    @EnvironmentObject var model: ReposModel
    let entry: FileEntry

    var body: some View {
        Button {
            if entry.isDir { model.descend(into: entry.url) }
            else { NSWorkspace.shared.open(entry.url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let size = entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption).foregroundStyle(.tertiary)
                } else if entry.isDir {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
