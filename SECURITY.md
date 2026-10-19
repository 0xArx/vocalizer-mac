# Security

## Reporting a problem

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/0xArx/vocalizer-mac/security/advisories/new)
rather than a public issue. Include the Vocalizer version (right-click the menu bar icon) and your macOS version.

## How releases are protected

- **Code signing:** every release is signed with an Apple Developer ID and notarized by Apple.
- **Updates:** Vocalizer updates itself with [Sparkle](https://sparkle-project.org). Each update must carry an EdDSA
  signature that matches the public key built into the app, and the same Developer ID as the installed app.
  Updates that fail either check are refused.
- **Keys:** the update signing key, the Developer ID certificate and the notarization key are kept offline on the
  maintainer's Mac and never in this repository.
- **Transparency:** the project is open source. Every release is listed on the
  [releases page](https://github.com/0xArx/vocalizer-mac/releases) with its changes.

## What Vocalizer can access

Vocalizer needs one macOS permission, **System Audio Recording**, to hear what your Mac plays. Audio is processed in
memory on your Mac and is never recorded, stored or sent anywhere. The app only contacts `vocalizer-mac.vercel.app`
(the update list) and `github.com` (downloads). More detail: [README › Updates and security](README.md#updates-and-security).
