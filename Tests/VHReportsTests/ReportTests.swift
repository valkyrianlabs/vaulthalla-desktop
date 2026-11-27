import Foundation
import Testing
@testable import VHReports

/// A report's redaction, with seeded secrets (docs/mac-experience.md §8): names, addresses, ids, paths and
/// key-shaped strings are planted in everything a report is built from, and none of those bytes may appear anywhere
/// in what a person would read or send.
@Suite struct ReportTests {
    /// What must never leave the Mac, planted below in names, messages and log lines.
    static let seeded: [String] = [
        "Bifrost-Prod", "Mimir Backup",                        // node names
        "Payroll 2026", "Odin's Ledger",                       // vault names
        "olaf.thorsen", "Freya",                               // users
        "Olaf's MacBook Pro",                                  // a device
        "vault.acme-corp.example", "studio.local", "bifrost.internal",
        "203.0.113.77", "10.0.0.33", "2001:db8:85a3::8a2e:370:7334", "fe80::1c2b:3aff:fe4d:5e6f",
        "olaf@acme-corp.example",
        "3f2b8c1e-9d4a-4f6b-8e2c-7a1d5b9c0e3f", "local-9b1d0c7e-5a3f-4e2d-8c6b-1f0a9e8d7c6b",
        "/Users/olaf/Secret Plans/budget-2026.xlsx", "/srv/vaulthalla/backing/payroll/q3.pdf", "~/Documents/keys/master.pem",
        "vh_tok_9aF3kLm2QpX7vB1nR8sT4uW6yZ0cD5eG",
        "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7",
        "c4293fac1f2924f97ffec5da0d43fe15fccb05f3275b033d295aa78c815dd567",
        "Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc",
    ]

