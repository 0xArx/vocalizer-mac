# Security

## Reporting a problem

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/0xArx/vocalizer-mac/security/advisories/new)
rather than a public issue. Include the Vocalizer version (right-click the menu bar icon) and your macOS version.

## How releases are protected

- **Code signing:** every release is signed with an Apple Developer ID and notarized by Apple.
- **Updates:** Vocalizer uses [Sparkle](https://sparkle-project.org) and asks before installing (automatic installing
  is an opt-in setting). Each update must carry an EdDSA
  signature that matches the public key built into the app, and the same Developer ID as the installed app.
  Updates that fail either check are refused.
- **Keys:** the update signing key, the Developer ID certificate and the notarization key are kept offline on the
  maintainer's Mac and never in this repository.
- **Transparency:** the project is open source. Every release is listed on the
  [releases page](https://github.com/0xArx/vocalizer-mac/releases) with its changes.

## Who can change Vocalizer

Open source means anyone can **read** the code, copy it, and suggest changes. It does not mean anyone can change
this project:
- Only the maintainer's GitHub account can push to this repository or publish releases. Anyone else can only open a
  pull request, which does nothing until the maintainer reviews and merges it.
- Even someone who managed to push code here couldn't ship it to your Mac: a release also needs the update signing
  key, the Developer ID certificate and the notarization key, which never leave the maintainer's Mac.
- Copies (forks) made by other people are separate projects. Your Vocalizer only accepts updates signed with
  Vocalizer's own key, so a fork can never update it.

## What Vocalizer can access

Vocalizer needs one macOS permission, **System Audio Recording**, to hear what your Mac plays. Audio is processed in
memory on your Mac and is never recorded, stored or sent anywhere. The app only contacts `vocalizer-mac.vercel.app`
(the update list) and `github.com` (downloads). More detail: [README › Updates and security](README.md#updates-and-security).
