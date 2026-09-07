# Contributing to AppSigner

Thanks for your interest in improving AppSigner!

## Development

- All code and comments are in **English**.
- The signing logic lives in the `SigningKit` library and is developed
  **test-first** (TDD). Please add or update tests for any behavior change.
- The SwiftUI app (`Sources/AppSigner`) is a thin layer over `SigningKit`.

```bash
swift build            # build everything
swift test             # run the unit tests (offline)
```

Gated tests (opt in with an environment variable):

- `APPSIGNER_INTEGRATION=1` — end-to-end signing against a real `.ipa` present in the
  workspace and a matching Keychain identity.
- `APPSIGNER_NET=1` — live GitHub-release tests.

## Pull requests

1. Keep changes focused and covered by tests.
2. Run `swift test` and make sure it is green.
3. Describe what changed and why.

## Reporting issues

Please include your macOS and Xcode versions, the exact steps, and any output from the
process screen / `codesign`.
