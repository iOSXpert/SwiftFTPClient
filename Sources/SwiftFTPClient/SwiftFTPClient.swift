import Foundation
import Network

/// A client for interacting with FTP servers.
///
/// This class provides functionality to connect to an FTP server, upload files or data,
/// and manage the transfer process.
///
/// Example usage:
/// ```swift
/// let credentials = FTPCredentials(host: "ftp.example.com", port: 21, username: "user", password: "pass")
/// let remotePath = "/upload/path"
///
/// let ftpClient = FTPClient(credentials: credentials, remotePath: remotePath)
///
/// let filesToUpload: [FTPUploadable] = [
///     .file(url: URL(fileURLWithPath: "/path/to/local/file1.txt"), remoteFileName: "file1.txt"),
///     .data(data: Data("Sample data".utf8), remoteFileName: "sample.txt")
/// ]
///
/// ftpClient.upload(files: filesToUpload, progressHandler: { progress in
///     print("Overall progress: \(progress.fractionCompleted * 100)%")
/// }, completionHandler: { result in
///     switch result {
///     case .success:
///         print("All files uploaded successfully.")
///     case .failure(let error):
///         print("An error occurred: \(error)")
///     }
/// })
/// ```

public class FTPClient {
    private let credentials: FTPCredentials
    private let remotePath: String
    private var controlConnection: NWConnection?
    private var isCancelled = false
    private var progress: Progress?
    private let bufferSize: Int

    /// Initializes a new FTP client.
    /// - Parameters:
    ///   - credentials: The credentials for connecting to the FTP server.
    ///   - remotePath: The remote path on the server where files will be uploaded.
    public init(credentials: FTPCredentials, remotePath: String, progress: Progress? = nil, bufferSize: Int = 512 * 1024) {
        self.credentials = credentials
        self.remotePath = remotePath
        self.progress = progress
        self.bufferSize = bufferSize
    }

    // MARK: - Public Methods

    /// Uploads multiple files to the FTP server.
    /// - Parameters:
    ///   - files: An array of `FTPUploadable` items to be uploaded.
    ///   - progressHandler: A closure that is called with updates on the overall progress of the upload.
    ///   - completionHandler: A closure that is called when all uploads are complete, or if an error occurs.
    public func upload(
        files: [FTPUploadable],
        progressHandler: @escaping (Progress) -> Void,
        completionHandler: @escaping (Result<Void, FTPError>) -> Void
    ) {
        Task {
            do {
                try await upload(files: files, progressHandler: progressHandler)
                completionHandler(.success(()))
            } catch let error as FTPError {
                completionHandler(.failure(error))
            } catch {
                completionHandler(.failure(FTPError.other(error.localizedDescription)))
            }
        }
    }

    /// Cancels any ongoing transfer operations.
    public func cancel() {
        isCancelled = true
        controlConnection?.cancel()
    }

    // MARK: - Private Methods

    public func upload(
        files: [FTPUploadable],
        progressHandler: @escaping (Progress) -> Void
    ) async throws {
        // Connect and authenticate
        try await connect()

        // Calculate total size for Progress
        let totalSize = try files.reduce(0) { (result, uploadable) -> Int64 in
            switch uploadable {
            case .file(let url, _):
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return result + (attributes[.size] as? Int64 ?? 0)
            case .data(let data, _):
                return result + Int64(data.count)
            }
        }

        let progress = self.progress ?? Progress(totalUnitCount: totalSize)
        progressHandler(progress)

        for uploadable in files {
            if isCancelled {
                throw FTPError.cancelled
            }

            switch uploadable {
            case .file(let url, let remoteFileName):
                try await uploadFile(url: url, remoteFileName: remoteFileName, progress: progress, progressHandler: progressHandler)
            case .data(let data, let remoteFileName):
                try await uploadData(data: data, remoteFileName: remoteFileName, progress: progress, progressHandler: progressHandler)
            }
        }

        // Close control connection
        controlConnection?.cancel()
    }

