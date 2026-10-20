// Installs a verified update by swapping the whole app, without an admin password.
//
// Why not Sparkle's installer: macOS App Management blocks writing *inside* a notarized app, even by the app
// itself. Sparkle checks exactly that, decides it needs an administrator, and so it can't install silently and
// asks for a password when you click Install. Renaming the whole bundle in its (writable) folder is allowed,
// so we do that instead, with the same checks Sparkle would make:
//   1. the download's EdDSA signature must match SUPublicEDKey (the key built into this app);
//   2. the new app must be signed by our Developer ID team, with our bundle identifier;
//   3. it must be a newer build.
// If anything fails, the caller falls back to Sparkle's own window.
import AppKit
import CryptoKit
import Security
import Sparkle

enum SelfInstaller {
    struct Prepared {
        let newApp: URL
        let staging: URL
        let version: String
    }

    enum Failure: LocalizedError {
        case missing(String), download, signature, unpack, codeSignature(OSStatus), notNewer
        var errorDescription: String? {
            switch self {
            case .missing(let what): "update is missing its \(what)"
            case .download: "download failed"
            case .signature: "update signature doesn't match Vocalizer's key"
            case .unpack: "couldn't unpack the update"
            case .codeSignature(let s): "new app isn't signed by Vocalizer's developer (\(s))"
            case .notNewer: "update isn't newer than this version"
            }
        }
    }

    static let team = "VP9VT747BA"

    /// Downloads, verifies and unpacks the update next to the running app. Nothing is replaced yet.
    static func prepare(_ item: SUAppcastItem) async throws -> Prepared {
        guard let url = item.fileURL else { throw Failure.missing("download address") }
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any]
        guard let sigText = enclosure?["sparkle:edSignature"] as? String, let signature = Data(base64Encoded: sigText),
              let keyText = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw Failure.missing("signature")
        }

        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = try Data(contentsOf: file, options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: archive) else { throw Failure.signature }

        // Unpack into a hidden folder beside the app, so the final swap is a rename on the same disk.
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".Vocalizer-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        // The download holds one app (normally Vocalizer.app; the installed copy may have been renamed).
        let apps = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard unzip.terminationStatus == 0, apps.count == 1, let newApp = apps.first else {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.unpack
        }

        do {
            try checkCodeSignature(newApp)
            let newBuild = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            guard (Int(newBuild) ?? 0) > (Int(currentBuild) ?? 0) else { throw Failure.notNewer }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return Prepared(newApp: newApp, staging: staging, version: item.displayVersionString)
    }

    /// Valid Developer ID signature from our team, with our bundle identifier.
    private static func checkCodeSignature(_ app: URL) throws {
        let id = Bundle.main.bundleIdentifier ?? "com.0xarx.vocalizer-mac"
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure.codeSignature(status) }
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw Failure.codeSignature(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement)
        guard status == errSecSuccess else { throw Failure.codeSignature(status) }
    }

    /// Swaps the new app into place, moves the old one to the Bin, and reopens. Does not return on success.
    static func install(_ prepared: Prepared) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let old = prepared.staging.appendingPathComponent("previous-\(current.lastPathComponent)")
        try fm.moveItem(at: current, to: old)
        do {
            try fm.moveItem(at: prepared.newApp, to: current)
        } catch {
            try? fm.moveItem(at: old, to: current) // put the old version back
            throw error
        }
        try? fm.trashItem(at: old, resultingItemURL: nil)
        try? fm.removeItem(at: prepared.staging)

        // Reopen the new version once this one has quit (and given the speakers back).
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", current.path]
        try? relaunch.run()
        NSLog("Vocalizer update: installed %@, reopening", prepared.version)
        NSApp.terminate(nil)
    }

    /// Removes any half-finished update folders left beside the app (e.g. after a crash).
    static func cleanUpLeftovers() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in items where name.hasPrefix(".Vocalizer-update-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
