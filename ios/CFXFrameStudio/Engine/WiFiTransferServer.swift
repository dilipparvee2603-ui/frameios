import Foundation
import Network
import UIKit
import Photos
import Darwin

// MARK: - Wi-Fi File Item
struct WiFiSharedFile: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let modifiedDate: Date
    let isVideo: Bool
    let isImage: Bool

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modifiedDate)
    }
}

// MARK: - Wi-Fi Transfer Server
final class WiFiTransferServer: ObservableObject {
    static let shared = WiFiTransferServer()

    @Published var isRunning: Bool = false
    @Published var localIP: String? = nil
    @Published var port: UInt16 = 8080
    @Published var activeConnections: Int = 0
    @Published var bytesReceived: Int64 = 0
    @Published var bytesSent: Int64 = 0
    @Published var statusMessage: String = "Offline"
    @Published var autoSaveToPhotos: Bool = true
    @Published var sharedFiles: [WiFiSharedFile] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cfx.framestudio.wifitransfer", qos: .userInitiated)
    private var activeConnectionObjects: [ObjectIdentifier: NWConnection] = [:]

    private init() {
        refreshSharedFiles()
    }

    var serverUrlString: String? {
        guard let ip = localIP, isRunning else { return nil }
        return "http://\(ip):\(port)"
    }

