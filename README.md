<p align="center">
  <img src="assets/resonance-lockup.png" width="460" alt="Resonance">
</p>

# Resonance

Resonance is the music player I wanted for my own library: a native Mac app built around listening, collecting, and deciding what belongs. It grew out of years of using players that treated a library as a static shelf. Resonance treats it as something you curate: songs audition their way in, projects gather what you're working through, and the app keeps track of what you've actually heard.

It's a personal project, written in Swift and SwiftUI for macOS, and it plays music from a [Navidrome](https://www.navidrome.org) server over the Subsonic API.

This repository holds the source for the showcase build. It is the same code that produces the download on the releases page.

## What this build is

This is a **showcase build**, not the copy of Resonance I run against my own library. It looks and behaves like Resonance, but it only talks to a local demo server on your own Mac at `http://127.0.0.1:4534`, and refuses everything else. Other hosts, other ports, HTTPS endpoints, and redirects are all rejected in the app's network layer. It cannot be pointed at a real server, and it makes no other network connections of any kind: no telemetry, no external services.

The isolation is not just a setting. It is pinned in `PublicDemoConfiguration` and covered by tests in `Resonance/ResonanceTests/PublicShowcaseIdentityTests.swift`, so you can read exactly what the build is allowed to reach.

It also stays out of the way of anything else on your Mac:

- Bundle identifier `com.resonance.public`
- Application Support directory `Resonance Public`
- Cache directory `Resonance Public`
- Keychain service `com.resonance.public.server`

That means it can sit next to any other music software, including a private Resonance install, without touching its settings, database, caches, or credentials.

No music is included in this repository or in the release build. You supply your own audio files.

## Building

You'll need **Xcode 16 or newer** and **macOS 14 (Sonoma) or newer**.

```bash
xcodebuild \
  -project Resonance/Resonance.xcodeproj \
  -scheme Resonance \
  -configuration Release \
  build
```

The Xcode project is generated from `Resonance/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), and the generated `project.pbxproj` is committed, so you do not need XcodeGen to build. If you add or remove source files, regenerate it:

```bash
cd Resonance && xcodegen generate
```

There is also a `Package.swift` for Swift Package Manager, which is what the unit tests run under:

```bash
swift test --package-path Resonance
```

The only dependency is [GRDB](https://github.com/groue/GRDB.swift) for SQLite persistence. It is resolved by SwiftPM.

The app is built ad-hoc signed rather than notarized (`CODE_SIGN_IDENTITY` is `-`, with no team). On first launch macOS may block it; open **System Settings → Privacy & Security** and choose **Open Anyway**, or right-click the app and choose Open.

## Giving it something to play

Install Navidrome and run it on port 4534 against a folder of your own audio files:

```bash
brew install navidrome
ND_DEVAUTOCREATEADMINPASSWORD=demo navidrome \
  --address 127.0.0.1 --port 4534 \
  --musicfolder ~/Music/demo \
  --datafolder "$HOME/Library/Application Support/Resonance Public Demo"
```

The app signs in automatically with the demo credentials `admin` / `demo`, which the command above creates on first run. Those credentials only ever go to the loopback address, so they're harmless by construction.

If you'd rather run it as a background service, `demo/` has a config file and a launch agent. Pick a folder to hold the demo data, substitute it into the config, and load the agent:

```bash
DEMO_ROOT="$HOME/ResonanceDemo"
mkdir -p "$DEMO_ROOT/Music" "$DEMO_ROOT/Logs"
mkdir -p "$HOME/Library/Application Support/Resonance Public Demo"
sed "s|DEMO_ROOT|$DEMO_ROOT|g" demo/navidrome.toml \
  > "$HOME/Library/Application Support/Resonance Public Demo/navidrome.toml"
cp demo/com.resonance.public.demo-server.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.resonance.public.demo-server.plist"
```

Put your audio under `$DEMO_ROOT/Music`. To stop it:

```bash
launchctl bootout "gui/$(id -u)/com.resonance.public.demo-server"
```

## What's in here

```
Resonance/Resonance/App/         app lifecycle, window and state wiring
Resonance/Resonance/Core/        audio, cache, database, network, playback
Resonance/Resonance/Features/    library, search, playlists, projects, settings
Resonance/Resonance/UI/          sidebar, components, styles, keyboard handling
Resonance/ResonanceTests/        unit tests
resonance-mgmt/                  optional companion service for tagging and file work
demo/                            local demo server config
```

The `resonance-mgmt` folder is a small TypeScript service that handles metadata tagging and file operations the app hands off. It is optional and the app runs without it.

My own planning notes, dogfood records, private fixtures, and library data are not in this repository.

## Caveats

This is a personal project published as-is. It is not a product. Some corners are rough, some of the code shows where I changed my mind partway through, and there is no support commitment. The layout in the app is influenced by Apple Music, which I used for years and wanted to argue with; the code and the artwork here are my own.

## License

MIT. See [LICENSE](LICENSE).
