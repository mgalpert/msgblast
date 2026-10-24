import Foundation

/// Sends only the user-authored note and the same opt-in diagnostic preview shown in the form.
public enum FeedbackSubmission {
    public static let productionEndpoint = URL(string: "https://msgblast.app/api/feedback")!
    private static let maximumReceiptBytes = 8192

    public static func send(
        _ request: DiagnosticRequest,
        id: UUID,
        endpoint: URL = productionEndpoint,
        isLocalFixture: Bool = false,
        session: URLSession? = nil
    ) async throws -> FeedbackReceipt {
        try validateEndpoint(endpoint, isLocalFixture: isLocalFixture)
        var upload = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        upload.httpMethod = "POST"
        upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        upload.setValue("msgblast/feedback", forHTTPHeaderField: "User-Agent")
        upload.httpShouldHandleCookies = false
        upload.httpBody = try encodeRequest(request, id: id)
        let transport = session ?? URLSession(configuration: sessionConfiguration())
        defer { if session == nil { transport.invalidateAndCancel() } }
        do {
            let (bytes, response) = try await transport.bytes(for: upload, delegate: RejectFeedbackRedirects())
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw FeedbackSubmissionError.invalidReceipt }
            // Reject status failures before reading a potentially unbounded server error body.
            try validateStatus(http.statusCode)
            guard http.expectedContentLength <= Int64(maximumReceiptBytes) else {
                throw FeedbackSubmissionError.invalidReceipt
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumReceiptBytes else {
                    throw FeedbackSubmissionError.invalidReceipt
                }
                data.append(byte)
            }
            return try receipt(from: data, statusCode: http.statusCode, id: id)
        } catch let error as FeedbackSubmissionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FeedbackSubmissionError.connectionFailed
        }
    }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    public static func validateEndpoint(_ endpoint: URL, isLocalFixture: Bool = false) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path == "/api/feedback" else { throw FeedbackSubmissionError.invalidEndpoint }
        if endpoint == productionEndpoint { return }
        if isLocalFixture, parts.scheme == "http", let host = parts.host,
           ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return }
        throw FeedbackSubmissionError.invalidEndpoint
    }

    public static func encodeRequest(_ request: DiagnosticRequest, id: UUID) throws -> Data {
        guard (request.kind == .crash) == (request.crash != nil) else { throw FeedbackSubmissionError.rejected }
        let package = try DiagnosticReport.make(request)
        // Match the package's control-character removal so the sent note matches the saved note.
        let note = DiagnosticReport.plain(request.note).trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = request.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.utf16.count <= 16_000 else { throw FeedbackSubmissionError.reportTooLarge }
        let data = try JSONEncoder().encode(SubmissionPayload(
            id: id.uuidString,
            kind: request.kind,
            note: note,
            contact: contact.isEmpty ? nil : contact,
            diagnostics: package.diagnosticsPreview, crash: request.crash))
        guard data.count <= 64 * 1024 else { throw FeedbackSubmissionError.reportTooLarge }
        return data
    }

    public static func receipt(from data: Data, statusCode: Int, id: UUID) throws -> FeedbackReceipt {
        try validateStatus(statusCode)
        guard data.count <= maximumReceiptBytes,
              let receipt = try? JSONDecoder().decode(ReceiptPayload.self, from: data),
              UUID(uuidString: receipt.id) == id else { throw FeedbackSubmissionError.invalidReceipt }
        return FeedbackReceipt(id: id)
    }

    private static func validateStatus(_ code: Int) throws {
        switch code {
        case 200, 201: return
        case 400, 413: throw FeedbackSubmissionError.rejected
        case 429: throw FeedbackSubmissionError.rateLimited
        case 300...399: throw FeedbackSubmissionError.redirectRejected
        default: throw FeedbackSubmissionError.unavailable
        }
    }
}

public struct FeedbackReceipt: Sendable, Equatable {
    public let id: UUID
}

public enum FeedbackSubmissionError: LocalizedError, Equatable {
    case invalidEndpoint, invalidReceipt, rejected, reportTooLarge, rateLimited, redirectRejected, unavailable, connectionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The feedback service address is not supported."
        case .invalidReceipt: "The service did not confirm your feedback. Try again with the same note."
        case .rejected: "The service could not accept this report. Check your note and reply email."
        case .reportTooLarge: "Your report is too large. Shorten your note, then try again."
        case .rateLimited: "Too many reports were sent recently. Wait a few minutes, then try again."
        case .redirectRejected: "The feedback service changed address. Your report was not forwarded."
        case .unavailable: "The feedback service is temporarily unavailable. Try again later."
        case .connectionFailed: "Could not connect to the feedback service. Check your connection and try again."
        }
    }
}

private struct SubmissionPayload: Encodable {
    let id: String
    let kind: DiagnosticReportKind
    let note: String
    let contact: String?
    let diagnostics: String?
    let crash: CrashReport?
}

private struct ReceiptPayload: Decodable {
    let id: String
}

private final class RejectFeedbackRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
