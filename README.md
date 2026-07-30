# Resonance Public

Resonance Public is a self-contained showcase build of the Resonance macOS music player. It is intentionally unable to connect to the private Resonance/Navidrome installation.

## Privacy and isolation

- App identity: `com.resonance.public`
- Display name: **Resonance Public**
- Network allowlist: only `http://127.0.0.1:4534`
- Redirects away from that loopback endpoint are rejected
- App data: `~/Library/Application Support/Resonance Public`
- Cache data: `~/Library/Caches/Resonance Public`
- Keychain service: `com.resonance.public.server`
- Demo media operations are read-only
- Navidrome external services and telemetry are disabled

The normal Resonance app, its settings, credentials, database, caches, live server, and Fetcher export are not read by this build.

## Forty demo library

The showcase library is named **Forty**. Media is not committed to Git and must not be redistributed with the source. On the showcase Mac it lives on the external volume:

```text
/Volumes/External/ResonancePublic/Forty
```

That directory contains forty album folders whose tracks are symlinked from complete Apple Music Classical albums already held on the same external volume. The links consume negligible additional storage; the audio remains outside the repository and off the internal SSD.

## Run the local demo service

Install Navidrome with Homebrew, copy the tiny service configuration into Application Support, then load the included loopback-only service:

```bash
brew install navidrome
/bin/mkdir -p "$HOME/Library/Application Support/Resonance Public Demo"
/bin/cp demo/navidrome.toml "$HOME/Library/Application Support/Resonance Public Demo/navidrome.toml"
/bin/cp demo/com.resonance.public.demo-server.plist "$HOME/Library/LaunchAgents/com.resonance.public.demo-server.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.resonance.public.demo-server.plist"
```

The service uses the included `demo/navidrome.toml`. Its demo-only credentials are `admin` / `demo`; they cannot be used against any non-loopback server because the app rejects every other endpoint.

To stop it:

```bash
launchctl bootout "gui/$(id -u)/com.resonance.public.demo-server"
```

## Build

Xcode 16 or newer and macOS 14 or newer are required.

```bash
swift test --package-path Resonance
xcodebuild \
  -project Resonance/Resonance.xcodeproj \
  -scheme Resonance \
  -configuration Release \
  -derivedDataPath /Volumes/External/ResonancePublic/DerivedData \
  build
```

The app bundle is produced as `Resonance Public.app` and can coexist with `Resonance.app`.

## What is included

The repository contains the SwiftUI app, tests, Xcode and Swift Package Manager definitions, the optional `resonance-mgmt` companion source, and the local demo-service configuration. Internal planning documents, dogfood records, private fixtures, screenshots, and media are excluded.

## License

No open-source license file has been selected yet. Until one is added, the source remains all-rights-reserved by default.
