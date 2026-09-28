import Foundation

// Client für die All-Inkl KAS-API. Hält die Session (CredentialToken aus `KasAuth`), führt
// Aufrufe strikt nacheinander aus, wartet den `KasFloodDelay` jeder Antwort ab und versucht es
// bei `flood_protection` einmal erneut. Passwort und Token werden nie geloggt.

public actor KASClient {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias PasswordProvider = @Sendable () async throws -> String

    /// Wartezeit nach einem `flood_protection`-Fault vor dem zweiten Versuch.
    public static let floodRetryDelay: Duration = .seconds(2)

    public let login: String
    private let passwordProvider: PasswordProvider
    private let transport: any KASTransport
    private let sleep: Sleep
    private let sessionLifetime: Int

    private var token: String?
    /// Sekunden, die vor dem nächsten Aufruf zu warten sind (aus der letzten Antwort).
    private var pendingDelay: Double = 0

    // Serialisierung: Actor-Methoden sind an `await` reentrant, deshalb eine eigene Warteschlange.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(login: String,
                passwordProvider: @escaping PasswordProvider,
                transport: any KASTransport = URLSessionKASTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                sessionLifetime: Int = 1800) {
        self.login = login
        self.passwordProvider = passwordProvider
        self.transport = transport
        self.sleep = sleep
        self.sessionLifetime = sessionLifetime
    }

    public init(login: String, password: String,
                transport: any KASTransport = URLSessionKASTransport(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                sessionLifetime: Int = 1800) {
        self.init(login: login, passwordProvider: { password }, transport: transport, sleep: sleep, sessionLifetime: sessionLifetime)
    }

    public var hasSession: Bool { token != nil }

    /// Vergisst den Token; der nächste Aufruf meldet sich neu an.
    public func resetSession() {
        token = nil
    }

    /// Führt eine `KasApi`-Aktion aus. Wirft `KASFault` bei SOAP-Faults, sonst `KastellanError`.
    public func call(_ action: String, params: [String: String] = [:]) async throws -> KASAPIResponse {
        await acquire()
        defer { release() }
        return try await perform(action, params: params, floodRetry: true, reauth: true)
    }

    /// Wie `call`, liefert nur `ReturnInfo`.
    public func returnInfo(_ action: String, params: [String: String] = [:]) async throws -> KASValue {
        try await call(action, params: params).returnInfo
    }

    // MARK: - Intern

    private func perform(_ action: String, params: [String: String], floodRetry: Bool, reauth: Bool) async throws -> KASAPIResponse {
        if pendingDelay > 0 {
            let delay = pendingDelay
            pendingDelay = 0
            try await sleep(.seconds(delay))
        }
        let token = try await ensureToken()
        let body = try KASEnvelope.api(login: login, token: token, action: action, params: params)
        let data = try await transport.post(url: KASEnvelope.apiURL, soapAction: KASEnvelope.apiSOAPAction, body: body)
        do {
            let response = try KASResponseParser.parseAPI(data)
            pendingDelay = response.floodDelay
            return response
        } catch let fault as KASFault {
            if fault.isFloodProtection, floodRetry {
                try await sleep(Self.floodRetryDelay)
                return try await perform(action, params: params, floodRetry: false, reauth: reauth)
            }
            if fault.isSessionInvalid, reauth {
                self.token = nil
                return try await perform(action, params: params, floodRetry: floodRetry, reauth: false)
            }
            throw fault
        }
    }

    private func ensureToken() async throws -> String {
        if let token { return token }
        let password = try await passwordProvider()
        let body = try KASEnvelope.auth(login: login, password: password, sessionLifetime: sessionLifetime)
        let data = try await transport.post(url: KASEnvelope.authURL, soapAction: KASEnvelope.authSOAPAction, body: body)
        let fresh = try KASResponseParser.parseAuth(data)
        token = fresh
        return fresh
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
