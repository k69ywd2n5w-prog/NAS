import CryptoKit
import CoreTransferable
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct Entry: Decodable, Identifiable {
    let name: String
    let directory: Bool
    let size: Int64
    let modified: Double?
    var id: String { name }
    private var fileType: UTType? { UTType(filenameExtension: (name as NSString).pathExtension) }

    var icon: String {
        if directory { return "folder.fill" }
        guard let type = fileType else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        return "doc"
    }

    var canLoadThumbnail: Bool {
        guard !directory, size > 0, size <= 12 * 1024 * 1024, let type = fileType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) ||
            type.conforms(to: .movie) || type.conforms(to: .text) ||
            ["docx", "xlsx", "pptx", "pages", "numbers", "key"].contains(
                (name as NSString).pathExtension.lowercased())
    }
}

private struct ClipboardItem {
    let path: [String]
    let move: Bool
    var name: String { path[path.count - 1] }
}

private struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct PhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try copy($0.file) }
        FileRepresentation(importedContentType: .movie) { try copy($0.file) }
    }

    private static func copy(_ source: URL) throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the extension supplied by Photos and give each imported file a unique name.
        let prefix = String(folder.lastPathComponent.prefix(8))
        let file = folder.appendingPathComponent(prefix + "-" + source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: file)
            return Self(url: file)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

private final class ServerTrust: NSObject, URLSessionTaskDelegate, Sendable {
    let fingerprint: String

    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              !fingerprint.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // The fingerprint is copied from the owner's Windows console through a trusted channel.
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map({ String(format: "%02x", $0) }).joined() == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private final class Drive: ObservableObject {
    @Published var token: String?
    @Published var clipboard: ClipboardItem?
    private var base: URL?
    private var session: URLSession?
    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    func login(address: String, fingerprint: String, username: String, password: String) async throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw APIError(message: "请输入 HTTPS 服务器地址，例如 https://nas.example.com:8787")
        }
        let pin = fingerprint.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        guard pin.isEmpty || pin.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw APIError(message: "证书指纹应为 64 个十六进制字符")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        session?.invalidateAndCancel()
        session = URLSession(configuration: config, delegate: ServerTrust(fingerprint: pin), delegateQueue: nil)
        base = url
        var request = try request("POST", "login")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        struct Login: Decodable { let token: String }
        token = try JSONDecoder().decode(Login.self, from: await send(request)).token
    }

    func logout() async {
        if let request = try? request("POST", "logout") { _ = try? await send(request) }
        token = nil
        clipboard = nil
        thumbnails.removeAllObjects()
        session?.invalidateAndCancel()
        session = nil
    }

    private func request(_ method: String, _ action: String, path: [String] = [],
                         recursive: Bool = false, destination: [String]? = nil) throws -> URLRequest {
        guard let base else { throw APIError(message: "请先登录") }
        let endpoint = base.appendingPathComponent("api").appendingPathComponent(action)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if !path.isEmpty {
            var query = [URLQueryItem(name: "path", value: path.joined(separator: "/"))]
            if recursive { query.append(URLQueryItem(name: "recursive", value: "true")) }
            if let destination {
                query.append(URLQueryItem(name: "destination", value: destination.joined(separator: "/")))
            }
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func check(_ response: URLResponse, _ data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "服务器响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                token = nil
                clipboard = nil
                thumbnails.removeAllObjects()
            }
            struct Failure: Decodable { let error: String }
            let message = data.flatMap { try? JSONDecoder().decode(Failure.self, from: $0).error }
            throw APIError(message: message ?? "请求失败（\(http.statusCode)）")
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        guard let session else { throw APIError(message: "请先登录") }
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return data
    }

    func list(_ path: [String]) async throws -> [Entry] {
        let data = try await send(request("GET", "files", path: path))
        return try JSONDecoder().decode([Entry].self, from: data).sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func create(_ path: [String]) async throws { _ = try await send(request("POST", "folder", path: path)) }
    func delete(_ path: [String], directory: Bool) async throws {
        _ = try await send(request("DELETE", "file", path: path, recursive: directory))
    }

    func transfer(_ item: ClipboardItem, to destination: [String]) async throws {
        let action = item.move ? "move" : "copy"
        _ = try await send(request("POST", action, path: item.path, destination: destination))
    }

    func upload(_ file: URL, to path: [String]) async throws {
        guard let session else { throw APIError(message: "请先登录") }
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        let request = try request("PUT", "file", path: path + [file.lastPathComponent])
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try check(response, data)
    }

    func download(_ path: [String], into selectedFolder: URL? = nil) async throws -> URL {
        guard let session, let name = path.last else { throw APIError(message: "请选择文件") }
        let files = FileManager.default
        let accessed = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { selectedFolder?.stopAccessingSecurityScopedResource() } }
        let folder = selectedFolder ?? files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent(name)
        let conflict = APIError(message: "保存位置已有同名文件，请选择其他位置")
        if selectedFolder != nil && files.fileExists(atPath: file.path) { throw conflict }
        let request = try request("GET", "file", path: path)
        let (temporary, response) = try await session.download(for: request)
        defer { try? files.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try? FileHandle(forReadingFrom: temporary)
            defer { try? body?.close() }
            try check(response, try? body?.read(upToCount: 4096))
        } else {
            try check(response)
        }
        if selectedFolder != nil {
            do { try files.copyItem(at: temporary, to: file) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { throw conflict }
        } else {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try files.moveItem(at: temporary, to: file) }
            catch {
                try? files.removeItem(at: folder)
                throw error
            }
        }
        return file
    }

    func thumbnail(for entry: Entry, at path: [String]) async throws -> UIImage {
        guard let loginToken = token else { throw APIError(message: "请先登录") }
        let key = "\(path.joined(separator: "/"))\n\(entry.size)\n\(entry.modified ?? 0)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let file = try await download(path)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Task.checkCancellation()
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 120, height: 120),
                                                   scale: 2, representationTypes: .thumbnail)
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let image = representation?.uiImage { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? APIError(message: "无法生成缩略图")) }
            }
        }
        try Task.checkCancellation()
        if token == loginToken { thumbnails.setObject(image, forKey: key) }
        return image
    }
}

