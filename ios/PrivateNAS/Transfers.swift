import SwiftUI

private struct TransferPart: Codable {
    let path: [String]
    let directory: Bool
    let size: Int64
    let modified: Double
    var uploadID = UUID()
}

struct TransferJob: Codable, Identifiable {
    enum Direction: String, Codable { case upload, download }
    enum State: String, Codable { case waiting, running, paused, failed, complete }
    let id: UUID
    let name: String
    let direction: Direction
    let scope: String
    let remote: [String]
    fileprivate let parts: [TransferPart]
    fileprivate let bookmark: Data?
    fileprivate var index = 0
    fileprivate var offset: Int64 = 0
    var state: State = .waiting
    var message: String?

    var total: Int64 { parts.reduce(0) { $0 + $1.size } }
    var transferred: Int64 { parts.prefix(index).reduce(offset) { $0 + $1.size } }
    var progress: Double {
        if total == 0 { return state == .complete ? 1 : 0 }
        return min(1, Double(transferred) / Double(total))
    }
}

@MainActor
final class TransferCenter: ObservableObject {
    @Published private(set) var jobs: [TransferJob] = []
    @Published private(set) var bytesPerSecond: Int64 = 0
    private let directory: URL
    private var worker: Task<Void, Never>?
    private var running: UUID?
    private var removing = Set<UUID>()
    private static let chunkSize = 1024 * 1024

    init() {
        directory = URL.applicationSupportDirectory.appendingPathComponent("PrivateNASTransfers", isDirectory: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("jobs.json")),
           let previous = try? JSONDecoder().decode([TransferJob].self, from: data) {
            jobs = previous.map {
                var job = $0
                if job.state == .running || job.state == .waiting { job.state = .paused }
                return job
            }
        }
    }