    // MARK: - Start / Stop
    func startServer() {
        guard !isRunning else { return }

        guard let ip = getLocalIPAddress() else {
            statusMessage = "Wi-Fi or Hotspot not connected"
            return
        }

        self.localIP = ip

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? 8080)

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.statusMessage = "Server Active on Wi-Fi"
                    case .failed(let error):
                        self?.isRunning = false
                        self?.statusMessage = "Failed: \(error.localizedDescription)"
                    case .cancelled:
                        self?.isRunning = false
                        self?.statusMessage = "Server Stopped"
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: queue)
            self.listener = listener
            refreshSharedFiles()
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        for (_, conn) in activeConnectionObjects {
            conn.cancel()
        }
        activeConnectionObjects.removeAll()

        DispatchQueue.main.async {
            self.isRunning = false
            self.activeConnections = 0
            self.statusMessage = "Offline"
        }
    }

    // MARK: - Local IP Discovery
    func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 = Wi-Fi, bridge100/ap0 = Personal Hotspot
                if name == "en0" || name == "bridge100" || name == "ap0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if name == "en0" { return address }
                }
            }
        }
        return address
    }

    // MARK: - Files Management
    func refreshSharedFiles() {
        Task.detached(priority: .userInitiated) {
            let docsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let tempUrl = FileManager.default.temporaryDirectory

            var results: [WiFiSharedFile] = []
            results += self.collectFiles(in: docsUrl)
            results += self.collectFiles(in: tempUrl)

            // Sort newest first
            results.sort { $0.modifiedDate > $1.modifiedDate }

            await MainActor.run {
                self.sharedFiles = results
            }
        }
    }

    private func collectFiles(in dir: URL) -> [WiFiSharedFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var files: [WiFiSharedFile] = []
        for case let fileUrl as URL in enumerator {
            guard let resourceValues = try? fileUrl.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }

            let size = Int64(resourceValues.fileSize ?? 0)
            let date = resourceValues.contentModificationDate ?? Date()
            let ext = fileUrl.pathExtension.lowercased()

            let isVid = ["mp4", "mov", "mkv", "webm", "avi", "m4v", "ts"].contains(ext)
            let isImg = ["png", "jpg", "jpeg", "webp", "heic"].contains(ext)

            if isVid || isImg {
                files.append(WiFiSharedFile(
                    id: fileUrl.lastPathComponent,
                    name: fileUrl.lastPathComponent,
                    sizeBytes: size,
                    modifiedDate: date,
                    isVideo: isVid,
                    isImage: isImg
                ))
            }
        }
        return files
    }

    // MARK: - Connection Handler
    private func handleNewConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        activeConnectionObjects[connId] = connection

        DispatchQueue.main.async {
            self.activeConnections = self.activeConnectionObjects.count
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.activeConnectionObjects.removeValue(forKey: connId)
                DispatchQueue.main.async {
                    self?.activeConnections = self?.activeConnectionObjects.count ?? 0
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        readHttpRequest(connection: connection)
    }

    private func readHttpRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.processRequest(data: data, connection: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP Dispatcher
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data.prefix(2048), encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Invalid Request".data(using: .utf8)!)
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Empty Request".data(using: .utf8)!)
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Bad Line".data(using: .utf8)!)
            return
        }

        let method = parts[0].uppercased()
        let path = parts[1]

        if method == "GET" {
            handleGet(path: path, connection: connection)
        } else if method == "POST" {
            handlePost(path: path, headerData: data, connection: connection)
        } else {
            sendResponse(connection: connection, status: "405 Method Not Allowed", contentType: "text/plain", body: "Method Not Allowed".data(using: .utf8)!)
        }
    }

    // MARK: - GET Handlers
    private func handleGet(path: String, connection: NWConnection) {
        let parsed = URLComponents(string: "http://localhost" + path)
        let cleanPath = parsed?.path ?? path

        switch cleanPath {
        case "/", "/index.html":
            let html = buildWebDashboardHtml()
            sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html.data(using: .utf8)!)

        case "/api/files":
            let fileList = sharedFiles.map { file -> [String: Any] in
                return [
                    "name": file.name,
                    "size": file.sizeFormatted,
                    "bytes": file.sizeBytes,
                    "date": file.dateFormatted,
                    "isVideo": file.isVideo,
                    "isImage": file.isImage
                ]
            }
            if let json = try? JSONSerialization.data(withJSONObject: fileList) {
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: json)
            } else {
                sendResponse(connection: connection, status: "500 Internal Error", contentType: "text/plain", body: "{}".data(using: .utf8)!)
            }

        case "/api/download":
            if let queryItems = parsed?.queryItems,
               let name = queryItems.first(where: { $0.name == "name" })?.value {
                streamFileDownload(filename: name, connection: connection)
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Missing filename".data(using: .utf8)!)
            }

        default:
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "Not Found".data(using: .utf8)!)
        }
    }

    // MARK: - POST Handlers (Upload / Delete)
    private func handlePost(path: String, headerData: Data, connection: NWConnection) {
        let parsed = URLComponents(string: "http://localhost" + path)
        let cleanPath = parsed?.path ?? path

        switch cleanPath {
        case "/api/upload":
            let filename = parsed?.queryItems?.first(where: { $0.name == "name" })?.value ?? "Upload_\(Int(Date().timeIntervalSince1970)).mp4"
            handleBinaryUpload(filename: filename, initialData: headerData, connection: connection)

        case "/api/delete":
            if let name = parsed?.queryItems?.first(where: { $0.name == "name" })?.value {
                deleteFile(named: name)
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: "{\"success\":true}".data(using: .utf8)!)
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Missing filename".data(using: .utf8)!)
            }

        default:
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "Not Found".data(using: .utf8)!)
        }
    }

    // MARK: - File Download Streaming
    private func streamFileDownload(filename: String, connection: NWConnection) {
        guard let fileUrl = findFileUrl(named: filename) else {
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "File Not Found".data(using: .utf8)!)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileUrl) else {
            sendResponse(connection: connection, status: "500 Internal Error", contentType: "text/plain", body: "Cannot read file".data(using: .utf8)!)
            return
        }

        let fileSize = (try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename

        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Length: \(fileSize)\r
        Content-Disposition: attachment; filename="\(encodedName)"\r
        Connection: keep-alive\r
        \r\n
        """

        connection.send(content: header.data(using: .utf8)!, completion: .contentProcessed { [weak self] _ in
            self?.streamChunk(handle: handle, connection: connection)
        })
    }

    private func streamChunk(handle: FileHandle, connection: NWConnection) {
        let chunkSize = 256 * 1024
        let data = handle.readData(ofLength: chunkSize)

        if data.isEmpty {
            try? handle.close()
            connection.cancel()
            return
        }

        DispatchQueue.main.async {
            self.bytesSent += Int64(data.count)
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error == nil {
                self?.streamChunk(handle: handle, connection: connection)
            } else {
                try? handle.close()
                connection.cancel()
            }
        })
    }

    // MARK: - Binary Upload Stream
    private func handleBinaryUpload(filename: String, initialData: Data, connection: NWConnection) {
        let docsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let targetUrl = docsUrl.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: targetUrl)

        // Find boundary of HTTP headers (\r\n\r\n)
        let headerDelimiter = "\r\n\r\n".data(using: .utf8)!
        guard let range = initialData.range(of: headerDelimiter) else {
            sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: "Invalid Headers".data(using: .utf8)!)
            return
        }

        let bodyStartIndex = range.upperBound
        let initialBody = initialData.subdata(in: bodyStartIndex..<initialData.count)

        // Extract Content-Length
        let headerStr = String(data: initialData.subdata(in: 0..<range.lowerBound), encoding: .utf8) ?? ""
        var expectedBytes: Int64 = -1
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    expectedBytes = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
                }
            }
        }

        FileManager.default.createFile(atPath: targetUrl.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: targetUrl) else {
            sendResponse(connection: connection, status: "500 Internal Error", contentType: "text/plain", body: "Cannot write file".data(using: .utf8)!)
            return
        }

        handle.write(initialBody)
        var totalReceived: Int64 = Int64(initialBody.count)
        DispatchQueue.main.async {
            self.bytesReceived += Int64(initialBody.count)
        }

        if expectedBytes > 0 && totalReceived >= expectedBytes {
            try? handle.close()
            finishUpload(targetUrl: targetUrl, connection: connection)
            return
        }

        receiveUploadChunks(handle: handle, expectedBytes: expectedBytes, totalReceived: &totalReceived, targetUrl: targetUrl, connection: connection)
    }

    private func receiveUploadChunks(
        handle: FileHandle,
        expectedBytes: Int64,
        totalReceived: inout Int64,
        targetUrl: URL,
        connection: NWConnection
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let chunk = content, !chunk.isEmpty {
                handle.write(chunk)
                let cCount = Int64(chunk.count)
                totalReceived += cCount
                DispatchQueue.main.async {
                    self.bytesReceived += cCount
                }
            }

            if (expectedBytes > 0 && totalReceived >= expectedBytes) || isComplete || error != nil {
                try? handle.close()
                self.finishUpload(targetUrl: targetUrl, connection: connection)
            } else {
                var copyReceived = totalReceived
                self.receiveUploadChunks(handle: handle, expectedBytes: expectedBytes, totalReceived: &copyReceived, targetUrl: targetUrl, connection: connection)
            }
        }
    }

    private func finishUpload(targetUrl: URL, connection: NWConnection) {
        if autoSaveToPhotos {
            let ext = targetUrl.pathExtension.lowercased()
            if ["mp4", "mov", "m4v"].contains(ext) {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetUrl)
                })
            } else if ["png", "jpg", "jpeg"].contains(ext) {
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: targetUrl, options: nil)
                })
            }
        }

        refreshSharedFiles()
        sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: "{\"success\":true}".data(using: .utf8)!)
    }

    private func deleteFile(named: String) {
        if let url = findFileUrl(named: named) {
            try? FileManager.default.removeItem(at: url)
            refreshSharedFiles()
        }
    }

    private func findFileUrl(named: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: docs.path) { return docs }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: temp.path) { return temp }
        return nil
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r\n
        """
        var responseData = header.data(using: .utf8)!
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Modern Glassmorphic Web Dashboard HTML
    private func buildWebDashboardHtml() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>CFX Frame Studio — Wi-Fi Transfer</title>
          <style>
            :root {
              --bg: #0D0D11;
              --card: #15151A;
              --elevated: #1A1A22;
              --accent: #C0000A;
              --accent-gradient: linear-gradient(135deg, #FF4A3D, #D92A20);
              --emerald: #10B981;
              --sky: #38BDF8;
              --text: #F4F5F7;
              --muted: #94A3B8;
              --border: rgba(255,255,255,0.08);
            }
            * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
            body { background: var(--bg); color: var(--text); padding: 32px 20px; display: flex; justify-content: center; }
            .container { max-width: 900px; width: 100%; display: flex; flex-direction: column; gap: 24px; }
            header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--border); padding-bottom: 18px; }
            .logo { display: flex; align-items: center; gap: 10px; font-weight: 900; font-size: 18px; letter-spacing: 1px; }
            .logo-dot { width: 10px; height: 10px; background: var(--accent); border-radius: 50%; box-shadow: 0 0 10px var(--accent); }
            .badge { background: rgba(16,185,129,0.14); color: var(--emerald); border: 1px solid rgba(16,185,129,0.3); padding: 4px 10px; border-radius: 20px; font-size: 11px; font-weight: 700; }
            
            /* Drag and Drop Zone */
            .drop-zone {
              background: var(--card); border: 2px dashed rgba(255,255,255,0.14); border-radius: 18px; padding: 40px 20px;
              text-align: center; cursor: pointer; transition: all 0.2s ease;
            }
            .drop-zone:hover, .drop-zone.dragover { border-color: var(--accent); background: var(--elevated); }
            .drop-icon { font-size: 38px; margin-bottom: 10px; color: var(--sky); }
            .drop-title { font-size: 16px; font-weight: 700; margin-bottom: 4px; }
            .drop-sub { font-size: 12px; color: var(--muted); }
            #fileInput { display: none; }
            
            /* Upload Progress */
            .progress-card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 16px; display: none; flex-direction: column; gap: 8px; }
            .progress-bar-bg { background: var(--elevated); height: 8px; border-radius: 4px; overflow: hidden; }
            .progress-bar-fill { background: var(--accent-gradient); width: 0%; height: 100%; transition: width 0.1s linear; }
            .progress-stats { display: flex; justify-content: space-between; font-size: 12px; font-family: monospace; color: var(--muted); }

            /* Files Table */
            .files-card { background: var(--card); border: 1px solid var(--border); border-radius: 18px; overflow: hidden; }
            .files-header { padding: 16px 20px; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; }
            .files-title { font-size: 14px; font-weight: 800; letter-spacing: 0.5px; }
            table { width: 100%; border-collapse: collapse; }
            th { text-align: left; padding: 12px 20px; font-size: 11px; color: var(--muted); border-bottom: 1px solid var(--border); text-transform: uppercase; }
            td { padding: 14px 20px; font-size: 13px; border-bottom: 1px solid rgba(255,255,255,0.04); }
            tr:hover td { background: rgba(255,255,255,0.02); }
            .btn {
              padding: 6px 14px; border-radius: 8px; font-size: 12px; font-weight: 700; cursor: pointer; border: none; text-decoration: none; display: inline-flex; align-items: center; gap: 4px;
            }
            .btn-download { background: var(--sky); color: #000; }
            .btn-delete { background: rgba(192,0,10,0.15); color: #FF4A3D; margin-left: 6px; }
          </style>
        </head>
        <body>
          <div class="container">
            <header>
              <div class="logo">
                <div class="logo-dot"></div>
                <span>CFX FRAME STUDIO</span>
              </div>
              <div class="badge">● IPHONE WI-FI DIRECT</div>
            </header>

            <!-- Drag & Drop Card -->
            <div class="drop-zone" id="dropZone" onclick="document.getElementById('fileInput').click()">
              <div class="drop-icon">⚡</div>
              <div class="drop-title">Drag & Drop Videos or Photos to Send to iPhone</div>
              <div class="drop-sub">Supports 4K MKV, MP4, MOV, HEVC, and Lossless PNG up to 50GB</div>
              <input type="file" id="fileInput" multiple onchange="handleFileSelect(this.files)">
            </div>

            <!-- Upload Progress -->
            <div class="progress-card" id="progressCard">
              <div class="progress-stats">
                <span id="progressName">Uploading...</span>
                <span id="progressSpeed">0%</span>
              </div>
              <div class="progress-bar-bg">
                <div class="progress-bar-fill" id="progressFill"></div>
              </div>
            </div>

            <!-- Files On iPhone Table -->
            <div class="files-card">
              <div class="files-header">
                <span class="files-title">FILES READY ON IPHONE</span>
                <button class="btn btn-download" onclick="loadFiles()">Refresh List</button>
              </div>
              <table>
                <thead>
                  <tr>
                    <th>Filename</th>
                    <th>Size</th>
                    <th>Date</th>
                    <th style="text-align: right;">Action</th>
                  </tr>
                </thead>
                <tbody id="filesTableBody">
                  <tr><td colspan="4" style="text-align: center; color: var(--muted); padding: 30px;">Loading files...</td></tr>
                </tbody>
              </table>
            </div>
          </div>

          <script>
            function loadFiles() {
              fetch('/api/files')
                .then(r => r.json())
                .then(files => {
                  const tbody = document.getElementById('filesTableBody');
                  if (!files || files.length === 0) {
                    tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; color: var(--muted); padding: 30px;">No video files found on iPhone.</td></tr>';
                    return;
                  }
                  tbody.innerHTML = files.map(f => `
                    <tr>
                      <td style="font-weight: 600;">${f.name}</td>
                      <td style="font-family: monospace; color: var(--sky);">${f.size}</td>
                      <td style="color: var(--muted); font-size: 11px;">${f.date}</td>
                      <td style="text-align: right;">
                        <a class="btn btn-download" href="/api/download?name=${encodeURIComponent(f.name)}">Download</a>
                        <button class="btn btn-delete" onclick="deleteFile('${encodeURIComponent(f.name)}')">Delete</button>
                      </td>
                    </tr>
                  `).join('');
                })
                .catch(err => console.error(err));
            }

            function deleteFile(name) {
              if (!confirm('Delete file from iPhone?')) return;
              fetch('/api/delete?name=' + name, { method: 'POST' })
                .then(() => loadFiles());
            }

            function handleFileSelect(files) {
              if (!files || files.length === 0) return;
              uploadFile(files[0]);
            }

            function uploadFile(file) {
              const card = document.getElementById('progressCard');
              const fill = document.getElementById('progressFill');
              const nameLbl = document.getElementById('progressName');
              const speedLbl = document.getElementById('progressSpeed');

              card.style.display = 'flex';
              nameLbl.textContent = 'Uploading: ' + file.name;

              const xhr = new XMLHttpRequest();
              const startTime = Date.now();

              xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                  const pct = Math.round((e.loaded / e.total) * 100);
                  fill.style.width = pct + '%';
                  const sec = (Date.now() - startTime) / 1000;
                  const mbps = sec > 0 ? ((e.loaded / (1024 * 1024)) / sec).toFixed(1) : '0';
                  speedLbl.textContent = pct + '% (' + mbps + ' MB/s)';
                }
              };

              xhr.onload = () => {
                card.style.display = 'none';
                loadFiles();
              };

              xhr.onerror = () => {
                alert('Upload failed over Wi-Fi.');
                card.style.display = 'none';
              };

              xhr.open('POST', '/api/upload?name=' + encodeURIComponent(file.name), true);
              xhr.send(file);
            }

            // Drag and Drop
            const drop = document.getElementById('dropZone');
            ['dragenter', 'dragover'].forEach(ev => {
              drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('dragover'); });
            });
            ['dragleave', 'drop'].forEach(ev => {
              drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('dragover'); });
            });
            drop.addEventListener('drop', (e) => {
              const dt = e.dataTransfer;
              if (dt && dt.files && dt.files.length > 0) {
                uploadFile(dt.files[0]);
              }
            });

            loadFiles();
          </script>
        </body>
        </html>
        """
    }
}
