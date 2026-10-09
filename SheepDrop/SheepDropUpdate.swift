import AppKit

// SheepDrop's half of the in-app updater: the ONLY file that ties the generic updater in
// SheepDrop/Update/ (copied unchanged from SheepTerm 5.0, 9 Oct 2026) to this app.
// Releases come from the public repository's latest GitHub Release: `SheepDrop-<version>.zip`
// (tag v<version>, semver) plus its Ed25519 `.zip.sig`, both made by the Sheep-family
// release.sh (/ship) from `.ship.conf`.

extension UpdateConfig {
    /// The Ed25519 key whose private half is in the release Mac's login Keychain (service
    /// `signingKeychainService`, account `ed25519`, made once by SheepTerm's Tools/update-keygen.sh
    /// on 9 Oct 2026). `.ship.conf` carries the same value as UPDATE_SIGN_PUBLIC_KEY, and
    /// `Tests/run.sh updater` (part of `run.sh server`) fails when the two differ. One key per app.
    static let sheepDrop = UpdateConfig(
        appName: "SheepDrop",
        repository: "bestonehxh/SheepDrop",
        tagScheme: .semver,
        publicKeyBase64: "C/HXhhmZOVHzYjUKqolTy5fCbJIiMASnI1lnCoPYhTo=",
        signingKeychainService: "Bestchaan.SheepDrop.update-signing"
    )
}

@MainActor
enum AppUpdater {
    /// SheepDrop has no quit question of its own (⌘Q stops the servers and ends
    /// transfers without asking), so Install & Relaunch is the only question asked.
    static let shared = Updater(config: .sheepDrop, hooks: UpdateHooks(
        presenter: CenteredUpdatePresenter()  // centred (a plain NSAlert left-aligns Details)
    ))

    /// Automatic checks are always on (the user, 9 Oct 2026: no option for it), so a stored
    /// "off" from an earlier build is cleared before the updater reads it.
    static func start() {
        UserDefaults.standard.removeObject(forKey: UpdateCore.autoCheckKey)
        shared.start()
    }
}
