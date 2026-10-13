# Contributing to Backglow

Thanks for helping with Backglow. Issues and pull requests are welcome in English or German.

## Questions and bugs

- Setup problems are often answered in the [setup guide](https://backglow.jandeboer.de/en/docs/#troubleshooting). If not, open an issue.
- For bugs, use the bug report template. Your macOS version, Mac model, board and strip help most, and so do the values on the app's **Diagnostics** page.
- Report security problems privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Before a larger change

Open an issue first for new features or anything that changes the serial protocol, the controller profile or the settings format. The app, the firmware and older settings files have to stay compatible, so it is worth agreeing on the approach before writing code.

## Building and testing

You need Xcode 26. The app runs on macOS 14 or later, so check changes to newer APIs with `#available` and a fallback.

```sh
./scripts/build-app.sh          # builds dist/Backglow.app, signed ad hoc without a certificate
swift test --disable-sandbox    # core tests, also run in CI
swift scripts/check-metal.swift Sources/Backglow/Shaders/ZoneAverage.metal
```

Firmware changes in `Firmware/BackglowController` should build for both boards and pass the host protocol test:

```sh
cd Firmware/BackglowController
pio run -e esp32dev && pio run -e nodemcuv2
clang++ -std=c++17 -DESP32 -DLED_DATA_PIN=18 -I tests/stubs \
  tests/host_protocol.cpp -o /tmp/backglow-protocol && /tmp/backglow-protocol
```

Live capture, serial transfer and storage on the controller can only be checked with real hardware. Say in the pull request what you tested on which Mac, board and strip.

## Guidelines

- Keep pull requests focused on one topic.
- Add or update tests in `Tests/BackglowCoreTests` for changes to `Sources/BackglowCore`.
- The app is localized in German (source language) and English. After changing user-facing text, run `./scripts/update-strings.sh` and translate the new keys in `AppBundle/Localization`.
- The website in `Website/public` exists in German and English; keep both versions in step (see [Website/README.md](Website/README.md)).
- Update the README or the setup guide when behavior changes.
- Commit messages are short imperative sentences, such as "Load the Metal shader from the app bundle".

By contributing, you agree that your contribution is licensed under the [GPL-3.0](LICENSE), like the rest of the project, and that you follow the [code of conduct](CODE_OF_CONDUCT.md).
