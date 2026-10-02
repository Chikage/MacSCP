import SwiftUI
import MacSCPCore

struct TransferQueueView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("传输队列", systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                Text("\(model.transfers.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if model.hasActiveTransfers { Text("按顺序传输").font(.caption).foregroundStyle(.secondary) }
                Button("清除已结束") { model.clearCompleted() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(!model.transfers.contains { $0.state != .waiting && $0.state != .running })
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if model.transfers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("每一次传输，都井然有序").font(.callout)
                        Text("选择文件后点击上传或下载，可在这里查看进度。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.transfers) { item in
                            TransferRow(item: item, canRetry: model.connectedSite == item.site,
                                        cancel: { model.cancelTransfer(item) }, retry: { model.retryTransfer(item) })
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let canRetry: Bool
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.request.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title2).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.request.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(item.state.rawValue).font(.caption).foregroundStyle(item.state == .failed ? Color.red : Color.primary)
                }
                if item.state == .running {
                    ProgressView(value: item.progress.fraction).tint(.accentColor)
                    HStack {
                        Text(item.progress.currentFile).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(bytes(item.progress.bytes)) / \(bytes(item.progress.totalBytes))").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(item.error ?? (item.state == .completed
                         ? "\(item.progress.completedFiles) 个文件 · \(bytes(item.progress.totalBytes))" + (item.progress.skipped > 0 ? " · 跳过 \(item.progress.skipped) 项" : "")
                         : item.request.destination))
                        .font(.caption).foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                        .lineLimit(1).help(item.error ?? item.request.destination)
                }
            }
            if item.state == .running || item.state == .waiting {
                Button(action: cancel) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("取消传输").accessibilityLabel("取消 \(item.request.title)")
            } else if item.state == .failed || item.state == .cancelled {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(!canRetry).help("重试").accessibilityLabel("重试 \(item.request.title)")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("传输完成")
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

#Preview { TransferQueueView(model: AppModel()).frame(width: 950, height: 190) }
