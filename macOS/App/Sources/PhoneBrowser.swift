//
//  PhoneBrowser.swift
//  iCam (Mac)
//
//  Finds iPhones running iCam on the local network (and over peer-to-peer
//  Wi-Fi, so a shared network isn't even required).
//

import Foundation
import Network
import os

struct BonjourPhone: Hashable {
    var name: String
    var deviceID: String?
    var endpoint: NWEndpoint
}

final class PhoneBrowser {
    /// Main queue.
    var onChange: (([BonjourPhone]) -> Void)?
    /// Main queue. Non-nil when browsing is blocked (e.g. Local Network
    /// permission denied).
    var onProblem: ((String?) -> Void)?

    private let log = Logger(subsystem: "app.icam.mac", category: "bonjour")
    private var browser: NWBrowser?

    func start() {
        browser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ICam.bonjourServiceType, domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onProblem?(nil)
            case .waiting(let error):
                self.log.notice("Browser waiting: \(error.localizedDescription, privacy: .public)")
                self.onProblem?(error.localizedDescription)
            case .failed(let error):
                self.log.error("Browser failed: \(error.localizedDescription, privacy: .public)")
                self.onProblem?(error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var byName: [String: (phone: BonjourPhone, peerToPeerOnly: Bool)] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var deviceID: String?
            if case let .bonjour(txt) = result.metadata {
                deviceID = txt["id"]
            }
            let peerToPeerOnly = !result.interfaces.isEmpty
                && result.interfaces.allSatisfy { $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw") }
            let phone = BonjourPhone(name: name, deviceID: deviceID, endpoint: result.endpoint)
            // Prefer the result reachable over the regular network.
            if let existing = byName[name], !existing.peerToPeerOnly, peerToPeerOnly { continue }
            byName[name] = (phone, peerToPeerOnly)
        }
        let phones = byName.values.map(\.phone).sorted { $0.name < $1.name }
        onChange?(phones)
    }
}
