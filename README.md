# Resonance

Resonance is the music player I wanted for my own library: a native Mac app built around listening, collecting, and deciding what belongs. It is written in Swift and SwiftUI and speaks to a Navidrome server over the Subsonic API.

This branch is the isolated showcase build. It looks and behaves like Resonance, but it talks only to a local demo server on the same Mac and cannot reach anything else.

## Privacy and isolation

- Bundle identifier: `com.resonance.public` (distinct from the private app)
- Network allowlist: only `http://127.0.0.1:4534`; other hosts, ports, schemes, and redirects are rejected
- App data: `~/Library/Application Support/Resonance Public`
- Cache data: `~/Library/Caches/Resonance Public`
- Keychain service: `com.resonance.public.server`
- Demo media operations are read-only
- No external services or telemetry

The normal Resonance app, its settings, credentials, database, caches, live server, and importers are never read by this build.

## Forty demo library

The showcase library is named **Forty**. Its media lives outside the repository (on the showcase Mac, under `/Volumes/External/ResonancePublic/Forty`), is not committed to Git, and is not redistributed with the source or with any release build. The downloadable build expects the isolated loopback demo server and does not include the Forty demo music.

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

The app bundle is produced as `Resonance.app` with bundle identifier `com.resonance.public`. Install it under a distinct name (for example `Resonance Showcase.app`) if a private `Resonance.app` already exists in `/Applications`.

## What is included

The repository contains the SwiftUI app, tests, Xcode and Swift Package Manager definitions, the optional `resonance-mgmt` companion source, and the local demo-service configuration. Internal planning documents, dogfood records, private fixtures, screenshots, and media are excluded.

## License

No open-source license file has been selected yet. Until one is added, the source remains all-rights-reserved by default.
