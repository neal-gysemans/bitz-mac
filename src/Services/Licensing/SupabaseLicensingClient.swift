import Foundation

/// Supabase REST client implementing the temporary Beta licensing lifecycle.
public final class SupabaseLicensingClient: LicensingBackendClient, Sendable {
    public let projectRef: String
    public let apiKey: String
    public let baseURL: URL
    private let urlSession: URLSession

    public init(
        projectRef: String = "bcmfoamykkptvycvmrqr",
        apiKey: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJjbWZvYW15a2twdHZ5Y3ZtcnFyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQzMjI0NzgsImV4cCI6MjEwOTg5ODQ3OH0.LymDkJGEcoBO0FdP6J573tQ_A7Wnfp3OKny6H2XBK58",
        urlSession: URLSession = .shared
    ) {
        self.projectRef = projectRef
        self.apiKey = apiKey
        self.baseURL = URL(string: "https://\(projectRef).supabase.co/rest/v1/rpc")!
        self.urlSession = urlSession
    }

    public func activateBeta(
        deviceId: String,
        deviceName: String,
        customerEmail: String? = nil
    ) async throws -> RemoteLicenseResult {
        let body: [String: Any?] = [
            "p_device_id": deviceId,
            "p_device_name": deviceName,
            "p_customer_email": customerEmail
        ]
        return try await executeRPC(name: "activate_beta_license", body: body)
    }

    public func validate(
        licenseKey: String,
        deviceId: String
    ) async throws -> RemoteLicenseResult {
        let body: [String: Any] = [
            "p_license_key": licenseKey,
            "p_device_id": deviceId
        ]
        return try await executeRPC(name: "validate_license", body: body)
    }

    public func registerEmail(
        licenseKey: String,
        customerEmail: String
    ) async throws -> RemoteEmailResult {
        let body: [String: Any] = [
            "p_license_key": licenseKey,
            "p_customer_email": customerEmail
        ]
        return try await executeRPC(name: "register_beta_email", body: body)
    }

    public func deactivate(
        licenseKey: String,
        deviceId: String
    ) async throws -> RemoteDeactivateResult {
        let body: [String: Any] = [
            "p_license_key": licenseKey,
            "p_device_id": deviceId
        ]
        return try await executeRPC(name: "deactivate_license", body: body)
    }

    // MARK: - Private RPC Execution

    private func executeRPC<T: Decodable>(name: String, body: [String: Any?]) async throws -> T {
        let endpointURL = baseURL.appendingPathComponent(name)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let nonNullBody = body.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: nonNullBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicensingError.storageFailed("Invalid HTTP response from licensing backend")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let serverError = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw LicensingError.storageFailed("Backend error (\(httpResponse.statusCode)): \(serverError)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
