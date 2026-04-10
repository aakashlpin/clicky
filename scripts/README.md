# Release Scripts

## `build-launcher.sh` — Build the installable Clicky launcher

This is the day-to-day release flow if you want to keep using Clicky without running it from Xcode.

It creates a Release archive, stages a standalone `Clicky.app`, and packages a zip artifact. The launcher app ends up at:

```bash
build/local-release/launcher/Clicky.app
```

### Quick start

```bash
./scripts/build-launcher.sh
```

Then move `build/local-release/launcher/Clicky.app` into `/Applications` and launch it from there.

That `/Applications/Clicky.app` bundle is the launcher you can keep running independently of Xcode. Installing from `/Applications` also matches how the app registers itself as a login item.

### Install automatically

```bash
./scripts/build-launcher.sh --install
```

That replaces `/Applications/Clicky.app` directly.

### What it does

1. Archives the app in `Release`
2. Copies `Clicky.app` out of the archive into `build/local-release/launcher/`
3. Creates `build/local-release/Clicky.zip`
4. Verifies the staged app signature
5. Optionally installs the app into `/Applications`

## `release.sh` — Full distribution release

This is the heavier distribution pipeline for shipping a public release: archive → export → DMG → notarize → Sparkle appcast → GitHub Release.

Use this only when you are publishing a new externally downloadable version, not for normal local use.

### Quick start

```bash
GITHUB_REPO=your-org/clicky-releases ./scripts/release.sh
```

### One-time setup (prerequisites)

1. **Xcode** with your Developer ID signing certificate
2. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
3. **GitHub CLI auth**:
   ```bash
   gh auth login
   ```
4. **Apple notarization credentials** (stored in Keychain):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id YOUR_TEAM_ID
   ```
5. **Sparkle EdDSA key** in Keychain
6. **Build the project in Xcode at least once** so SPM downloads Sparkle and its CLI tools
