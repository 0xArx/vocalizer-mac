// Checks GitHub for a newer release once a day; "Update" runs the same one-line installer as the README.
import Foundation

@MainActor
final class Updater: ObservableObject {
    static let repo = "0xArx/vocalizer-mac"
    @Published private(set) var latest: String?
    @Published private(set) var updating = false
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var updateAvailable: Bool { latest.map { Self.isNewer($0, than: current) } ?? false }

    func checkSoon() {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else {
            latest = UserDefaults.standard.string(forKey: "latestVersion"); return
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                UserDefaults.standard.set(version, forKey: "latestVersion")
                self.latest = version
            }
        }.resume()
    }

    /// Runs install.sh detached: it quits this app (which restores the speakers), installs, and reopens it.
    func update() {
        updating = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "curl -fsSL https://raw.githubusercontent.com/\(Self.repo)/main/install.sh | bash > /tmp/vocalizer-update.log 2>&1"]
        do { try p.run() } catch { updating = false }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