    func enqueueUpload(_ source: URL, to destination: [String], drive: Drive, importPhoto: Bool = false) async throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let scope = try await drive.transferScope()
        let id = UUID()
        let bookmark: Data?
        let inspectionURL: URL
        do {
            if importPhoto {
                let staged = workFolder(id)
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                let target = staged.appendingPathComponent(source.lastPathComponent)
                try await Task.detached { try FileManager.default.copyItem(at: source, to: target) }.value
                inspectionURL = target
                bookmark = nil
            } else {
                bookmark = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                inspectionURL = source
            }
            let parts = try await Task.detached { try Self.localParts(inspectionURL, path: []) }.value
            let job = TransferJob(id: id, name: source.lastPathComponent, direction: .upload, scope: scope,
                                  remote: destination + [source.lastPathComponent], parts: parts, bookmark: bookmark)
            try enqueue(job, drive: drive)
        } catch {
            if importPhoto { try? FileManager.default.removeItem(at: workFolder(id)) }
            throw error
        }
    }

    func enqueueDownload(_ entry: Entry, at path: [String], into folder: URL, drive: Drive) async throws {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let scope = try await drive.transferScope()
        let remote = path + [entry.name]
        let parts = try await remoteParts(entry, remote: remote, relative: [], drive: drive)
        let job = TransferJob(id: UUID(), name: entry.name, direction: .download, scope: scope,
                              remote: remote, parts: parts, bookmark: bookmark)
        try enqueue(job, drive: drive)
    }

    func pause(_ id: UUID) {
        guard let position = jobs.firstIndex(where: { $0.id == id }) else { return }
        if running == id { worker?.cancel() }
        else if jobs[position].state == .waiting {
            jobs[position].state = .paused
            try? save()
        }
    }

    func resume(_ id: UUID, drive: Drive) {
        guard running != id, !removing.contains(id), let position = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[position].state = .waiting
        jobs[position].message = nil
        try? save()
        runNext(drive)
    }

    func clearCompleted() {
        for job in jobs where job.state == .complete { try? FileManager.default.removeItem(at: workFolder(job.id)) }
        jobs.removeAll { $0.state == .complete }
        try? save()
    }

    func remove(_ job: TransferJob, drive: Drive) async throws {
        guard running != job.id, !removing.contains(job.id),
              let job = jobs.first(where: { $0.id == job.id }), job.state != .waiting else { return }
        removing.insert(job.id)
        defer { removing.remove(job.id) }
        if job.direction == .upload && job.state != .complete && job.index < job.parts.count {
            guard try await drive.transferScope() == job.scope else {
                throw APIError(message: "请连接原服务器和原网盘目录后移除")
            }
            let part = job.parts[job.index]
            if !part.directory {
                do {
                    _ = try await drive.transferData("DELETE", "upload-chunk", path: job.remote + part.path,
                                                     values: uploadValues(part))
                } catch let error as APIError where error.status == 404 { }
            }
        }
        let folder = workFolder(job.id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        jobs.removeAll { $0.id == job.id }
        try save()
    }

    private func enqueue(_ job: TransferJob, drive: Drive) throws {
        jobs.insert(job, at: 0)
        do { try save() }
        catch {
            jobs.removeAll { $0.id == job.id }
            try? FileManager.default.removeItem(at: workFolder(job.id))
            throw error
        }
        runNext(drive)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("jobs.json"), options: .atomic)
    }

    private func update(_ job: TransferJob) throws {
        if let position = jobs.firstIndex(where: { $0.id == job.id }) { jobs[position] = job }
        try save()
    }

    private func workFolder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func runNext(_ drive: Drive) {
        guard worker == nil, let initial = jobs.last(where: { $0.state == .waiting }) else { return }
        running = initial.id
        worker = Task {
            var job = initial
            job.state = .running
            do {
                try update(job)
                guard try await drive.transferScope() == job.scope else {
                    throw APIError(message: "请连接原服务器和原网盘目录后继续")
                }
                try await transfer(&job, drive: drive)
                job.state = .complete
                try update(job)
                try? FileManager.default.removeItem(at: workFolder(job.id))
            } catch {
                let paused = Task.isCancelled || (error as? URLError)?.code == .cancelled
                job.state = paused ? .paused : .failed
                job.message = paused ? nil : error.localizedDescription
                try? update(job)
            }
            bytesPerSecond = 0
            running = nil
            worker = nil
            runNext(drive)
        }
    }

    private nonisolated static func localParts(_ url: URL, path: [String]) throws -> [TransferPart] {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                      .fileSizeKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw APIError(message: "无法上传符号链接或特殊文件")
        }
        let directory = values.isDirectory == true
        let updated = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let item = TransferPart(path: path, directory: directory, size: directory ? 0 : Int64(values.fileSize ?? 0),
                                modified: updated)
        guard directory else { return [item] }
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        return [item] + (try children.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { child in
            try localParts(child, path: path + [child.lastPathComponent])
        })
    }

    private func remoteParts(_ entry: Entry, remote: [String], relative: [String], drive: Drive) async throws -> [TransferPart] {
        if !entry.directory && entry.modified == nil { throw APIError(message: "服务器没有提供文件版本，请更新服务端") }
        var parts = [TransferPart(path: relative, directory: entry.directory, size: entry.directory ? 0 : entry.size,
                                  modified: entry.modified ?? 0)]
        if entry.directory {
            for child in try await drive.list(remote) {
                parts += try await remoteParts(child, remote: remote + [child.name],
                                               relative: relative + [child.name], drive: drive)
            }
        }
        return parts
    }

    private func transfer(_ job: inout TransferJob, drive: Drive) async throws {
        guard let token = drive.token else { throw APIError(message: "请重新登录后继续传输") }
        let local: URL
        if let bookmark = job.bookmark {
            var stale = false
            local = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { throw APIError(message: "文件访问授权已失效，请重新选择文件或目录") }
        } else {
            local = workFolder(job.id).appendingPathComponent(job.name)
        }
        let accessed = local.startAccessingSecurityScopedResource()
        defer { if accessed { local.stopAccessingSecurityScopedResource() } }
        while job.index < job.parts.count {
            try Task.checkCancellation()
            guard drive.token == token else { throw APIError(message: "登录已变更，请重新连接后续传") }
            let part = job.parts[job.index]
            let remote = job.remote + part.path
            let base = job.direction == .upload ? local : local.appendingPathComponent(job.name)
            let target = part.path.reduce(base) { $0.appendingPathComponent($1) }
            if part.directory {
                if job.direction == .upload {
                    let siblings = try await drive.list(Array(remote.dropLast()))
                    if let existing = siblings.first(where: { $0.name.caseInsensitiveCompare(remote.last ?? "") == .orderedSame }) {
                        guard existing.directory else { throw APIError(message: "目标位置已有同名文件") }
                    } else { try await drive.create(remote) }
                } else {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                        let info = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
                        guard isDirectory.boolValue, info.isSymbolicLink != true else {
                            throw APIError(message: "保存位置已有同名项目")
                        }
                    } else {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    }
                }
            } else if job.direction == .upload {
                try await upload(&job, part: part, local: target, remote: remote, drive: drive, token: token)
            } else {
                try await download(&job, part: part, local: target, remote: remote, drive: drive, token: token)
            }
            job.index += 1
            job.offset = 0
            try update(job)
            if !part.directory && job.direction == .upload && drive.token == token {
                _ = try? await drive.transferData("DELETE", "upload-chunk", path: remote,
                                                   values: uploadValues(part))
            }
        }
    }

    private func uploadValues(_ part: TransferPart) -> [String: String] {
        ["id": part.uploadID.uuidString, "size": String(part.size)]
    }

    private func upload(_ job: inout TransferJob, part: TransferPart, local: URL, remote: [String],
                        drive: Drive, token: String) async throws {
        struct Status: Decodable { let offset: Int64; let finished: Bool }
        let values = uploadValues(part)
        let current = try JSONDecoder().decode(Status.self, from: await drive.transferData(
            "GET", "upload-chunk", path: remote, values: values))
        guard (0...part.size).contains(current.offset) else { throw APIError(message: "服务器续传位置无效") }
        job.offset = current.offset
        if current.finished { return }
        let metadata = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard metadata.fileSize.map({ Int64($0) }) == part.size,
              abs((metadata.contentModificationDate?.timeIntervalSince1970 ?? 0) - part.modified) < 0.001 else {
            throw APIError(message: "本地文件已变更，请重新添加上传任务")
        }
        let file = try FileHandle(forReadingFrom: local)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(job.offset))
        while job.offset < part.size {
            try Task.checkCancellation()
            guard drive.token == token else { throw APIError(message: "登录已变更，请重新连接后续传") }
            let count = Int(min(Int64(Self.chunkSize), part.size - job.offset))
            guard let bytes = try file.read(upToCount: count), !bytes.isEmpty else {
                throw APIError(message: "本地文件读取不完整")
            }
            let began = ContinuousClock.now
            var query = values
            query["offset"] = String(job.offset)
            let reply = try JSONDecoder().decode(Status.self, from: await drive.transferData(
                "PUT", "upload-chunk", path: remote, values: query, body: bytes))
            guard reply.offset == job.offset + Int64(bytes.count) else { throw APIError(message: "服务器确认的进度无效") }
            job.offset = reply.offset
            try record(job, bytes: bytes.count, began: began)
        }
        try Task.checkCancellation()
        guard drive.token == token else { throw APIError(message: "登录已变更，请重新连接后续传") }
        _ = try await drive.transferData("POST", "upload-chunk", path: remote, values: values)
    }

    private func download(_ job: inout TransferJob, part: TransferPart, local: URL, remote: [String],
                          drive: Drive, token: String) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: local.path) { throw APIError(message: "保存位置已有同名文件") }
        let folder = workFolder(job.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("\(job.index).part")
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw APIError(message: "无法建立下载缓存") }
        }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        job.offset = Int64(try file.seekToEnd())
        guard job.offset <= part.size else { throw APIError(message: "下载缓存大小异常") }
        let values = ["size": String(part.size), "modified": String(part.modified)]
        repeat {
            try Task.checkCancellation()
            guard drive.token == token else { throw APIError(message: "登录已变更，请重新连接后续传") }
            var query = values
            query["offset"] = String(job.offset)
            let began = ContinuousClock.now
            let bytes = try await drive.transferData("GET", "download-chunk", path: remote, values: query)
            guard Int64(bytes.count) <= part.size - job.offset,
                  !bytes.isEmpty || job.offset == part.size else { throw APIError(message: "服务器返回的数据不完整") }
            try file.write(contentsOf: bytes)
            job.offset += Int64(bytes.count)
            try record(job, bytes: bytes.count, began: began)
        } while job.offset < part.size
        try Task.checkCancellation()
        try file.synchronize()
        try fm.copyItem(at: partial, to: local)
    }

    private func record(_ job: TransferJob, bytes: Int, began: ContinuousClock.Instant) throws {
        let duration = (ContinuousClock.now - began).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let rate = Int64(Double(bytes) / max(0.05, seconds))
        bytesPerSecond = bytesPerSecond == 0 ? rate : (bytesPerSecond + rate) / 2
        try update(job)
    }
}