@main
struct PrivateNASApp: App {
    @StateObject private var drive = Drive()

    var body: some Scene {
        WindowGroup {
            if drive.token == nil {
                LoginView(drive: drive)
            } else {
                NavigationStack { FolderView(drive: drive, path: []) }
            }
        }
    }
}

private struct ServerProfile: Codable, Identifiable {
    var id = UUID()
    var name = ""
    var address = ""
    var username = ""
    var fingerprint = ""

    static let home = ServerProfile(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
        name: "家庭网盘", address: "https://desktop-evd50fu.tail5100bc.ts.net", username: "chenzheng")

    private static let legacyHomeAddresses = [
        "https://192.168.0.111:8787",
        "https://100.117.28.50:8787",
    ]

    private var normalizedAddress: String {
        address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isLegacyHome: Bool {
        username == Self.home.username && Self.legacyHomeAddresses.contains(normalizedAddress)
    }

    var updatedHomeProfile: Self {
        guard id == Self.home.id, username == Self.home.username,
              isLegacyHome || normalizedAddress == Self.home.address else { return self }
        var updated = self
        updated.address = Self.home.address
        updated.fingerprint = ""
        return updated
    }
}

private enum ServerPasswords {
    private static func query(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "PrivateNAS.ServerPassword",
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(for id: UUID) throws -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let password = String(data: data, encoding: .utf8) else {
            throw APIError(message: "无法读取 iPhone 钥匙串（\(status)）")
        }
        return password
    }

    static func save(_ password: String, for id: UUID) throws {
        var item = query(for: id)
        let data = Data(password.utf8)
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(item as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw APIError(message: "无法保存密码到 iPhone 钥匙串（\(status)）")
        }
    }
}

private struct LoginView: View {
    @ObservedObject var drive: Drive
    @AppStorage("serverProfiles") private var storedProfiles = Data()
    @AppStorage("didMigrateHomeToTailscale") private var didMigrateHomeToTailscale = false
    @State private var editor: ServerEditorRequest?
    @State private var error = ""
    @State private var connecting: UUID?

