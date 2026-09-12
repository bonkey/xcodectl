# xcodectl

Install, approve, switch and remove Xcode versions from the terminal. Works on your Mac and on
self-hosted CI Macs. No Apple login code inside: you sign in once in a window, the tool keeps the
session in your Keychain and does the rest.

```
xcodectl login                     sign in to Apple Developer (once)
xcodectl list [<regex>]            versions: latest major + newest beta major; regex searches all
xcodectl list-installed            what is in /Applications, active one starred
xcodectl install [<ver>] [--approve] [--select]
xcodectl approve [<ver>]           license + first launch + developer mode (sudo)
xcodectl select [<ver>]            xcode-select (sudo)
xcodectl remove <ver>
xcodectl session export | import   move the session to a runner
```

`<ver>` is forgiving: `26.1`, `27`, `27 rc`, `27-rc1`, `27 beta 3`, `27A266a`, `latest`,
`latest-beta`. Omit it on `install`, `approve`, `select` for a picker.

## Install

```
mise use -g ubi:bonkey/xcodectl
# or
brew install bonkey/tap/xcodectl
# or from source
git clone https://github.com/bonkey/xcodectl && cd xcodectl && just install
```

## First run

```
xcodectl login          # a window opens; sign in with your Apple ID and 2FA code
xcodectl install 26.6   # downloads (16 connections), expands, moves to /Applications/Xcode-26.6.app
xcodectl approve 26.6   # sudo: accept license, install first-launch packages
xcodectl select 26.6    # sudo: xcode-select
```

Two-factor codes sent to a trusted device or by SMS work in the window. Security keys and
passkeys do not: an embedded web view cannot use them for apple.com. Turn off Security Keys for
the account you use for downloads, or use a second Apple ID.

## CI (self-hosted runner)

On your Mac: `xcodectl session export | pbcopy`. On the runner, once:
`pbpaste | xcodectl session import` (stores it in that runner's Keychain). Then in the job:

```
xcodectl install 26.6 --approve --select
```

Alternatively pass the blob per job as `XCODECTL_SESSION`; it is then used in memory only.
Apple's login session lasts weeks; when a job fails with "session expired", run `login` and
export again.

## How it works

- Versions and direct download URLs: `https://xcodereleases.com/data.json`.
- Auth: Apple's portal sets a long-lived login session in the window; the tool keeps only the
  `apple.com` cookies, in the Keychain. Each download needs a ~24 h `ADCDownloadAuth` cookie,
  which the tool fetches itself from Apple's download-list endpoint using that session.
- Download: 16 parallel HTTP range requests on URLSession into one preallocated file, resumable.
- Expand: in-process [unxip](https://github.com/saagarjha/unxip).
- `approve`: `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, `DevToolsSecurity -enable`.
- `remove`: deletes the app bundle. System packages, simulator runtimes and DerivedData are shared
  between Xcode versions and stay.

Files: `~/.xcodectl/cache/` (downloads in flight, cached version list). Nothing else.