struct TransferPanel: View {
    @ObservedObject var transfers: TransferCenter
    let drive: Drive
    @Environment(\.dismiss) private var dismiss
    @State private var direction: TransferJob.Direction
    @State private var pendingRemoval: TransferJob?
    @State private var error: String?

    init(transfers: TransferCenter, drive: Drive, direction: TransferJob.Direction) {
        self.transfers = transfers
        self.drive = drive
        _direction = State(initialValue: direction)
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("传输方向", selection: $direction) {
                    Text("上传").tag(TransferJob.Direction.upload)
                    Text("下载").tag(TransferJob.Direction.download)
                }
                .pickerStyle(.segmented)
                ForEach(transfers.jobs.filter { $0.direction == direction }) { job in
                    row(job)
                        .swipeActions(allowsFullSwipe: false) {
                            if job.state != .running && job.state != .waiting {
                                Button("移除", role: .destructive) { pendingRemoval = job }
                            }
                        }
                }
                if !transfers.jobs.contains(where: { $0.direction == direction }) {
                    ContentUnavailableView("暂无传输任务", systemImage: "arrow.up.arrow.down")
                }
            }
            .navigationTitle("传输")
            .confirmationDialog("移除传输任务？",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval) { job in
                    Button("移除任务", role: .destructive) {
                        Task {
                            do { try await transfers.remove(job, drive: drive) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } message: { _ in Text("会清理续传缓存，已完成的文件会保留。") }
            .alert("移除失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("清除已完成", action: transfers.clearCompleted)
                        .disabled(!transfers.jobs.contains { $0.state == .complete })
                }
            }
        }
    }

    private func row(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.name).font(.headline)
            ProgressView(value: job.progress)
            HStack {
                Text("\(format(job.transferred)) / \(format(job.total))")
                Spacer()
                switch job.state {
                case .waiting: Text("排队中"); Button("暂停") { transfers.pause(job.id) }
                case .running:
                    Text("\(format(transfers.bytesPerSecond))/秒")
                    Button("暂停") { transfers.pause(job.id) }
                case .paused, .failed: Button("继续") { transfers.resume(job.id, drive: drive) }
                case .complete: Text("已完成")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if let message = job.message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