    private func connect() async throws {
        let parameters = NWParameters.tcp
        let endpoint = NWEndpoint.Host(credentials.host)
        let port = NWEndpoint.Port(rawValue: credentials.port)!
        controlConnection = NWConnection(host: endpoint, port: port, using: parameters)

        try await withSafeStateHandler { completion in
            controlConnection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion(.success(()))
                case .failed(let error):
                    completion(.failure(FTPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    completion(.failure(FTPError.cancelled))
                default:
                    break
                }
            }
            controlConnection?.start(queue: .global())
        }

        // Read the initial server response
        _ = try await readResponse()

        // Send USER command
        try await sendCommand("USER \(credentials.username)")
        let userResponse = try await readResponse()
        guard userResponse.starts(with: "331") else {
            throw FTPError.authenticationFailed("Username not accepted: \(userResponse)")
        }

        // Send PASS command
        try await sendCommand("PASS \(credentials.password)")
        let passResponse = try await readResponse()
        guard passResponse.starts(with: "230") else {
            throw FTPError.authenticationFailed("Password not accepted: \(passResponse)")
        }

        // Change directory to remotePath
        try await sendCommand("CWD \(remotePath)")
        let cwdResponse = try await readResponse()
        guard cwdResponse.starts(with: "250") else {
            throw FTPError.other("Failed to change to remote directory: \(cwdResponse)")
        }
    }

