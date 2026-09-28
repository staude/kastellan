import Foundation

// Unterkonten bei Mittwald sind Einladungen und Mitgliedschaften. `POST /projects/{id}/invites
// {mailAddress, role owner|emailadmin|external, message?, membershipExpiresAt?}` lädt per Mail
// ein; ein Passwort gibt es nicht (die Person hat einen eigenen mStudio-Zugang). Organisationsebene
// über `extra.customer_id` mit Rollen owner|member|accountant. Löschen entfernt eine offene
// Einladung oder die Mitgliedschaft.

extension MittwaldAdapter {
    static let projectRoles = ["owner", "emailadmin", "external"]
    static let customerRoles = ["owner", "member", "accountant"]

    public func createSubaccount(password: String, comment: String?, extra: Extra) async throws -> Subaccount {
        guard let mail = extra["mail_address"]?.stringValue ?? extra["email"]?.stringValue, mail.contains("@") else {
            throw KastellanError.invalidArgument("Mittwald: Einladung braucht extra.mail_address; ein Passwort gibt es nicht, die Person nutzt ihren eigenen mStudio-Zugang")
        }
        let role = extra["role"]?.stringValue ?? "external"
        var body: [String: JSONValue] = ["mailAddress": .string(mail), "role": .string(role)]
        if let message = extra["message"]?.stringValue ?? comment { body["message"] = .string(message) }
        if let expires = extra["expires_at"]?.stringValue { body["membershipExpiresAt"] = .string(expires) }

        let created: JSONValue
        var extraOut: Extra = ["kind": .string("invite"), "role": .string(role), "mailAddress": .string(mail)]
        if let customer = extra["customer_id"]?.stringValue, !customer.isEmpty {
            guard Self.customerRoles.contains(role) else { throw KastellanError.invalidArgument("Rolle für Organisationen: \(Self.customerRoles.joined(separator: ", "))") }
            created = try await client.post("/customers/\(customer)/invites", body: .object(body))
            extraOut["customer_id"] = .string(customer)
        } else {
            guard Self.projectRoles.contains(role) else { throw KastellanError.invalidArgument("Rolle für Projekte: \(Self.projectRoles.joined(separator: ", "))") }
            let project = try await projectID(extra)
            created = try await client.post("/projects/\(project)/invites", body: .object(body))
            extraOut["projectId"] = .string(project)
        }
        if let expires = body["membershipExpiresAt"] { extraOut["membershipExpiresAt"] = expires }
        extraOut["note"] = .string("Einladung per Mail verschickt; das übergebene Passwort wurde nicht verwendet.")
        return Subaccount(ref: ref(created.string("id") ?? ""), login: mail, comment: "Einladung offen, Rolle \(role)", extra: extraOut)
    }

    public func deleteSubaccount(login: String) async throws {
        let mail = login.lowercased()
        for pid in try await projectIDs() {
            if let invite = try await client.list("/projects/\(pid)/invites").first(where: { $0.string("mailAddress")?.lowercased() == mail }), let id = invite.string("id") {
                try await client.delete("/project-invites/\(id)")
                return
            }
            if let member = try await client.list("/projects/\(pid)/memberships").first(where: { $0.string("email")?.lowercased() == mail }), let id = member.string("id") {
                if member.bool("inherited") == true {
                    throw KastellanError.invalidArgument("Mittwald: \(login) ist über die Organisation berechtigt; Mitgliedschaft dort entfernen")
                }
                try await client.delete("/project-memberships/\(id)")
                return
            }
        }
        throw KastellanError.notFound("Einladung oder Mitgliedschaft \(login) bei Mittwald")
    }
}
