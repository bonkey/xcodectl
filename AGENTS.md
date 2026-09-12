# xcodectl — agent notes

CLI that installs, approves, switches and removes Xcode versions on macOS, locally and on
self-hosted CI Macs. README.md covers usage; this file covers how to work on the repo.

## What it is, in one paragraph

No Apple auth code. `login` opens a WKWebView (throwaway data store) on
developer.apple.com; when Apple's portal reports a signed-in session (`myacinfo` cookie on the
downloads page) the `apple.com` cookies go into the login Keychain as one generic-password item
(service `xcodectl`, account `apple-session`). A download needs one short-lived cookie,
`ADCDownloadAuth` (~24 h); `install` fetches a fresh one by POSTing
`developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action` with the stored
session. Version metadata and direct XIP URLs come from `xcodereleases.com/data.json`.
Download is 16 parallel `Range` requests on URLSession writing into one preallocated file
(resumable via a `.state` sidecar). Expansion is in-process `libunxip`. `approve` and `select`
are the only commands that call `sudo`.

## Layout

```
Sources/xcodectl/
  XcodeCtl.swift     commands, pickers, tables (Noora for TUI)
  Releases.swift     data.json model, version query parsing/matching, listing
  Session.swift      cookie model, Keychain, XCODECTL_SESSION, download-ticket refresh
  LoginWindow.swift  AppKit + WKWebView modal window (only file importing AppKit/WebKit)
  Downloader.swift   parallel ranged download + resume
  Install.swift      installed scan, unxip, move, approve, select, remove
  Shell.swift        Fail error, paths, sudo(), small system helpers
  Version.swift      `let version = "x.y.z"`, bumped by `just release`
```

## Conventions

- Swift 5 language mode, macOS 14+. Dependencies: swift-argument-parser, Noora, unxip. Do not add
  more without a reason that survives "could Foundation do this".
- No external processes except `/usr/bin/sudo` (approve, select, remove fallback). Networking is
  URLSession; XIP expansion is libunxip.
- Nothing cookie-related ever touches disk. Session lives in the Keychain or in the
  `XCODECTL_SESSION` environment variable (base64 JSON), never in a file.
- Errors: throw `Fail("one actionable line")`; ArgumentParser prints it and exits 1.
- Pickers only when stdin and stdout are a TTY; otherwise a missing argument is an error.
- Installed Xcodes are matched by `Contents/version.plist` `ProductBuildVersion`, never by
  directory name, so apps installed by other tools resolve too.

## Build, run, test

```
just build            # swift build
just run list         # swift run xcodectl list
just release-build    # universal binary; `just release-bin` prints its directory
just install          # copy it to ~/.local/bin
just lint / just fmt  # swiftformat
```

Manual end-to-end check (needs an Apple Developer account): `xcodectl login`, `xcodectl list`,
`xcodectl install <ver>`, `xcodectl approve <ver>`, `xcodectl select <ver>`, `xcodectl remove <ver>`.
A hidden `xcodectl _download <url> <file>` exercises the downloader against any URL
(`--with-ticket` adds the Apple cookies).

## Releasing

`just release` bumps the patch version (or `just release 1.2.0`), commits, tags `v<ver>`, pushes,
builds the universal binary, and creates the GitHub release with
`xcodectl-<ver>-macos-universal.tar.gz` + `.sha256`. mise (`ubi:bonkey/xcodectl`) and the brew
formula resolve versions from GitHub releases, so a bare tag is not a release. Requires a clean
tree and `gh` logged in.