    private var profiles: [ServerProfile] {
        let saved = (try? JSONDecoder().decode([ServerProfile].self, from: storedProfiles)) ?? [.home]
        return didMigrateHomeToTailscale ? saved : saved.map(\.updatedHomeProfile)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("选择服务器") {
                    ForEach(profiles) { profile in
                        Button { connect(profile) } label: {
                            HStack {
                                Label(profile.name, systemImage: "externaldrive.connected.to.line.below")
                                Spacer()
                                if connecting == profile.id { ProgressView() }
                                else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(connecting != nil)
                        .contextMenu {
                            Button {
                                editor = ServerEditorRequest(profile: profile)
                            } label: { Label("编辑服务器", systemImage: "pencil") }
                        }
                    }
                    Button {
                        editor = ServerEditorRequest(profile: ServerProfile())
                    } label: { Label("新增服务器", systemImage: "plus.circle") }
                    .disabled(connecting != nil)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("私人网盘")
            .sheet(item: $editor) { request in
                ServerEditor(request: request) { profile, password in
                    try save(profile, password: password)
                    if request.passwordOnly { connect(profile) }
                }
            }
            .onAppear {
                migratePreviousServer()
                if !didMigrateHomeToTailscale, let data = try? JSONEncoder().encode(profiles) {
                    storedProfiles = data
                    didMigrateHomeToTailscale = true
                }
            }
        }
    }

    private func connect(_ profile: ServerProfile) {
        guard connecting == nil else { return }
        error = ""
        do {
            guard let password = try ServerPasswords.read(for: profile.id) else {
                editor = ServerEditorRequest(profile: profile, passwordOnly: true)
                return
            }
            connecting = profile.id
            Task {
                defer { connecting = nil }
                do {
                    try await drive.login(address: profile.address, fingerprint: profile.fingerprint,
                                          username: profile.username, password: password)
                } catch { self.error = "\(error.localizedDescription)  如需更新密码，请长按服务器并选择「编辑服务器」。" }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ profile: ServerProfile, password: String) throws {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        let data = try JSONEncoder().encode(updated)
        if !password.isEmpty { try ServerPasswords.save(password, for: profile.id) }
        storedProfiles = data
        error = ""
    }

    private func migratePreviousServer() {
        guard storedProfiles.isEmpty,
              let address = UserDefaults.standard.string(forKey: "serverAddress"), !address.isEmpty,
              address != ServerProfile.home.address else { return }
        let profile = ServerProfile(name: "之前的服务器", address: address,
                                    username: UserDefaults.standard.string(forKey: "ownerName") ?? "",
                                    fingerprint: UserDefaults.standard.string(forKey: "serverFingerprint") ?? "")
        guard !profile.isLegacyHome else { return }
        try? save(profile, password: "")
    }
}

private struct ServerEditorRequest: Identifiable {
    var id: UUID { profile.id }
    let profile: ServerProfile
    var passwordOnly = false
}

private struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let request: ServerEditorRequest
    let onSave: (ServerProfile, String) throws -> Void
    @State private var profile: ServerProfile
    @State private var password = ""
    @State private var error = ""

    init(request: ServerEditorRequest, onSave: @escaping (ServerProfile, String) throws -> Void) {
        self.request = request
        self.onSave = onSave
        _profile = State(initialValue: request.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !request.passwordOnly {
                    Section("服务器") {
                        TextField("名称", text: $profile.name)
                        TextField("https://服务器地址:8787", text: $profile.address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("自签名证书 SHA-256 指纹", text: $profile.fingerprint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("用户名", text: $profile.username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section {
                    SecureField("网盘密码", text: $password).textContentType(.password)
                } header: {
                    Text("登录凭据")
                } footer: {
                    Text("密码保存在这台 iPhone 的钥匙串中。")
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(request.passwordOnly ? profile.name : "服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.passwordOnly ? "保存并连接" : "保存", action: save)
                }
            }
        }
    }

    private func save() {
        do {
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.address = profile.address.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.fingerprint = profile.fingerprint.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
            guard !profile.name.isEmpty, !profile.username.isEmpty,
                  let url = URL(string: profile.address), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw APIError(message: "请填写名称、HTTPS 地址和用户名。")
            }
            guard profile.fingerprint.isEmpty ||
                    profile.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw APIError(message: "证书指纹应为 64 个十六进制字符。")
            }
            let original = request.profile
            let connectionChanged = profile.address != original.address || profile.username != original.username ||
                profile.fingerprint != original.fingerprint.lowercased()
            if password.isEmpty {
                guard !connectionChanged else { throw APIError(message: "请输入网盘密码。") }
                guard try ServerPasswords.read(for: profile.id) != nil else {
                    throw APIError(message: "请输入网盘密码。")
                }
            }
            try onSave(profile, password)
            password = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct FolderView: View {
    @ObservedObject var drive: Drive
    let path: [String]
    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var importing = false
    @State private var pendingDownload: Entry?
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var transferStatus: String?
    @State private var transferResult: String?
    @State private var creating = false
    @State private var folder = ""
    @State private var deleting: Entry?
    @State private var renaming: Entry?
    @State private var newName = ""
    @State private var export: Export?
    @State private var previewCache: URL?
    @State private var busy = false
    @State private var error = ""
    @State private var showingError = false

    private struct Export: Identifiable { let url: URL; var id: URL { url } }
    private var visible: [Entry] { entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        fileBrowser
        .alert("新建文件夹", isPresented: $creating) {
            TextField("文件夹名称", text: $folder)
            Button("取消", role: .cancel) {}
            Button("创建") {
                run {
                    guard !folder.isEmpty, !folder.contains("/") else { throw APIError(message: "请输入有效的文件夹名称") }
                    try await drive.create(path + [folder])
                    entries = try await drive.list(path)
                }
            }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { entry in
            TextField("新名称", text: $newName).autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = newName
                guard name != entry.name else { return }
                run {
                    guard !name.isEmpty, !name.contains("/") else { throw APIError(message: "请输入有效的名称") }
                    let source = path + [entry.name]
                    let target = path + [name]
                    try await drive.transfer(ClipboardItem(path: source, move: true), to: target)
                    if drive.clipboard?.path.starts(with: source) == true { drive.clipboard = nil }
                    entries = try await drive.list(path)
                }
            }
        } message: { entry in Text("当前名称：\(entry.name)") }
        .confirmationDialog("永久删除", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { entry in
            Button(entry.directory ? "删除文件夹及其内容" : "删除文件", role: .destructive) {
                run {
                    let source = path + [entry.name]
                    try await drive.delete(source, directory: entry.directory)
                    if drive.clipboard?.path.starts(with: source) == true { drive.clipboard = nil }
                    entries = try await drive.list(path)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(entry.directory
                 ? "「\(entry.name)」及其中的所有文件和子文件夹都会被永久删除。"
                 : "「\(entry.name)」将被永久删除。")
        }
        .alert("操作失败", isPresented: $showingError) { Button("确定", role: .cancel) {} } message: { Text(error) }
        .alert("传输结果", isPresented: Binding(get: { transferResult != nil }, set: { if !$0 { transferResult = nil } })) {
            Button("确定", role: .cancel) { transferResult = nil }
        } message: { Text(transferResult ?? "") }
        .sheet(item: $export, onDismiss: clearPreview) { item in
            FilePreview(file: item.url)
        }
    }

    private var fileList: some View {
        List(visible) { entry in
            Group {
                if entry.directory {
                    NavigationLink { FolderView(drive: drive, path: path + [entry.name]) } label: { row(entry) }
                } else {
                    Button { openPreview(entry) } label: {
                        row(entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .swipeActions(allowsFullSwipe: false) { deleteButton(entry) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !entry.directory {
                    Button { chooseDownloadLocation(entry) } label: {
                        Label("下载", systemImage: "arrow.down.to.line")
                    }
                    .tint(.blue)
                    .disabled(busy)
                }
            }
            .contextMenu { itemActions(entry) }
        }
    }

    private var fileBrowser: some View {
        fileList
        .overlay { folderOverlay }
        .navigationTitle(path.last ?? "我的文件")
        .searchable(text: $query, prompt: "搜索当前文件夹")
        .safeAreaInset(edge: .bottom) { clipboardBar }
        .toolbar { fileToolbar }
        .task { await refresh() }
        .refreshable { await refresh() }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 30,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            photos = []
            run { await uploadPhotos(selection) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: pendingDownload == nil ? [.item] : [.folder],
                      onCompletion: finishPickingLocation)
    }

    private func openPreview(_ entry: Entry) {
        run {
            transferStatus = "正在准备预览…"
            let file = try await drive.download(path + [entry.name])
            previewCache = file.deletingLastPathComponent()
            export = Export(url: file)
        }
    }

    private func clearPreview() {
        if let previewCache { try? FileManager.default.removeItem(at: previewCache) }
        previewCache = nil
    }

    private func chooseDownloadLocation(_ entry: Entry) {
        pendingDownload = entry
        importing = true
    }

    private func finishPickingLocation(_ result: Result<URL, Error>) {
        let downloadEntry = pendingDownload
        pendingDownload = nil
        run {
            let location = try result.get()
            if let entry = downloadEntry {
                transferStatus = "正在下载 \(entry.name)"
                _ = try await drive.download(path + [entry.name], into: location)
                transferResult = "已将「\(entry.name)」保存到「\(location.lastPathComponent)」。"
            } else {
                transferStatus = "正在上传 \(location.lastPathComponent)"
                try await drive.upload(location, to: path)
                entries = try await drive.list(path)
                transferResult = "已上传 \(location.lastPathComponent)"
            }
        }
    }

    @ViewBuilder
    private func fileActions(_ entry: Entry) -> some View {
        Button { openPreview(entry) } label: { Label("预览", systemImage: "eye") }
        Button { chooseDownloadLocation(entry) } label: {
            Label("下载并选择保存位置", systemImage: "arrow.down.to.line")
        }
    }

    @ViewBuilder
    private func itemActions(_ entry: Entry) -> some View {
        if !entry.directory { fileActions(entry).disabled(busy) }
        Button { drive.clipboard = ClipboardItem(path: path + [entry.name], move: false) } label: {
            Label("复制", systemImage: "document.on.document")
        }
        .disabled(busy)
        Button { drive.clipboard = ClipboardItem(path: path + [entry.name], move: true) } label: {
            Label("剪切", systemImage: "scissors")
        }
        .disabled(busy)
        Button { newName = entry.name; renaming = entry } label: {
            Label("重命名", systemImage: "pencil")
        }
        .disabled(busy)
        deleteButton(entry)
    }

    @ViewBuilder
    private var clipboardBar: some View {
        if let item = drive.clipboard {
            HStack {
                Label(item.name, systemImage: item.move ? "scissors" : "document.on.document")
                    .lineLimit(1)
                Spacer()
                Button(item.move ? "移动到这里" : "粘贴到这里") {
                    run {
                        transferStatus = item.move ? "正在移动…" : "正在复制…"
                        try await drive.transfer(item, to: path + [item.name])
                        if item.move { drive.clipboard = nil }
                        entries = try await drive.list(path)
                        transferResult = item.move ? "移动成功" : "复制成功"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                Button { drive.clipboard = nil } label: {
                    Image(systemName: "xmark.circle.fill").accessibilityLabel("清除剪贴板")
                }
                .disabled(busy)
            }
            .font(.subheadline)
            .padding()
            .background(.regularMaterial)
        }
    }

    private func deleteButton(_ entry: Entry) -> some View {
        Button(role: .destructive) { deleting = entry } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private var folderOverlay: some View {
        if busy {
            ProgressView(transferStatus ?? "正在加载…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .accessibilityElement(children: .combine)
        }
        else if entries.isEmpty { Text("文件夹为空").foregroundStyle(.secondary) }
        else if visible.isEmpty { Text("没有匹配的文件").foregroundStyle(.secondary) }
    }

    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { pickingPhotos = true } label: {
                    Label("上传照片和视频", systemImage: "photo.on.rectangle.angled")
                }
                Button { pendingDownload = nil; importing = true } label: {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("上传", systemImage: "plus.circle.fill")
            }
            .disabled(busy)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    folder = ""
                    creating = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                if path.isEmpty {
                    Button { run { await drive.logout() } } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Label("文件操作", systemImage: "ellipsis.circle")
            }
            .disabled(busy)
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            FileThumbnail(drive: drive, entry: entry, path: path + [entry.name])
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                if !entry.directory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func uploadPhotos(_ selection: [PhotosPickerItem]) async {
        var uploaded = 0
        var firstFailure: String?
        for (index, item) in selection.enumerated() {
            transferStatus = "正在上传相册项目 \(index + 1) / \(selection.count)"
            do {
                guard let photo = try await item.loadTransferable(type: PhotoFile.self) else {
                    throw APIError(message: "无法读取所选照片或视频")
                }
                defer { try? FileManager.default.removeItem(at: photo.url.deletingLastPathComponent()) }
                try await drive.upload(photo.url, to: path)
                uploaded += 1
            } catch {
                firstFailure = firstFailure ?? error.localizedDescription
                if drive.token == nil { break }
            }
        }
        if drive.token != nil {
            do { entries = try await drive.list(path) }
            catch { firstFailure = firstFailure ?? error.localizedDescription }
        }
        var result = "已上传 \(uploaded) / \(selection.count) 个项目。"
        if let firstFailure { result += "\n\(firstFailure)" }
        transferResult = result
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { entries = try await drive.list(path) }
        catch { show(error) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false; transferStatus = nil }
            do { try await action() }
            catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        self.error = error.localizedDescription
        showingError = true
    }
}

private struct FileThumbnail: View {
    let drive: Drive
    let entry: Entry
    let path: [String]
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color.blue.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: entry.icon)
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
        .task(id: entry.modified) {
            image = nil
            guard entry.canLoadThumbnail else { return }
            image = try? await drive.thumbnail(for: entry, at: path)
        }
    }
}

private struct FilePreview: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(file as NSURL) {
                    QuickLookFile(file: file)
                } else {
                    ContentUnavailableView("无法预览此格式", systemImage: "doc",
                                           description: Text("可以分享文件，或存到「文件」后用其他 App 打开。"))
                }
            }
            .navigationTitle(file.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: file) { Label("分享或存储到「文件」", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
}

private struct QuickLookFile: UIViewControllerRepresentable {
    let file: URL

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.file != file else { return }
        context.coordinator.file = file
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var file: URL
        init(file: URL) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            file as NSURL
        }
    }
}
