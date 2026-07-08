# Dispatch

Dispatch is an iOS app for self-tracking through randomly timed surveys.
A few times a day, at moments you don't control, Dispatch asks you a short
set of questions — how you're feeling, what you're doing, who you're
with — and quietly attaches the sensor context of that moment: location,
steps and heart rate from Health, ambient noise level, nearby photo
activity, and whether a Focus was active. Answer enough of them over
weeks and months and a genuinely useful picture of your life emerges,
one you can search, chart, and export whenever you want.

This project draws its inspiration from *Reporter*, the pioneering
self-tracking app built by Nicholas Felton and Drew Breunig and later
discontinued — Dispatch is a from-scratch reimplementation of that idea
for a modern iOS, with its own design and codebase, built to let people
keep using the format Reporter popularized and to import their existing
Reporter exports.

## Features

- **Randomly timed surveys** — configurable question sets fire at
  unpredictable times throughout the day, avoiding the bias of
  fixed-schedule check-ins.
- **Sensor context capture** — each report can be enriched with
  location, weather, steps/heart rate/HRV/sleep/workouts from Apple
  Health, ambient sound level, recent photo count, and Focus state,
  depending on what you grant access to.
- **Rich question types** — scales, choices, free text, and more, with
  per-question Health "State of Mind" logging when you opt in. Author
  question sets in the app.
- **Search** — full-text and Spotlight-indexed search across your
  reports.
- **Visualizations** — charts and summaries of your answers over time.
- **Face ID app lock** — optional biometric lock on launch.
- **Import & export** — bring in an original Reporter export or a
  Dispatch export, and export your data back out as JSON or CSV at any
  time. Everything lives on-device; there is no backend server.

## Requirements

- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 26 SDK / simulator (or a device running iOS 26+)

## Building

```sh
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Or just open `Dispatch.xcodeproj` in Xcode after running `xcodegen generate`.

### Entitlements note

Dispatch ships with WeatherKit and HealthKit entitlements. These require
a paid Apple Developer Program membership tied to a real team ID —
`project.yml` is configured with `DEVELOPMENT_TEAM: UTQFCBPQRF`; change
it to your own.

Focus-state capture additionally needs the Focus Status capability
(`com.apple.developer.focus-status`), which automatic provisioning cannot
add — enable it manually on your App ID in the Apple Developer portal,
then add the key to `App/Dispatch.entitlements` and rebuild. Until then,
Focus context is simply omitted from reports.

If you build with a free-tier team, Xcode will drop entitlements it
can't provision; Dispatch degrades gracefully in every such case
(weather, Health, and Focus context are omitted from reports) rather
than crash.

## Importing an original Reporter export

Reporter's export format (`{"questions": [...], "snapshots": [...]}`) is
supported directly. From Settings → Data → Import…, choose your
exported `.json` file. Dispatch detects whether the file is a Reporter
(v1) export or a Dispatch (v2, `schemaVersion: 2`) export automatically
and imports accordingly, then rebuilds its search index. You'll see a
summary of how many reports, questions, and responses were imported
(and how many records were skipped because they were malformed).

## License

MIT — see [LICENSE](LICENSE).

## Screenshots

Coming soon.

- [ ] Add screenshots captured from a real device once available.
