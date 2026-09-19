# xcodectl

Install, approve, switch and remove Xcode versions from the terminal. Works on your Mac and on
self-hosted CI Macs. No Apple login code inside: you sign in once in a window, the tool keeps the
session in your Keychain and does the rest.

```
xcodectl login                     sign in to Apple Developer (once)
xcodectl list [<regex>]            two latest majors + running betas; --stable/--beta; regex searches all
xcodectl list-installed            what is in /Applications, active one starred
xcodectl release-notes [<ver>] [<ver2>] [--markdown | --plain] [--abridged] [--ask "<question>"]
                                   notes rendered in the terminal; two versions: what changed; no login needed
xcodectl install [<ver>] [--select] [--no-approve] [--no-clt]
xcodectl install-clt [<ver>]       only the Command Line Tools of that Xcode version (sudo); no login needed
xcodectl approve [<ver>]           license + first launch + developer mode (sudo); install does this by default
xcodectl select [<ver>]            xcode-select (sudo)
xcodectl remove <ver>
xcodectl session export | import   move the session to a runner
```

`<ver>` is forgiving: `26.1`, `27`, `27 rc`, `27-rc1`, `27 beta 3`, `27A266a`, `latest`,
`latest-beta`. Omit it on `install`, `approve`, `select` for a picker.

## Release notes

No login needed. `--abridged` and `--ask` run on the on-device Apple Intelligence model (macOS 26+);
nothing leaves the Mac.

```
xcodectl release-notes 26.4                  the notes, rendered: colors, bold, italic, clickable links
xcodectl release-notes 26.4 --markdown       the Markdown Apple serves
xcodectl release-notes 26.4 --plain          plain text; also the default when piped
xcodectl release-notes 27 --abridged         the overview and the ten changes that matter most
xcodectl release-notes 26.3 26.4             what 26.4 adds (+) and drops (-) compared to 26.3
xcodectl release-notes 27 --ask "which minimal macOS is required?"
```

```
$ xcodectl release-notes 27 --ask "which minimal macOS is required?"
Xcode 27 requires a Mac running macOS Tahoe 26.6 or later.

$ xcodectl release-notes 26.4.0 --ask "Are there known issues with Swift Testing?"
The release notes for Xcode 26.4 list several known issues with Swift Testing: failures in retrying
tests when continueAfterFailure is set to false, inability to attach UIImage instances to tests when
testing a Mac Catalyst app, and potential crashes at launch on Apple silicon when using a Rosetta
run destination.
```

`--abridged` takes about a minute on long notes: the model names and rates up to three changes in
each part, and the ten highest rated ones make the summary.

```
$ xcodectl release-notes 27 --abridged
...
- Instruments now requires target iOS, watchOS and tvOS devices with versions of at least iOS 17, watchOS 10, or tvOS 17.
- Xcode 27 will only install and run on Apple silicon Macs.
- Removed `ld64` linker and `-ld_classic` option; linking now incompatible
```

The model is small: treat its answers and summaries as a pointer into the notes, not as the notes.

## Install

```
mise use -g github:bonkey/xcodectl
# or
brew install bonkey/tap/xcodectl
# or from source
git clone https://github.com/bonkey/xcodectl && cd xcodectl && just install
```

## First run

```
xcodectl login          # a window opens; sign in with your Apple ID and 2FA code
xcodectl install 26.6   # downloads (16 connections), expands, moves to /Applications/Xcode-26.6.app,
                        # then approves it (sudo: license, first-launch packages) and installs
                        # Command Line Tools 26.6 (sudo: softwareupdate)
xcodectl select 26.6    # sudo: xcode-select
```

Two-factor codes (trusted device, SMS) and hardware security keys (YubiKey and other FIDO2 keys,
PIN + touch) both work in the window. Passkeys stored in iCloud Keychain do not.

## CI (self-hosted runner)

On your Mac: `xcodectl session export | pbcopy`. On the runner, once:
`pbpaste | xcodectl session import` (stores it in that runner's Keychain). Then in the job:

```
xcodectl install 26.6 --select
```

Alternatively pass the blob per job as `XCODECTL_SESSION`; it is then used in memory only.

Over plain ssh the login Keychain is locked (macOS gives ssh logins their own security session),
so `session import` and `install` fail with "User interaction is not allowed". Run
`security unlock-keychain` in that ssh session first, do the import from a GUI session (Screen
Sharing), or use `XCODECTL_SESSION`. Runners launched in the logged-in session are not affected.
Apple's login session lasts weeks; when a job fails with "session expired", run `login` and
export again.

## How it works

- Versions and direct download URLs: `https://xcodereleases.com/data.json`.
- Auth: Apple's portal sets a long-lived login session in the window; the tool keeps only the
  `apple.com` cookies, in the Keychain. WebKit refuses WebAuthn for apple.com in third-party apps,
  so the page's `navigator.credentials.get` is routed to libfido2, which drives the security key.
  Each download needs a ~24 h `ADCDownloadAuth` cookie, which the tool fetches itself from Apple's
  download-list endpoint using that session.
- Download: 16 parallel HTTP range requests on URLSession into one preallocated file, resumable.
- Expand: in-process [unxip](https://github.com/saagarjha/unxip).
- `approve`: `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, `DevToolsSecurity -enable`.
- Command Line Tools: `install` runs `sudo softwareupdate --install "Command Line Tools for Xcode
  X.Y-X.Y"` for the Xcode's major.minor when that is newer than the receipt in
  `/Library/Apple/System/Library/Receipts` (or there is none); skip it with `--no-clt`. It never
  downgrades, so an older Xcode installed side by side leaves the tools alone. Keeps Homebrew's
  "A newer Command Line Tools release is available" quiet. When Software Update has no package for
  that version (some betas), a warning is printed and the install still succeeds.
- `install-clt` runs the same Software Update install for exactly the version asked for, older
  ones included, without touching Xcode or the Apple session. It fails when Software Update has
  no package for that version.
- `release-notes`: Apple serves each notes page under `developer.apple.com/documentation/` as
  Markdown at the same URL plus `.md`; the link comes from `data.json`. On a terminal the Markdown
  is rendered with escape sequences (links as OSC 8 hyperlinks), in the colors of Gogh's "GitHub
  Dark" or "Github Light": the tool asks the terminal for its background (OSC 11) and takes dark
  when there is no answer; `XCODECTL_THEME=dark|light` decides instead. Terminals without 24-bit
  color (`COLORTERM` unset) get their own 16 colors. `--markdown` prints the Markdown raw,
  `--plain` strips the markup, which is also what a pipe gets. Two versions list the items the
  second one's notes add (`+`) and drop (`-`), by section; betas, the rc and the final of one
  version share a page. `--abridged` and `--ask` run on the on-device Apple Intelligence model
  (macOS 26+); nothing leaves the Mac. `--abridged` keeps the overview as it is and lets the model
  rate the changes of each part, `--ask` answers from the overview and the sections that share
  words with the question. Notes older than the documentation site (archived HTML, PDFs) are not
  available.
- `remove`: deletes the app bundle. System packages, simulator runtimes and DerivedData are shared
  between Xcode versions and stay.

Files: `~/.xcodectl/cache/` (downloads in flight, cached version list). Nothing else.
