import Foundation

enum DefaultAccountNames {
    static let all = [
        "Turing", "Shannon", "Neumann", "Dijkstra", "Knuth", "Hopper", "Ritchie", "Thompson", "Torvalds", "Berners-Lee",
        "Cerf", "Kahn", "Lamport", "Codd", "McCarthy", "Minsky", "Kay", "Engelbart", "Wirth", "Hoare",
        "Diffie", "Hellman", "Rivest", "Shamir", "Adleman", "Hinton", "Bengio", "LeCun", "Sutskever", "Vaswani",
        "Shazeer", "Devlin", "Radford", "Brown", "Kaplan", "Hoffmann", "Amodei", "Silver", "Ng", "Li",
        "Dean", "Mikolov", "Bahdanau", "Cho", "Goodfellow", "Salakhutdinov", "Raffel", "Lewis", "Bommasani", "Wei",
        "Miyamoto", "Kojima", "Miyazaki", "Sakurai", "Aonuma", "Iwata", "Molyneux", "Wright", "Meier", "Carmack",
        "Romero", "Newell", "Howard", "Druckmann", "Houser", "Garriott", "Sweeney", "Bleszinski", "Mizuguchi", "Kamiya",
        "Inafune", "Yamauchi", "Mikami", "Yoshida", "Yoko", "Nomura", "Kitase", "Schafer", "Gilbert", "Fares",
        "Kare", "Atkinson", "Ive", "Dye", "Ording", "Chaudhri", "Forstall", "Christie", "Hertzfeld", "Tesler",
        "Horn", "Capps", "Brunner", "Esslinger", "Howarth", "Hankey", "Stringer", "Fadell", "Rubinstein", "Serlet"
    ]

    static func apply(to snapshots: inout [Snapshot], defaults: UserDefaults = .standard) {
        var assignments = defaults.dictionary(forKey: "defaultAliasAssignments") as? [String: String] ?? [:]
        let accountIDs = Set(snapshots.flatMap(\.accounts).map(\.id))
        let used = Set(assignments.filter { accountIDs.contains($0.key) }.map(\.value))
        var available = all.filter { !used.contains($0) }.shuffled()

        for snapshotIndex in snapshots.indices {
            for accountIndex in snapshots[snapshotIndex].accounts.indices {
                let account = snapshots[snapshotIndex].accounts[accountIndex]
                guard account.alias?.isEmpty != false else { continue }
                if assignments[account.id] == nil, let name = available.popLast() {
                    assignments[account.id] = name
                }
                snapshots[snapshotIndex].accounts[accountIndex].alias = assignments[account.id]
            }
        }
        defaults.set(assignments, forKey: "defaultAliasAssignments")
    }
}
