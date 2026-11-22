import CryptoKit
import Security
import SwiftUI
import UniformTypeIdentifiers

private struct Entry: Decodable, Identifiable {
    let name: String
    let directory: Bool
    let size: Int64
    var id: String { name }
}

private struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    private var base: URL?
    private var session: URLSession?

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
        session?.invalidateAndCancel()
        session = nil
    }

    private func request(_ method: String, _ action: String, path: [String] = []) throws -> URLRequest {
        guard let base else { throw APIError(message: "请先登录") }
        let endpoint = base.appendingPathComponent("api").appendingPathComponent(action)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if !path.isEmpty {
            components.queryItems = [URLQueryItem(name: "path", value: path.joined(separator: "/"))]
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
            if http.statusCode == 401 { token = nil }
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
    func delete(_ path: [String]) async throws { _ = try await send(request("DELETE", "file", path: path)) }

    func upload(_ file: URL, to path: [String]) async throws {
        guard let session else { throw APIError(message: "请先登录") }
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        let request = try request("PUT", "file", path: path + [file.lastPathComponent])
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try check(response, data)
    }

    func download(_ path: [String]) async throws -> URL {
        guard let session, let name = path.last else { throw APIError(message: "请选择文件") }
        let request = try request("GET", "file", path: path)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
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

private struct LoginView: View {
    @ObservedObject var drive: Drive
    @AppStorage("serverAddress") private var address = ""
    @AppStorage("serverFingerprint") private var fingerprint = ""
    @AppStorage("ownerName") private var username = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("https://公网地址:8787", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("自签名证书 SHA-256 指纹", text: $fingerprint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("网盘账号") {
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                }
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        error = ""
                        do {
                            try await drive.login(address: address, fingerprint: fingerprint, username: username, password: password)
                            password = ""
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    if busy { ProgressView() } else { Text("登录") }
                }
                .disabled(busy || address.isEmpty || username.isEmpty || password.isEmpty)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("私人网盘")
        }
    }
}

private struct FolderView: View {
    @ObservedObject var drive: Drive
    let path: [String]
    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var importing = false
    @State private var creating = false
    @State private var folder = ""
    @State private var deleting: Entry?
    @State private var export: Export?
    @State private var busy = false
    @State private var error = ""
    @State private var showingError = false

    private struct Export: Identifiable { let url: URL; var id: URL { url } }
    private var visible: [Entry] { entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        List(visible) { entry in
            Group {
                if entry.directory {
                    NavigationLink { FolderView(drive: drive, path: path + [entry.name]) } label: { row(entry) }
                } else {
                    Button { run { export = Export(url: try await drive.download(path + [entry.name])) } } label: { row(entry) }
                        .buttonStyle(.plain)
                }
            }
            .swipeActions { Button("删除", role: .destructive) { deleting = entry } }
        }
        .overlay {
            if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            else if entries.isEmpty { Text("文件夹为空").foregroundStyle(.secondary) }
            else if visible.isEmpty { Text("没有匹配的文件").foregroundStyle(.secondary) }
        }
        .navigationTitle(path.last ?? "我的文件")
        .searchable(text: $query, prompt: "搜索当前文件夹")
        .toolbar { fileToolbar }
        .task { await refresh() }
        .refreshable { await refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            run { try await drive.upload(result.get(), to: path); entries = try await drive.list(path) }
        }
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
        .confirmationDialog("永久删除此项目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
            Button("删除 \(entry.name)", role: .destructive) {
                run { try await drive.delete(path + [entry.name]); entries = try await drive.list(path) }
            }
        }
        .alert("操作失败", isPresented: $showingError) { Button("确定", role: .cancel) {} } message: { Text(error) }
        .sheet(item: $export, onDismiss: { export = nil }) { item in
            VStack(spacing: 20) {
                Text(item.url.lastPathComponent).font(.headline)
                ShareLink(item: item.url) { Label("分享或存储到「文件」", systemImage: "square.and.arrow.up") }
            }
            .padding()
            .presentationDetents([.medium])
        }
    }

    private var fileToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { importing = true } label: {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
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
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                if !entry.directory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: entry.directory ? "folder.fill" : "doc")
                .foregroundStyle(.blue).frame(width: 28)
        }
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
            defer { busy = false }
            do { try await action() }
            catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        self.error = error.localizedDescription
        showingError = true
    }
}
