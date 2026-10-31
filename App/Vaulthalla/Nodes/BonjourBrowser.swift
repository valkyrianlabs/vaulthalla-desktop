import Foundation
import Observation
import VHCore
import VHNodes

/// The Add Node sheet's view of Vaulthalla servers on the local network: VaulthallaKit's `BonjourServiceBrowser`
/// (which also feeds the endpoint selector's last source), observed on the main actor.
@Observable
final class BonjourBrowser {
    typealias Status = BonjourServiceBrowser.Status

    private(set) var status: Status = .idle
    private(set) var servers: [DiscoveredServer] = []

    @ObservationIgnored private var browser: BonjourServiceBrowser?

    func start() {
        guard browser == nil else { return }
        let made = BonjourServiceBrowser()
        browser = made
        status = .browsing
        made.start { [weak self] servers, status in
            Task { @MainActor in
                guard let self, self.browser === made else { return }
                self.servers = servers
                self.status = status
            }
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
        servers = []
        status = .idle
    }
}
