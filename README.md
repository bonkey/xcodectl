# xcodectl

Install, approve, switch and remove Xcode versions from the terminal. Works on your Mac and on
self-hosted CI Macs. No Apple login code inside: you sign in once in a window, the tool keeps the
session in your Keychain and does the rest.

```
xcodectl login                     sign in to Apple Developer (once)
xcodectl list [<regex>]            versions: latest major + newest beta major; regex searches all
xcodectl list-installed            what is in /Applications, active one starred
xcodectl install [<ver>] [--select] [--no-approve]
xcodectl approve [<ver>]           license + first launch + developer mode (sudo); install does this by default
xcodectl select [<ver>]            xcode-select (sudo)
xcodectl remove <ver>
xcodectl session export | import   move the session to a runner
```

`<ver>` is forgiving: `26.1`, `27`, `27 rc`, `27-rc1`, `27 beta 3`, `27A266a`, `latest`,
`latest-beta`. Omit it on `install`, `approve`, `select` for a picker.

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
                        # then approves it (sudo: license, first-launch packages)
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
- `remove`: deletes the app bundle. System packages, simulator runtimes and DerivedData are shared
  between Xcode versions and stay.

Files: `~/.xcodectl/cache/` (downloads in flight, cached version list). Nothing else.
