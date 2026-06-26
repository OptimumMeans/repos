import SwiftUI

struct PanelView: View {
    @EnvironmentObject var model: ReposModel

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .task { if model.repos.isEmpty { await model.reload() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            Text("Repos").font(.headline)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search repos", text: $model.search).textFieldStyle(.plain)
        }
        .padding(7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if model.repos.isEmpty {
            if model.loading {
                ProgressView("Loading…").padding(28).frame(maxWidth: .infinity)
            } else if let err = model.error {
                centeredError(err)
            } else {
                Text("No repos found").foregroundStyle(.secondary).padding(28).frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if let err = model.error { errorBanner(err) }
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        section("On this Mac", model.onDiskFiltered)
                        section("Cloud only", model.cloudFiltered)
                    }
                }
                .frame(maxHeight: 400)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ repos: [Repo]) -> some View {
        if !repos.isEmpty {
            Section {
                ForEach(repos) { repo in
                    RepoRow(repo: repo)
                    Divider().padding(.leading, 34)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(repos.count)").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(.bar)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("\(model.onDiskCount) on this Mac")
            Text("·").foregroundStyle(.tertiary)
            Text("\(model.onDiskMB) MB")
            Spacer()
            Text("\(model.repos.count) total").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(err).font(.caption).lineLimit(2)
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    private func centeredError(_ err: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.title2)
            Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
    }
}

struct RepoRow: View {
    let repo: Repo
    @EnvironmentObject var model: ReposModel

    // Always read the model's live entry, never the snapshot captured at render
    // time — that's what kept the toggle out of sync after a clone.
    private var current: Repo { model.repos.first { $0.id == repo.id } ?? repo }

    var body: some View {
        let r = current
        HStack(spacing: 10) {
            Circle()
                .fill(r.onDisk ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.body)
                Text(r.onDisk ? "On this Mac · \(r.sizeMB) MB" : "Cloud only · \(r.sizeMB) MB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing(r)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func trailing(_ r: Repo) -> some View {
        if let pct = model.progress[r.name] {
            HStack(spacing: 6) {
                Text("\(Int(pct * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: pct).frame(width: 52)
            }
        } else if model.busy.contains(r.name) {
            ProgressView().controlSize(.small)
        } else {
            Toggle("", isOn: Binding(get: { r.onDisk },
                                     set: { _ in Task { await model.toggle(r) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}
