import AppKit
import Observation
import Security
import TesseraCore

/// Free trial and license keys (Dodo Payments' public license endpoints; no API key in the app).
///
/// Switched off unless `TesseraCheckoutURL` and `TesseraLicenseAPI` are set at build time.
@MainActor
@Observable
final class LicenseManager {
    static let shared = LicenseManager()

    private(set) var licenseKey: String?
    private(set) var instanceID: String?
    private(set) var revoked = false
    private(set) var busy = false
    var lastError: String?

    private let defaults = UserDefaults.standard
    private let service = (Bundle.main.bundleIdentifier ?? "Tessera") + ".license"

    var maskedKey: String? {
        guard let licenseKey else { return nil }
        return String(repeating: "•", count: max(0, licenseKey.count - 4)) + licenseKey.suffix(4)
    }

    // MARK: Start

    func start() {
        if Keychain.read(service: service, account: "firstLaunch") == nil {
            let stamp = String(Date().timeIntervalSince1970)
            Keychain.write(stamp, service: service, account: "firstLaunch")
        }
        licenseKey = Keychain.read(service: service, account: "key")
        instanceID = Keychain.read(service: service, account: "instance")
        revoked = defaults.bool(forKey: "licenseRevoked")
        recompute()
        if AppConfig.licensingEnabled, licenseKey != nil {
            Task { await validate() }
        }
    }

    private var firstLaunch: Date {
        let stamp = Keychain.read(service: service, account: "firstLaunch").flatMap(Double.init) ?? Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: stamp)
    }

    func recompute() {
        var state = LicenseState.compute(
            licensingEnabled: AppConfig.licensingEnabled,
            firstLaunch: firstLaunch,
            now: Date(),
            trialLength: AppConfig.trialLength,
            hasActiveKey: licenseKey != nil && instanceID != nil,
            keyRevoked: revoked
        )
        // Whole hours only, so the UI doesn't redraw every poll.
        if case .trial(let remaining) = state {
            state = .trial(remaining: (remaining / 3600).rounded(.up) * 3600)
        }
        let old = AppModel.shared.licenseState
        guard old != state else { return }
        AppModel.shared.licenseState = state
        if old.canTile != state.canTile || old.hasFullVersion != state.hasFullVersion {
            TilingController.shared.statusChanged()
        }
    }

    // MARK: Actions

    func buy() {
        if let url = AppConfig.checkoutURL { NSWorkspace.shared.open(url) }
    }

    /// Activates a key on this Mac.
    func activate(key rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        busy = true
        defer { busy = false }
        lastError = nil
        let name = Host.current().localizedName ?? "Mac"
        switch await post("licenses/activate", ["license_key": key, "name": name]) {
        case .success(let (status, json)):
            switch status {
            case 200..<300:
                guard let id = json?["id"] as? String else {
                    lastError = L("The license server sent an unexpected reply.")
                    return false
                }
                Keychain.write(key, service: service, account: "key")
                Keychain.write(id, service: service, account: "instance")
                licenseKey = key
                instanceID = id
                revoked = false
                defaults.set(false, forKey: "licenseRevoked")
                recompute()
                return true
            case 403: lastError = L("This key isn't active. It may have been refunded.")
            case 404: lastError = L("We couldn't find that key. Check it and try again.")
            case 422: lastError = L("This key is already active on another Mac. Deactivate it there first.")
            default: lastError = L("Activation failed (error %ld).", status)
            }
        case .failure:
            lastError = L("Couldn't reach the license server. Check your connection.")
        }
        return false
    }

    /// Frees this Mac's activation so the key can move to another Mac.
    func deactivate() async {
        guard let key = licenseKey, let instance = instanceID else { return }
        busy = true
        defer { busy = false }
        _ = await post("licenses/deactivate", ["license_key": key, "license_key_instance_id": instance])
        Keychain.delete(service: service, account: "key")
        Keychain.delete(service: service, account: "instance")
        licenseKey = nil
        instanceID = nil
        recompute()
    }

    /// Checks the key is still good (e.g. not refunded). Works offline: network errors change nothing.
    func validate() async {
        guard let key = licenseKey else { return }
        var body: [String: String] = ["license_key": key]
        if let instanceID { body["license_key_instance_id"] = instanceID }
        guard case .success(let (status, json)) = await post("licenses/validate", body) else { return }
        if (200..<300).contains(status), let valid = json?["valid"] as? Bool {
            revoked = !valid
            defaults.set(revoked, forKey: "licenseRevoked")
            recompute()
        }
    }

    // MARK: Networking

    private func post(_ path: String, _ body: [String: String]) async -> Result<(Int, [String: Any]?), Error> {
        guard let base = AppConfig.licenseAPI else { return .failure(URLError(.badURL)) }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .success((status, json))
        } catch {
            return .failure(error)
        }
    }
}

/// Minimal Keychain wrapper for small strings.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