    static let pem = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
    -----END PRIVATE KEY-----
    """

    static func input(note: String? = nil) -> ReportBuilder.Input {
        ReportBuilder.Input(
            subject: .init(kind: .finding, class: "system.storage.degraded_vaults", severity: "warning",
                           card: "system.storage", metric: "vaults", title: "Storage Backend",
                           message: "Vault Payroll 2026 on Bifrost-Prod can't reach s3://acme-bucket/prefix at 203.0.113.77:9000 "
                               + "(user olaf.thorsen, key vh_tok_9aF3kLm2QpX7vB1nR8sT4uW6yZ0cD5eG)."),
            node: .init(name: "Bifrost-Prod", hosts: ["vault.acme-corp.example", "10.0.0.33"],
                        ids: ["3f2b8c1e-9d4a-4f6b-8e2c-7a1d5b9c0e3f", "local-9b1d0c7e-5a3f-4e2d-8c6b-1f0a9e8d7c6b"],
                        version: "1.26.2", protocol: 1, protocolRange: 1...1, routeClass: "vpn", reachability: "online",
                        overallStatus: "warning", errorCount: 0, warningCount: 2, checkedAt: 1_795_700_000,
                        findings: [
                            .init(class: "system.storage.degraded_vaults", severity: "warning", card: "system.storage",
                                  message: "1 vault backend(s) are degraded: Odin's Ledger at /srv/vaulthalla/backing/payroll/q3.pdf"),
                            .init(class: "system.fuse.error_rate_elevated", severity: "warning", card: "system.fuse",
                                  message: "FUSE alertable error rate is above 2%."),
                        ]),
            desktop: .init(version: "0.7.0", build: "1", osVersion: "27.2", arch: "arm64", model: "Mac13,2", nodeCount: 2,
                           linkedToCloud: true, settings: ["menu_bar_item": "on", "open_at_login": "on"]),
            log: [
                "12:30:05 session Bifrost-Prod online via https://vault.acme-corp.example:36972/ws (pin Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc)",
                "12:30:06 fleet: studio.local and bifrost.internal answered; fe80::1c2b:3aff:fe4d:5e6f did not",
                "12:30:07 registry /Users/olaf/Secret Plans/budget-2026.xlsx is not a node list; ~/Documents/keys/master.pem ignored",
                "12:30:08 paired by olaf@acme-corp.example from Olaf's MacBook Pro, device 3f2b8c1e-9d4a-4f6b-8e2c-7a1d5b9c0e3f",
                "12:30:09 route 2001:db8:85a3::8a2e:370:7334 sha c4293fac1f2924f97ffec5da0d43fe15fccb05f3275b033d295aa78c815dd567",
                "12:30:10 other node Mimir Backup, user Freya " + pem,
            ],
            occurrences: .init(count: 3, firstSeen: 1_795_690_000, lastSeen: 1_795_700_000),
            note: note,
            known: .init(nodes: ["Bifrost-Prod", "Mimir Backup"], vaults: ["Payroll 2026", "Odin's Ledger"],
                         users: ["olaf.thorsen", "Freya"], devices: ["Olaf's MacBook Pro"],
                         hosts: ["vault.acme-corp.example"], ids: []))
    }

    @Test func nothingSeededSurvivesAnywhereInTheReport() throws {
        let report = ReportBuilder.build(Self.input(note: "Olaf's MacBook Pro shows this since Payroll 2026 was added."),
                                         id: UUID(uuidString: "0F6C1C0E-6B1E-4D0C-9A52-3F3B6F1F9A10")!,
                                         now: Date(timeIntervalSince1970: 1_795_703_000))
        let sent = String(decoding: try report.encoded(), as: UTF8.self)
        let read = ReportBuilder.summary(of: report, reference: "VHR-7K2M9Q")
        for secret in Self.seeded {
            #expect(!sent.localizedCaseInsensitiveContains(secret), "\(secret) is in the document")
            #expect(!read.localizedCaseInsensitiveContains(secret), "\(secret) is in the summary")
        }
        #expect(!sent.contains("BEGIN PRIVATE KEY"))
        #expect(!sent.contains("acme"))

        // What stays is what a report needs.
        #expect(report.format == "vh-report/1")
        #expect(report.id == "0f6c1c0e-6b1e-4d0c-9a52-3f3b6f1f9a10")
        #expect(report.subject.class == "system.storage.degraded_vaults")
        #expect(report.subject.node == .init(label: "node-1", version: "1.26.2", protocol: 1))
        #expect(report.evidence.map(\.name) == ["finding.json", "node.json", "desktop.json", "log.txt"])
        #expect(sent.contains("system.fuse.error_rate_elevated"))
        #expect(sent.contains("FUSE alertable error rate is above 2%."))
        #expect(sent.contains("\\\"route_class\\\" : \\\"vpn\\\""))
        #expect(report.redaction.rules == "vh-redact/1")
        for kind in ["node", "vault", "user", "device", "host", "address", "email", "install_id", "path", "secret"] {
            #expect((report.redaction.removed[kind] ?? 0) > 0, "nothing counted as \(kind)")
        }
        #expect(read.contains("warning system.storage.degraded_vaults on node-1 (Vaulthalla 1.26.2)"))
        #expect(read.contains("reference VHR-7K2M9Q"))
    }

    @Test func aLabelIsStableWithinOneReport() throws {
        let report = ReportBuilder.build(Self.input())
        let finding = try #require(report.evidence.first { $0.name == "finding.json" }).text
        let log = try #require(report.evidence.first { $0.name == "log.txt" }).text
        // The report's own node is node-1 everywhere; the other node is another label.
        #expect(finding.contains("on node-1 can't reach"))
        #expect(log.contains("session node-1 online via https://host-1"))
        #expect(log.contains("other node node-2"))
        // The same vault, the same label; the same address, the same label.
        #expect(finding.contains("Vault vault-1 on node-1"))
        var redactor = ReportRedactor()
        redactor.know("Payroll 2026", as: .vault)
        let twice = redactor.scrub("Payroll 2026 then payroll 2026 at 10.0.0.33 and 10.0.0.33 and 10.0.0.34")
        #expect(twice == "vault-1 then vault-1 at addr-1 and addr-1 and addr-2")
        #expect(redactor.removed == ["vault": 2, "address": 3])
    }

    @Test func ordinaryTextIsLeftAlone() {
        var redactor = ReportRedactor()
        let plain = [
            "12:30:05 fleet check finished in 0.42 s; 3 of 4 nodes online",
            "stats.dashboard.overview answered error_count=1 warning_count=2 for system.fuse.error_rate_high",
            "Vaulthalla 1.26.2, protocol 1..1, macOS 27.2 on Mac13,2",
            "ratio 3/4 done, see docs/mac-experience.md and report.json",
        ]
        for line in plain {
            #expect(redactor.scrub(line) == line)
        }
        #expect(redactor.removed.isEmpty)
        // One-character names are not names worth shredding words for.
        #expect(redactor.know("a", as: .vault) == nil)
        #expect(redactor.scrub("a vault and a node") == "a vault and a node")
    }

    @Test func aGeneralReportHasNoFindingAndFitsTheLimits() throws {
        var input = Self.input(note: String(repeating: "word ", count: 1000))
        input.subject = .init(kind: .general)
        input.node = nil
        input.log = (0..<20_000).map { "12:30:05 line \($0) of an ordinary log, nothing to see" }
        let report = ReportBuilder.build(input)
        #expect(report.subject.node == nil)
        #expect(report.evidence.map(\.name) == ["desktop.json", "log.txt"])
        #expect((report.note?.count ?? 0) <= ReportDocument.maxNoteLength)
        let log = try #require(report.evidence.last)
        #expect(log.text.utf8.count <= ReportDocument.maxEvidenceBytes)
        #expect(log.text.contains("line 19999"), "the newest lines are the ones kept")
        #expect(try report.encoded().count <= ReportDocument.maxDocumentBytes)
        #expect(report.evidence.count <= ReportDocument.maxEvidenceParts)
    }

    @Test func theDocumentRoundTripsInTheContractsShape() throws {
        let report = ReportBuilder.build(Self.input())
        let data = try report.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactly the members the contract names: the service refuses anything else.
        #expect(Set(object.keys) == ["format", "id", "created_at", "product", "version", "build", "platform", "subject",
                                     "occurrences", "redaction", "evidence"])
        #expect(Set((object["platform"] as? [String: Any] ?? [:]).keys) == ["os", "os_version", "arch", "model"])
        let evidence = try #require((object["evidence"] as? [[String: Any]])?.first)
        #expect(Set(evidence.keys) == ["name", "media_type", "text"])
        #expect(try JSONDecoder().decode(ReportDocument.self, from: data) == report)

        let receipt = try JSONDecoder().decode(ReportReceipt.self, from: Data(
            #"{"id":"6a0c","reference":"VHR-7K2M9Q","received_at":1795703010}"#.utf8))
        #expect(receipt.reference == "VHR-7K2M9Q")
    }

    @Test func theSavedFolderHoldsWhatWasShownAndNothingElse() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vh-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var report = ReportBuilder.build(Self.input())
        report.evidence.append(.init(name: "../escape.txt", mediaType: "text/plain", text: "no"))
        try ReportBuilder.write(report, to: directory, reference: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["desktop.json", "finding.json", "log.txt", "node.json", "report.json", "summary.txt"])
        for name in names {
            let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            for secret in Self.seeded {
                #expect(!text.localizedCaseInsensitiveContains(secret), "\(secret) is in \(name)")
            }
        }
    }
}
