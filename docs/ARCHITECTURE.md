# Architecture

AppSigner is split into a reusable, fully tested core library (`SigningKit`) and a thin
SwiftUI front-end (`AppSigner`). The app target contains almost no logic — it observes a
view model that drives `SigningKit`.

```
Sources/
  SigningKit/            # the engine (pure Swift, unit-tested)
  AppSigner/             # SwiftUI app (views + view model)
Tests/
  SigningKitTests/       # TDD suite + a non-sensitive sample profile fixture
```

## SigningKit modules

Each type has a single responsibility and is testable in isolation.

| Module | Responsibility |
|--------|----------------|
| `ProcessRunner` | Safe subprocess execution (argument arrays, captured or **streamed** output, exit codes). Never uses a shell string. |
| `ProvisioningProfile` | Parses a `.mobileprovision` by extracting the embedded XML plist from its CMS container — team, expiry, type, app-id, entitlements, developer-certificate SHA‑1s. |
| `KeychainService` | Enumerates code-signing identities via the Security framework and matches them to a profile's certificates by fingerprint. |
| `IPAPackage` | Unzips / repacks an IPA, locates `Payload/<App>.app`, reads app metadata or the whole `Info.plist` by extracting just that one file, and orders the signable components (inner → outer). |
| `InfoPlistEditor` | Reads and edits `Info.plist`, preserving the on-disk format: the basics (bundle id, version, build, name) plus minimum iOS version, device families, file sharing, ATS arbitrary loads, removing required capabilities, URL-scheme prefixing, and a raw typed key editor (`PlistValue`). Refuses to touch protected keys. |
| `MachOFile` | Generic Mach-O reader: walks thin/fat files and 32/64-bit slices, reporting architectures, FairPlay state and every dylib reference (load / weak / reexport / upward). Also maps a jailbreak install path to its `@rpath` form. |
| `MachOInjector` | Injects, **removes**, **re-points** and re-flags dylib load commands natively. A rewrite is written into the existing command when the new path fits, otherwise the command is removed and re-injected, keeping the weak flag either way. Injection writes into the header padding; removal compacts the commands and re-zeroes the freed tail, so file size and section offsets never change. |
| `BundleInspector` | Scans any `.app`: finds every Mach-O, classifies each dylib reference (system / bundled / jailbreak / missing) resolving `@rpath`, `@executable_path` and `@loader_path`, builds a referrer graph, reports each nested bundle's own identifier, and lists removable vs protected entries with sizes. |
| `DebPackage` | Reads a Cydia/Sileo `.deb`: unpacks the `ar` container and payload with system `tar` (gzip/xz/bzip2/zstd auto-detected), parses the control metadata, and finds tweak dylibs, resource bundles, frameworks, and the target bundle ids from each tweak's filter plist. |
| `BundleEditor` | Applies removals, path rewrites and dylib edits to an unpacked bundle, installs resource bundles and frameworks, and embeds a provisioning profile inside a nested bundle. Validates up front and refuses protected paths or paths escaping the bundle. |
| `PreflightValidator` | Pure, app-agnostic checks run before signing; findings are advisory and never block a run. |
| `IconInstaller` | Renders the standard iOS icon PNG sizes with CoreGraphics/ImageIO and wires them into `Info.plist`, overriding an `Assets.car` icon by loose PNGs. |
| `Codesigner` | Builds an entitlements plist from the profile and runs `codesign` per component, then verifies. |
| `DeviceService` | Lists connected devices and installs an IPA via libimobiledevice, resolving tool paths explicitly. |
| `HomebrewService` | Detects Homebrew, reads tool versions, checks `brew outdated`, and installs/upgrades formulae. |
| `GitHubReleaseService` | Fetches the latest release of a repo, picks a binary asset, downloads and extracts it (used for the legacy `optool` link). |
| `ToolCatalog` / `ToolsInspector` | Describes each external tool and computes its runtime status for the Tools panel. |
| `SigningPreset` / `PresetStore` | A reusable, app-agnostic signing configuration persisted as JSON; saving under an existing name replaces it. |
| `BatchSigner` | Signs a list of requests in order, recording failures and continuing, and reporting per-item progress. Its signing step is injectable so the batch logic is testable without signing. |
| `SigningPipeline` | Orchestrates the whole run and emits ordered progress events. |

## Signing pipeline

`SigningPipeline.sign(_:progress:)`:

1. Parse the profile; fail fast if it is expired or the selected identity is not one of
   the profile's certificates.
2. Unpack the IPA into a temp working directory (cleaned up via `defer`).
3. Apply `Info.plist` edits (id / version / name).
4. Remove any existing `*.mobileprovision`, copy the profile to `embedded.mobileprovision`.
5. Apply bundle edits: strip selected dylib load commands, weaken others, delete selected
   entries (extensions, watch app, frameworks, resources).
6. Install frameworks into `Frameworks/`, copy tweak resource bundles into the app root,
   then inject dylibs (copy into
   `Frameworks/`, patch the main executable's load commands), weak-linked by default.
7. Replace the icon (before signing, so the icons are sealed by the signature).
8. Extract entitlements from the profile.
9. Embed any per-extension profiles and write their own entitlements, then `codesign`
   every component from the inside out — nested frameworks and dylibs, then app
   extensions, then the `.app` — applying entitlements only to the app and its extensions.
10. Verify with `codesign --verify --deep --strict`.
11. Repack into `<input-basename>_Signed.ipa` (unique).

## Design choices

- **No third-party signing tools.** Everything the engine needs is implemented in Swift or
  delegated to Apple's own system tools. The signature itself is produced by `codesign`:
  Apple exposes no public signing API, and while third-party projects (zsign, ldid)
  do re-implement the signature format — that is what lets them run off macOS — Apple's
  implementation is the most trustworthy one on this platform, so it is a deliberate
  choice rather than a hard constraint.
- **Explicit identity selection.** The signing certificate is chosen by SHA‑1 rather than
  relying on an implicit "first identity", which avoids signing with the wrong team.
- **Absolute paths everywhere.** All external commands receive absolute paths, avoiding a
  class of path/quoting bugs.
- **The view layer stays thin.** All testable behavior lives in `SigningKit`; the SwiftUI
  views only present state and forward user intent.
