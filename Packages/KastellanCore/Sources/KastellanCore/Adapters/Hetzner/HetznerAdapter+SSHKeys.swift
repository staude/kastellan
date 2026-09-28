import Foundation

// SSH-Keys über die Hetzner Cloud API (`/ssh_keys`). Hetzner kennt keine SSH-Benutzer, nur
// benannte öffentliche Schlüssel je Projekt. Ein `SSHUser` entspricht einem Key: `username`
// ist der Name bei Hetzner, `public_keys` enthält genau diesen Schlüssel.

extension HetznerAdapter: SSHUserAdapter {
    public func listSSHUsers() async throws -> [SSHUser] {
        try await client.list("/ssh_keys", key: "ssh_keys").map { sshUser($0) }
    }

    /// Legt je Schlüssel einen Eintrag an. Ohne Namen heißt der erste `kastellan-<Datum>`,
    /// weitere bekommen `-2`, `-3` angehängt. Zurück kommt der erste, die übrigen Namen stehen
    /// in `extra["also_created"]`.
    public func createSSHUser(username: String?, publicKeys: [String]) async throws -> SSHUser {
        let keys = publicKeys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { throw KastellanError.invalidArgument("public_keys ist leer") }
        let base = (username?.isEmpty == false) ? username! : Self.defaultKeyName()

        var created: [SSHUser] = []
        for (index, key) in keys.enumerated() {
            let name = index == 0 ? base : "\(base)-\(index + 1)"
            let response = try await client.post("/ssh_keys", body: .object(["name": .string(name), "public_key": .string(key)]))
            guard let item = response["ssh_key"] else {
                throw KastellanError.provider("Hetzner: Antwort auf POST /ssh_keys enthält keinen ssh_key")
            }
            created.append(sshUser(item))
        }
        var first = created[0]
        if created.count > 1 {
            first.extra["also_created"] = .array(created.dropFirst().map { .string($0.username) })
        }
        return first
    }

    public func deleteSSHUser(username: String) async throws {
        guard !username.isEmpty else { throw KastellanError.invalidArgument("username ist leer") }
        let matches = try await client.get("/ssh_keys", query: [("name", username)]).array("ssh_keys")
        guard let id = matches.first?.int("id") else {
            throw KastellanError.notFound("SSH-Key \(username)")
        }
        try await client.delete("/ssh_keys/\(id)")
    }

    // MARK: - Mapping

    func sshUser(_ item: JSONValue) -> SSHUser {
        var extra = Self.extra(from: item, keys: ["fingerprint", "labels", "created"])
        if let id = item.int("id") { extra["id"] = .int(id) }
        return SSHUser(ref: ref(String(item.int("id") ?? 0)),
                       username: item.string("name") ?? "",
                       publicKeys: [item.string("public_key")].compactMap { $0 },
                       extra: extra)
    }

    /// `kastellan-20260906`
    static func defaultKeyName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return "kastellan-" + f.string(from: date)
    }
}