    private func sendCommand(_ command: String) async throws {
        guard let connection = controlConnection else {
            throw FTPError.connectionFailed("No control connection available.")
        }
        let commandWithCRLF = command + "\r\n"
        guard let data = commandWithCRLF.data(using: .utf8) else {
            throw FTPError.other("Failed to encode command.")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: FTPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }))
        }
    }

    private func readResponse() async throws -> String {
        guard let connection = controlConnection else {
            throw FTPError.connectionFailed("No control connection available.")
        }

        var completeResponse = ""
        while true {
            let partialResponse: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: FTPError.connectionFailed(error.localizedDescription))
                    } else if let data = data, let response = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: response)
                    } else if isComplete {
                        continuation.resume(throwing: FTPError.other("Connection closed while reading response."))
                    } else {
                        continuation.resume(throwing: FTPError.other("Failed to read response from server."))
                    }
                }
            }
            completeResponse += partialResponse
            // Check if response is complete (ends with \r\n)
            if completeResponse.hasSuffix("\r\n") {
                break
            }
        }
        return completeResponse
    }

    private func uploadFile(
        url: URL,
        remoteFileName: String,
        progress: Progress,
        progressHandler: @escaping (Progress) -> Void
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        // Enter passive mode
        let dataConnection = try await enterPassiveModeAndOpenDataConnection()

        // Send STOR command
        try await sendCommand("STOR \(remoteFileName)")
        let storResponse = try await readResponse()
        guard storResponse.starts(with: "150") else {
            throw FTPError.transferFailed("Failed to initiate file transfer: \(storResponse)")
        }

        // Send file data
        //let bufferSize = 1024 * 1024 // 1MB buffer
        while true {
            if isCancelled {
                dataConnection.cancel()
                throw FTPError.cancelled
            }

            if #available(macOS 10.15.4, *) {
                let data = try fileHandle.read(upToCount: bufferSize)
                if let data = data, !data.isEmpty {
                    try await sendData(data: data, over: dataConnection)
                    progress.completedUnitCount += Int64(data.count)
                    progressHandler(progress)
                } else {
                    break
                }
            } else {
                fatalError("SwiftFTPClient requires macOS 10.15.4 or later.")
            }
        }

        // Close data connection
        dataConnection.cancel()

        // Read server response
        let transferResponse = try await readResponse()
        guard transferResponse.starts(with: "226") else {
            throw FTPError.transferFailed("File transfer failed: \(transferResponse)")
        }
    }

    private func uploadData(
        data: Data,
        remoteFileName: String,
        progress: Progress,
        progressHandler: @escaping (Progress) -> Void
    ) async throws {
        // Enter passive mode
        let dataConnection = try await enterPassiveModeAndOpenDataConnection()

        // Send STOR command
        try await sendCommand("STOR \(remoteFileName)")
        let storResponse = try await readResponse()
        guard storResponse.starts(with: "150") else {
            throw FTPError.transferFailed("Failed to initiate data transfer: \(storResponse)")
        }

        // Send data
        try await sendData(data: data, over: dataConnection)
        progress.completedUnitCount += Int64(data.count)
        progressHandler(progress)

        // Close data connection
        dataConnection.cancel()

        // Read server response
        let transferResponse = try await readResponse()
        guard transferResponse.starts(with: "226") else {
            throw FTPError.transferFailed("Data transfer failed: \(transferResponse)")
        }
    }

    // MARK: - Download

    /// Downloads a remote file to a local URL.
    /// - Parameters:
    ///   - remoteFileName: The name/path of the file on the FTP server (relative to current remote directory).
    ///   - localURL: The local file URL to write to. If the file exists it will be overwritten.
    ///   - progressHandler: Optional handler for incremental progress updates.
    @available(macOS 10.15.4, *)
    public func download(
        remoteFileName: String,
        to localURL: URL,
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws {
        // Ensure we're connected
        if controlConnection == nil { try await connect() }

        // Switch to binary mode where supported
        try? await sendCommand("TYPE I")
        _ = try? await readResponse()

        // Try to fetch total size (some servers may not support SIZE)
        var totalSize: Int64 = 0
        var hasTotal = false
        do {
            try await sendCommand("SIZE \(remoteFileName)")
            let sizeResp = try await readResponse()
            if sizeResp.hasPrefix("213") {
                // format: 213 <size>\r\n
                if let last = sizeResp.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first,
                   let sizeStr = last.split(separator: " ").last,
                   let sz = Int64(sizeStr) {
                    totalSize = sz
                    hasTotal = true
                }
            }
        } catch {
            // Ignore SIZE errors; progress will be indeterminate
        }

        let progress = Progress(totalUnitCount: hasTotal ? totalSize : 0)
        progressHandler?(progress)

        // Prepare local file
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
        let writeHandle = try FileHandle(forWritingTo: localURL)
        defer { try? writeHandle.close() }

        // Open passive data connection and request file
        let dataConnection = try await enterPassiveModeAndOpenDataConnection()
        try await sendCommand("RETR \(remoteFileName)")
        let retrResp = try await readResponse()
        guard retrResp.hasPrefix("150") else {
            dataConnection.cancel()
            throw FTPError.transferFailed("Failed to initiate download: \(retrResp)")
        }

        // Stream bytes to disk
        while true {
            if isCancelled {
                dataConnection.cancel()
                throw FTPError.cancelled
            }

            let chunk: (Data?, Bool) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
                dataConnection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                    if let error = error {
                        cont.resume(throwing: FTPError.transferFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: (data, isComplete))
                    }
                }
            }

            if let data = chunk.0, !data.isEmpty {
                try writeHandle.write(contentsOf: data)
                progress.completedUnitCount += Int64(data.count)
                progressHandler?(progress)
            }

            if chunk.1 { break } // server closed data connection
            if chunk.0 == nil && !chunk.1 { break }
        }

        // Close data connection and read final status
        dataConnection.cancel()
        let final = try await readResponse()
        guard final.hasPrefix("226") else {
            throw FTPError.transferFailed("Download failed: \(final)")
        }
    }

    /// Downloads a remote file into memory and returns it as `Data`.
    /// - Parameters:
    ///   - remoteFileName: The name/path of the file on the FTP server (relative to current remote directory).
    ///   - progressHandler: Optional handler for incremental progress updates.
    /// - Returns: The downloaded bytes.
    public func downloadData(
        remoteFileName: String,
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> Data {
        // Ensure we're connected
        if controlConnection == nil { try await connect() }

        // Switch to binary mode
        try? await sendCommand("TYPE I")
        _ = try? await readResponse()

        // Try to fetch total size
        var totalSize: Int64 = 0
        var hasTotal = false
        do {
            try await sendCommand("SIZE \(remoteFileName)")
            let sizeResp = try await readResponse()
            if sizeResp.hasPrefix("213"),
               let last = sizeResp.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first,
               let sizeStr = last.split(separator: " ").last,
               let sz = Int64(sizeStr) {
                totalSize = sz
                hasTotal = true
            }
        } catch {
            // Ignore SIZE errors
        }

        let progress = Progress(totalUnitCount: hasTotal ? totalSize : 0)
        progressHandler?(progress)

        // Open passive data connection and request file
        let dataConnection = try await enterPassiveModeAndOpenDataConnection()
        try await sendCommand("RETR \(remoteFileName)")
        let retrResp = try await readResponse()
        guard retrResp.hasPrefix("150") else {
            dataConnection.cancel()
            throw FTPError.transferFailed("Failed to initiate download: \(retrResp)")
        }

        var buffer = Data()
        while true {
            if isCancelled {
                dataConnection.cancel()
                throw FTPError.cancelled
            }

            let chunk: (Data?, Bool) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
                dataConnection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                    if let error = error {
                        cont.resume(throwing: FTPError.transferFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: (data, isComplete))
                    }
                }
            }

            if let data = chunk.0, !data.isEmpty {
                buffer.append(data)
                progress.completedUnitCount += Int64(data.count)
                progressHandler?(progress)
            }

            if chunk.1 { break }
            if chunk.0 == nil && !chunk.1 { break }
        }

        dataConnection.cancel()
        let final = try await readResponse()
        guard final.hasPrefix("226") else {
            throw FTPError.transferFailed("Download failed: \(final)")
        }

        return buffer
    }

    private func enterPassiveModeAndOpenDataConnection() async throws -> NWConnection {
        try await sendCommand("PASV")
        let pasvResponse = try await readResponse()

        // Parse PASV response
        let pattern = "\\((.*?)\\)"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: pasvResponse, range: NSRange(pasvResponse.startIndex..., in: pasvResponse)) else {
            throw FTPError.other("Failed to parse PASV response: \(pasvResponse)")
        }
        let range = Range(match.range(at: 1), in: pasvResponse)!
        let numbersString = pasvResponse[range]
        let numbers = numbersString.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else {
            throw FTPError.other("Invalid PASV response format: \(pasvResponse)")
        }
        let host = "\(numbers[0]).\(numbers[1]).\(numbers[2]).\(numbers[3])"
        let port = (numbers[4] << 8) + numbers[5]

        let dataConnection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        try await withSafeStateHandler { completion in
            dataConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion(.success(()))
                case .failed(let error):
                    completion(.failure(FTPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    completion(.failure(FTPError.cancelled))
                default:
                    break
                }
            }
            dataConnection.start(queue: .global())
        }

        return dataConnection
    }

    private func sendData(data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: FTPError.transferFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }))
        }
    }

    /// Verifies the connection to the FTP server.
    /// This method attempts to connect to the server, authenticate, and then disconnect.
    /// - Returns: A boolean indicating whether the connection was successful.
    /// - Throws: An `FTPError` if the connection or authentication fails.
    public func verifyConnection() async throws -> Bool {
        do {
            try await connect()
            await disconnect()
            return true
        } catch {
            throw error
        }
    }

    private func disconnect() async {
        controlConnection?.cancel()
        controlConnection = nil
    }

    private actor SafeCompletionHandler<T> {
        private var hasCompleted = false

        func complete(with result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
            guard !hasCompleted else { return }
            hasCompleted = true
            continuation.resume(with: result)
        }
    }

    private func withSafeStateHandler<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let safeHandler = SafeCompletionHandler<T>()
            operation { result in
                Task {
                    await safeHandler.complete(with: result, continuation: continuation)
                }
            }
        }
    }

    public func listDirectory(path: String? = nil) async throws -> [FTPEntry] {
        // Connect if needed
        if controlConnection == nil {
            try await connect()
        }

        // Optionally change directory
        if let path = path {
            try await sendCommand("CWD \(path)")
            let cwdResp = try await readResponse()
            guard cwdResp.hasPrefix("250") else { throw FTPError.other("CWD failed: \(cwdResp)") }
        }

        // Open passive data connection
        let dataConnection = try await enterPassiveModeAndOpenDataConnection()

        // Prefer machine-readable MLSD; if it fails, fall back to LIST
        try await sendCommand("MLSD")
        var resp = try await readResponse()
        var usedCommand = "MLSD"
        if !resp.hasPrefix("150") { // 150 Opening data connection
            // Some servers don’t support MLSD; try LIST
            try await sendCommand("LIST")
            resp = try await readResponse()
            guard resp.hasPrefix("150") else { throw FTPError.other("Directory list not supported: \(resp)") }
            usedCommand = "LIST"
        }

        // Read all bytes from data socket
        let data = try await readAllData(from: dataConnection)
        dataConnection.cancel()

        // Final status from control channel (226 = transfer complete)
        let final = try await readResponse()
        guard final.hasPrefix("226") else { throw FTPError.other("LIST failed: \(final)") }

        // Parse
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if usedCommand == "MLSD" {
            return parseMLSD(lines: lines)
        } else {
            return parseLIST(lines: lines)
        }
    }

    // MARK: - Helpers

    private func readAllData(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk: (Data?, Bool) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                    if let error = error {
                        cont.resume(throwing: FTPError.transferFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: (data, isComplete))
                    }
                }
            }
            if let data = chunk.0 { buffer.append(data) }
            if chunk.1 { break } // server closed data connection
            if chunk.0 == nil && !chunk.1 { break }
        }
        return buffer
    }

    private func parseMLSD(lines: [String]) -> [FTPEntry] {
        var entries: [FTPEntry] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmmss"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        for line in lines {
            // format: "type=file;size=123;modify=20250101123456; ... filename"
            guard let space = line.firstIndex(of: " ") else { continue }
            let factsPart = line[..<space]
            let name = line[line.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var facts: [String: String] = [:]
            for fact in factsPart.split(separator: ";") {
                if fact.isEmpty { continue }
                let kv = fact.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { facts[kv[0].lowercased()] = kv[1] }
            }
            let isDir = facts["type"] == "dir" || facts["type"] == "cdir" || facts["type"] == "pdir"
            let size: Int64? = facts["size"].flatMap(Int64.init)
            let modified: Date? = facts["modify"].flatMap { dateFormatter.date(from: $0) }
            if facts["type"] != "pdir" && facts["type"] != "cdir" { // skip . and ..
                entries.append(FTPEntry(name: name, isDirectory: isDir, size: size, modified: modified))
            }
        }
        return entries
    }

    private func parseLIST(lines: [String]) -> [FTPEntry] {
        // Very basic Unix LIST parser, best-effort only
        var entries: [FTPEntry] = []
        for line in lines {
            // e.g., "drwxr-xr-x  2 user group     4096 Jan  1 12:00 dirname"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perms = String(parts[0])
            let isDir = perms.first == "d"
            let size = Int64(parts[4])
            // filename starts after the date fields (usually at index >= 8)
            let name = parts.dropFirst(8).joined(separator: " ")
            entries.append(FTPEntry(name: name, isDirectory: isDir, size: size, modified: nil))
        }
        return entries
    }
}
