# xcodectl

Install, approve, switch and remove Xcode versions and their simulator runtimes from the terminal.
Works on your Mac and on self-hosted CI Macs. No Apple login code inside: you sign in once in a
window, the tool keeps the session in your Keychain and does the rest.

```
xcodectl auth login                sign in to Apple Developer (once)
xcodectl auth status [--no-login]  whether Apple still accepts the session; exits 1 when not;
                                   otherwise the sign-in window opens, --no-login fails instead
xcodectl list [<regex>]            newest major by minor, the one before, running betas, installed ones,
                                   and whether each runs on this Mac; --stable/--beta,
                                   --by-version/--by-date; regex searches all
xcodectl installed [--no-size]     what is in /Applications with its size and the runtimes each Xcode uses
xcodectl release-notes [<ver>] [<ver2>] [--markdown | --plain] [--abridged] [--ask "<question>"]
                                   notes rendered in the terminal; two versions: what changed; no login needed
xcodectl install [<ver>...] [--select] [--no-approve] [--no-clt] [--no-login]
                 [--runtimes all|ios,watchos,...|none]
                                   several versions download and expand in parallel; so do separate runs
xcodectl upgrade [<ver>] [--minor] [--keep] [--beta] [--dry-run]
                 [--no-approve] [--no-clt] [--no-login] [--runtimes all|ios,watchos,...|none]
                                   newest release of each installed major (27.0 -> 27.2) with its
                                   simulator runtimes for the platforms you have, then the old one
                                   is removed and the new one selected if the old one was;
                                   --minor: newest build of the major.minor (27.0 -> 27.0.1);
                                   --keep: old ones stay; --beta: betas and rcs move too, to the
                                   newest beta or final of their line; <ver> picks the installed
                                   ones to upgrade (27 is every 27.x); --runtimes: other platforms
xcodectl install-clt [<ver>]       only the Command Line Tools of that Xcode version (sudo); no login needed
xcodectl approve [<ver>]           license + first launch + developer mode (sudo); install does this by default
xcodectl select [<ver>]            xcode-select (sudo)
xcodectl remove <ver> [--keep-runtimes]
                                   also deletes the simulator runtimes no other installed Xcode uses
xcodectl list <platform>|runtimes  simulator runtimes Apple offers; --stable/--beta, --all
xcodectl installed <platform>|runtimes
                                   runtimes installed, including leftovers simctl hides
xcodectl install <platform> [<ver>] [--xcode <ver>]
xcodectl remove <platform>|runtimes [<ver>]
xcodectl prune [--dry-run]         leftover runtime registrations that still hold disk space
xcodectl config init | check       defaults for any flag in ~/.config/xcodectl/config.toml
xcodectl auth export [--no-login] [--copy] | import [--paste]
                                   move the session to a runner; both check it with Apple first;
                                   --copy / --paste use the clipboard
xcodectl auth logout               delete the session from this Mac's Keychain
```

Every flag the config file can set has an inverse (`--approve`/`--no-approve`, `--size`/`--no-size`,
`--json`/`--no-json`), so a default from the file can be turned back for one run. `--dry-run` is
never a default.

`<ver>` is forgiving: `26.1`, `27`, `27 rc`, `27-rc1`, `27 beta 3`, `27A266a`, `latest`,
`latest-beta`. Omit it on `install`, `approve`, `select` for a picker and on `upgrade` for every
installed Xcode. `<platform>` is `ios`, `tvos`,
`watchos` or `visionos`, and `runtimes` means every platform.

## List

```
$ xcodectl list
VERSION     BUILD     RELEASED    STATUS     MACOS
27.2-beta3  27B5038j  2026-10-14             ✓ 26.6 or later
27.1        27A9275   2026-10-15  installed  ✓ 26.6 or later
27.1-beta1  27A9269   2026-09-18  installed  ✓ 26.6 or later
27.0        27A266a   2026-09-14  * active   ✓ 26.6 or later
26.6        17F113    2026-06-25             ✗ 26.2–26.x
```

Each minor of the newest major shows its newest release, the major before it only its newest one,
a beta cycle in progress its newest beta, and an installed Xcode always shows (here a 27.1 beta that
27.1 has since replaced). MACOS is the range of macOS versions that Xcode runs on, behind `✓` when
this Mac's macOS is in it and `✗` when it is too old or too new; here the Mac runs macOS 27.0.
`--stable` and `--beta` narrow the list, a regex searches all versions: `xcodectl list '^16\.'`. The
highest version comes first; `--by-date` puts the newest release first instead.

```
$ xcodectl installed
VERSION     BUILD     SIZE    PATH
27.2        27B5019j  3.3 GB  /Applications/Xcode-27.2-beta1.app  * active
  iOS 27.2  24B5084k  7.6 GB
27.1        27A9269   3.3 GB  /Applications/Xcode-27.1-beta1.app
  iOS 27.1  24A94401  7.3 GB
27.0        27A266a   3.3 GB  /Applications/Xcode-27.0.app
  iOS 27.0  24A434    7.5 GB
```

Under each Xcode are the simulator runtimes it uses; one shared by several Xcodes shows under each.
Sizing an Xcode reads every file in it and takes a second or so: at a terminal the table shows at
once with `…` in place of each Xcode's size and fills in, a pipe gets the finished table.
`--no-size` skips sizing.
`xcodectl remove` deletes those runtimes along with the Xcode, except the ones another installed
Xcode still uses; `--keep-runtimes` keeps them all.

### JSON

`list`, `installed` (also for runtimes) and `auth status` take `--json`, for scripts and agents:

```
$ xcodectl installed --json
[
  {
    "active" : true,
    "build" : "27B5019j",
    "path" : "/Applications/Xcode-27.2-beta1.app",
    "runtimes" : [
      {
        "build" : "24B5084k",
        "platform" : "ios",
        "size" : 8163172705,
        "version" : "27.2"
      }
    ],
    "size" : 3585789952,
    "version" : "27.2"
  }
]
```

Stdout then holds the JSON and nothing else; errors stay on stderr with exit 1. The JSON carries
the table's facts as values: sizes in bytes, booleans for `installed` and `active`, dates as
`YYYY-MM-DD`, platforms as `ios`, `tvos`, `watchos` or `visionos`. `version` and `build` are what
`install`, `select` and `remove` take. In `list --json`, `macOS` holds `minimum`, `newest` and
`runsHere`, whether this Mac's macOS is in that range. A value that is not known leaves its key
out: `size` with `--no-size`, `newest` when Apple names no upper bound, `runsHere` when Apple's
system requirements page cannot be fetched or has no row for that Xcode. Nothing found is `[]`,
exit 0. `auth status --json` prints `{"signedIn": true, "source": "keychain"}` (or `"environment"`), or
`signedIn: false` with the `reason` and exit 1.

## Release notes

No login needed.

```
xcodectl release-notes 26.4                  the notes, rendered: colors, bold, italic, clickable links
xcodectl release-notes 26.4 --markdown       the Markdown Apple serves
xcodectl release-notes 26.4 --plain          plain text; also the default when piped
xcodectl release-notes 27 --abridged         what a developer of apps needs to know before upgrading
xcodectl release-notes 26.3 26.4             what 26.4 adds (+) and drops (-) compared to 26.3
xcodectl release-notes 27 --ask "which minimal macOS is required?"
```

Under the title, the notes and `--abridged` give the macOS versions that Xcode runs on and whether
this Mac's is one of them, as the MACOS column of `list` does.

```
$ xcodectl release-notes 27

Xcode 27 Release Notes

macOS: ✓ 26.6 or later; this Mac runs 27.0.0

Update your apps to use new features, and test your apps against API changes.

Overview

Xcode 27 includes Swift 6.4 and SDKs for iOS 27, iPadOS 27, tvOS 27, watchOS 27, macOS 27, and
visionOS 27. Xcode 27 supports on-device debugging in iOS 17 and later, tvOS 17 and later, watchOS
10 and later, and visionOS. Xcode 27 requires a Mac running macOS Tahoe 26.6 or later.

See Xcode Support to learn more about compatible platforms and deployment targets.

General

Resolved Issues

• Fixed: The scheme action toolbar button now treats ‘without building’ variants, obtained by
  holding the Control key, as a one-shot operation and reverts to the standard action afterward.
...
```

### Summary and questions

`--abridged` and `--ask` send the whole notes to a model in one request: OpenRouter, OpenAI or
Gemini with the API key in `OPENROUTER_API_KEY`, `OPENAI_API_KEY` or `GEMINI_API_KEY` (looked up in
that order), or a server of your own, such as Ollama. The default model is `gpt-5.6-luna` on
OpenRouter and OpenAI and `gemini-3.8-flash` on Gemini, through its
[OpenAI compatible API](https://ai.google.dev/gemini-api/docs/openai), all with low reasoning
effort. The spinner names the model, the provider and the key variable in use.

`--abridged` takes five to twenty seconds. The model writes for a typical developer of apps in
Swift: what to know before upgrading, known issues, new features, fixes and deprecations, grouped
by area of Xcode. It keeps only what such a developer would act on and leaves out C++, linkers,
Intel and the catalog of bundled versions. A name in backticks that the notes do not hold as
written is listed under the summary, as models sometimes misspell one.

```
$ xcodectl release-notes 27 --abridged
✔︎ Summarizing with openai/gpt-5.6-luna on OpenRouter (OPENROUTER_API_KEY) [7.8s]

Xcode 27 Release Notes

macOS: ✓ 26.6 or later; this Mac runs 27.0.0

Before you upgrade

• Requirements: Xcode 27 requires macOS Tahoe 26.6 or later.

Known issues

• App Store distribution: Apps using the Hardware-Checked Pointer Arithmetic Slice feature cannot be
  uploaded with automatic signing on macOS Tahoe 26.6; distribute with macOS 27 and Xcode 27 or use
  manual signing.
• Swift compiler: A computed property with an init accessor and array or dictionary literal initial
  value may no longer compile when the getter precedes the accessor; declare the init accessor
  first.
• Address Sanitizer: Address Sanitizer may fail to launch on 27.0 operating systems when building
  with Xcode 26.4 or older; use Xcode 26.5 or later.
• Device Hub: Parallelized simulator tests may not appear in Device Hub even though they are
  running; disable parallelized test runs to watch UI tests.
• Previews & Playgrounds: Standalone Swift files opened by double-clicking in Finder may fail to run
  #Playground or #Preview blocks; use File > Open… or drag them onto the Dock icon.
• Simulator: Some simulator runtimes may reappear after removal and a reboot.

New

• Testing:
  • Test plans can set application-crash handling during UI tests to off, warning, failure, or fatal
    failure.
  • XCTest adds XCUIVoiceOverService for testing VoiceOver focus, spoken output, and navigation.
  • Launch-test templates can run across every supported orientation, localization, and appearance
    combination.
• Previews:
  • iOS previews support arbitrarily sized containers through the new Resizable Canvas mode.
  • You can preview your UI in a different localization.
  • Canvas can display a preview grid for each argument passed to #Preview(arguments:).
• Device Hub: iPhone, iPad, and Apple Watch running iOS 27, iPadOS 27, or watchOS 27 can pair over a
  network with “Pair Nearby Device…”.
• Background Assets:
  • Localized asset packs deliver the appropriate assets based on the user’s preferred languages.
  • Xcode can serve asset packs to apps while debugging on devices through the Run scheme action’s
    Background Asset Packs folder.
• StoreKit Testing: StoreKit configuration files support testing In-App Purchase offer codes,
  subscription bundles, and subscription suites locally.
• Coding Intelligence:
  • Agents can boot simulators, install and launch apps, synthesize touch events, and capture
    screenshots to verify UI behavior.
  • Planning is a first-class workflow with editable Markdown plans that you can review and approve
    before implementation.

Fixed

• Previews: Previewing with an uninstalled runtime now shows a placeholder instead of silently
  falling back to macOS.
• Previews: Code inside #Preview now runs explicitly on the main actor, avoiding concurrency
  warnings or runtime check failures when calling main-actor-isolated APIs.
• Previews & Playgrounds: Previews and #Playground no longer repeatedly restart builds in large
  workspaces after files are written into derived data.
• Testing: The “Test Repetition Mode” setting now repeats individual Swift Testing test cases
  instead of the entire test plan.
• Testing: watchOS unit and UI tests now run on devices.
• Device Hub: Simulator devices no longer disappear from Device Hub because of an
  installation-package timing issue.

Deprecated

• On Demand Resources: On Demand Resources and the NSBundleResourceRequest API are deprecated; use
  Background Assets instead.
• Previews: PreviewProvider and its family of preview modifiers are deprecated.
```

```
$ xcodectl release-notes 27 --ask "which minimal macOS is required?"
Xcode 27 requires a Mac running macOS Tahoe 26.6 or later.

$ xcodectl release-notes 26.4.0 --ask "Are there known issues with Swift Testing?"
Yes. Xcode 26.4 lists three known Swift Testing issues: async XCTest methods with
continueAfterFailure set to false can skip retries; UIImage attachments don’t work for Mac Catalyst
tests (use UIImage.cgImage); and Swift Testing tests may crash at launch on Rosetta destinations
when using Xcode for Apple silicon.
```

Treat answers and summaries as a pointer into the notes, not as the notes.

```
--key-env MY_KEY               read the API key from another environment variable (goes to OpenAI
                               unless --provider says otherwise)
--provider openai|openrouter|gemini
                               use this provider's key although another one is set too
--model <id>                   use this model
--base-url <url> --model <id>  another OpenAI-compatible API; needs no key
```

```
xcodectl release-notes 27 --abridged --base-url http://localhost:11434/v1 --model <model>
```

That is Ollama. Long notes hold about 15k tokens, more than Ollama reads by default: raise its
context, for example with `OLLAMA_CONTEXT_LENGTH=32768`.

## Simulator runtimes

No login needed from iOS 18, tvOS 18, watchOS 11 and visionOS 2 on: Apple serves the runtime catalog
and these runtimes publicly. Older ones, back to iOS 16, tvOS 16, watchOS 9 and visionOS 1, download
with your Apple session, like an Xcode.

```
$ xcodectl list runtimes
PLATFORM  VERSION    BUILD     SIZE    STATUS
iOS       27.2 beta  24B5084k  7.6 GB
iOS       27.1 beta  24A94401  7.3 GB  installed
iOS       27.0       24A434    7.5 GB  installed
tvOS      27.0       24J360    3.5 GB
watchOS   27.0       24R362    3.6 GB
visionOS  27.0       24M362    7.0 GB
```

`xcodectl list ios` (or `tvos`, `watchos`, `visionos`) narrows it, `--stable` and `--beta` pick one
kind, `--all` shows every version instead of the newest major of each platform.

Install the runtime matching an Xcode, or an exact one:

```
xcodectl install ios              # the one matching the active Xcode
xcodectl install tvos 26.0
xcodectl install ios 17           # the newest iOS 17 release: 17.5
xcodectl install ios --xcode 27.0 # through that Xcode, without selecting it
```

Xcode 27 no longer downloads runtimes older than iOS 26, tvOS 26, watchOS 26 and visionOS 26. Through
Xcode 27 or newer, `install` fetches iOS 18, tvOS 18, watchOS 11 and visionOS 2 runtimes, point
releases and betas included, from Apple's public asset server itself and adds them with `simctl`, still
without a login. That needs free space for about twice the runtime while it installs, and the installed
runtime keeps taking about that much: CoreSimulator stores both the runtime bundle and the cryptex
inside it, 16.5 GB for iOS 18.6.

Install Xcode and its runtimes in one go:

```
xcodectl install 27.1 --runtimes ios,watchos
xcodectl install 27.1 --runtimes all      # every platform, about 23 GB
```

`--runtimes none` installs none, for a run that overrides a `runtimes` default from the config file.
`xcodectl upgrade` does this by itself: each new Xcode gets its runtime for every platform that has
a runtime installed, before the old Xcode and the runtimes only it uses go. `--runtimes` names other
platforms, or `none`.

Runtimes are several gigabytes each, and a deleted one only gives its space back once the last
registration referencing it is gone. `remove` says which happened:

```
$ xcodectl remove tvos 27.0
   ✔︎ Removed tvOS 27.0 (24J360)
i Info
  Freed 3.4 GB
```

An interrupted download leaves a registration that `simctl runtime list` does not print while it
still holds gigabytes. `xcodectl installed runtimes` shows those, and `prune` clears them:

```
xcodectl prune --dry-run   # what would go, and how much it frees
xcodectl prune
```

Runtimes back to iOS 16, tvOS 16, watchOS 9 and visionOS 1 are supported. Apple limits iOS 16,
tvOS 16 and watchOS 9 to Xcode 26 and older. Apple Silicon only.

## Install

```
mise use -g github:bonkey/xcodectl
# or
brew install bonkey/tap/xcodectl
# or from source
git clone https://github.com/bonkey/xcodectl && cd xcodectl && just install
```

## Shell completion

Commands, options and their values complete; `upgrade`, `approve`, `select`, `remove` and
`install --xcode` also offer the installed versions, and `remove` the platforms.

```
eval "$(xcodectl --generate-completion-script zsh)"    # ~/.zshrc, after compinit
eval "$(xcodectl --generate-completion-script bash)"   # ~/.bashrc
xcodectl --generate-completion-script fish > ~/.config/fish/completions/xcodectl.fish
```

## First run

```
xcodectl auth login     # a window opens; sign in with your Apple ID and 2FA code
xcodectl install 26.6   # downloads (16 connections), expands, moves to /Applications/Xcode-26.6.app,
                        # then approves it (sudo: license, first-launch packages) and installs
                        # Command Line Tools 26.6 (sudo: softwareupdate)
xcodectl select 26.6    # sudo: xcode-select
```

Two-factor codes (trusted device, SMS) and hardware security keys (YubiKey and other FIDO2 keys,
PIN + touch) both work in the window. Passkeys stored in iCloud Keychain do not.

When the session is missing or Apple no longer accepts it, `install`, `upgrade`, `auth status` and
`auth export` open the same window and carry on once you are signed in. They do so only at a
terminal (never with `--json`) and only for the Keychain session, not for `XCODECTL_SESSION`;
`--no-login` makes them fail instead.

The window starts with the cookies of the last session and stays hidden: while Apple remembers
that browser, it signs you in again without any input. The window shows when Apple asks for your
security key, or after 15 seconds without a session, for instance when Apple wants your password.

## CI (self-hosted runner)

On your Mac: `xcodectl auth export --copy`. It asks Apple whether the session still holds and
copies it with a fresh download ticket; when Apple rejects it, the sign-in window opens and the
new session is copied (`--no-login` fails instead). On the runner, once:
`xcodectl auth import --paste` checks the blob with Apple the same way and stores it in that
runner's Keychain. `xcodectl auth export | pbcopy` and `pbpaste | xcodectl auth import` are the
same by hand. Then in the job:

```
xcodectl install 26.6 --select
```

Alternatively pass the blob per job as `XCODECTL_SESSION`; it is then used in memory only.

Over plain ssh the login Keychain is locked (macOS gives ssh logins their own security session),
so `auth import` and `install` fail with "User interaction is not allowed". Run
`security unlock-keychain` in that ssh session first, do the import from a GUI session (Screen
Sharing), or use `XCODECTL_SESSION`. Runners launched in the logged-in session are not affected.
Apple's login session lasts from a day to a few weeks, depending on the region;
`xcodectl auth status` asks Apple whether it still holds and exits 1 when not (`--json` adds
`signedIn` and the reason on stdout). When it has expired,
`xcodectl auth export --copy` signs you in again and copies the new session in one go;
`auth status` does the same without printing it. The window opens only when someone is at
the terminal and only for the Keychain session, not for `XCODECTL_SESSION`.

## Configuration

`xcodectl config init` writes `~/.config/xcodectl/config.toml` (or the path in `XCODECTL_CONFIG`)
with every key commented out, a `[table]` per command. Keys are the flags without `--`; a flag
takes `true` or `false`, an option a quoted string. Keys before the first table reach every
command that has them.

```toml
login = false            # never open the sign-in window: install, upgrade, auth status, auth export

[install]
approve = false          # install --no-approve
clt = false
runtimes = "ios,watchos"

[list]
order = "by-date"

[release-notes]
plain = true
```

A flag typed on the command line wins over its table, which wins over the shared keys. A value
that does not fit the run is ignored: with `clt = false` under `[install]`, `xcodectl install ios`
installs the runtime as if the key were not there. `upgrade` reads `[upgrade]` only; the `install`
and `remove` it runs inside do not read the file. A shared `runtimes` key reaches both `install` and
`upgrade`; `runtimes = "none"` under `[upgrade]` keeps upgrades from installing runtimes.
An unknown key or table, or a value a flag cannot take, fails every command that reads the file;
`xcodectl config check` lists every problem, or every setting the file makes, and exits 1 when
something is wrong.

## How it works

- Versions and direct download URLs: `https://xcodereleases.com/data.json`.
- macOS versions (`list`, `release-notes`): the range an Xcode runs on, `26.2–26.x` or `26.6 or
  later`, behind `✓` when this Mac's macOS is in it and `✗` when it is too old or too new. The
  oldest macOS is the release's `requires` in `data.json`, exact for each beta. The newest comes
  from the "Supported macOS Versions" column of
  `https://developer.apple.com/xcode/system-requirements/`: "26.x" covers every 26 release, "or
  later" sets no limit. A release takes the row of its version, else of its major.minor (26.4 is
  listed as 26.4.1); betas take the row of their version ("Xcode 27.1 beta", "Xcode 27" for the
  27.0 betas). Versions the page does not list (before 14) show `from 12.5`, without a mark. When
  the page cannot be fetched, its cached copy stands in; without one, every range reads `from …`
  and only a macOS that is too old gets its `✗`.
- Auth: Apple's portal sets a login session in the window; the tool keeps only the `apple.com`
  cookies, in the Keychain. The next sign-in window starts with all of them except the login cookie
  (`myacinfo`) and the download ticket, so Apple sees a browser it trusts and usually signs it in
  without input. WebKit refuses WebAuthn for apple.com in third-party apps,
  so the page's `navigator.credentials.get` is routed to libfido2, which drives the security key.
  Each download needs a ~24 h `ADCDownloadAuth` cookie, which the tool fetches itself from Apple's
  download-list endpoint using that session.
- Download: 16 parallel HTTP range requests on URLSession into one preallocated file, resumable.
- Expand: in-process [unxip](https://github.com/saagarjha/unxip).
- Move: a rename into `/Applications`. On a Mac that keeps its user out of `/Applications`, the
  archive expands in `~/.xcodectl/tmp` and `sudo mv` moves the app in, so `install` itself never
  needs to run under sudo. When the move fails, the expanded app stays there and the next
  `install` of that version moves it in without downloading or expanding again (an install of
  another version in between removes it).
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
  version share a page. `--abridged` and `--ask` send the whole notes in one request to an
  OpenAI-compatible API, through AnyLanguageModel: the summary follows a fixed brief and set of
  headings, the answer comes in one to three sentences. Notes older than the documentation site (archived HTML, PDFs) are not
  available.
- `remove`: deletes the simulator runtimes only this Xcode uses, then the app bundle. Which runtimes
  an Xcode uses is what `simctl runtime match list` answers under that Xcode's `DEVELOPER_DIR`: the
  runtime CoreSimulator picks for each of its SDKs, often a newer build than the SDK's own, so the
  SDK builds in `data.json` cannot tell. When the picked build is not installed, the SDK runs on
  another build of its version, so the installed runtimes of that platform and major.minor count.
  Runtimes go first because simctl comes with Xcode and may
  not run once the Xcode is gone. System packages and DerivedData are shared between Xcode versions
  and stay.
- Simulator runtimes: the catalog is Apple's public
  `https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex`, read for
  its `cryptexDiskImage` and `diskImage` entries and deduplicated to one row per build, preferring the
  Apple Silicon artifact over the universal one. Apple delivers cryptexes as MobileAssets into a
  SIP-protected store that only Xcode can write, so their download is `xcodebuild
  -downloadPlatform`, pointed at a chosen Xcode through `DEVELOPER_DIR` so it needs neither
  `xcode-select` nor sudo; without a version, Xcode picks the runtime matching itself. Xcode 27 and
  newer refuse a cryptex whose index entry and MobileAsset name no architectures, which is every one
  before iOS 26, so through those Xcodes the tool installs such a runtime itself: Apple's public asset
  server (`gdmf.apple.com/v2/assets`, the request xcodebuild makes) answers with the URL of an
  encrypted `.aar` on `updates.cdn-apple.com`, its key and its SHA-256. The archive downloads like an
  Xcode into `~/.xcodectl/cache/`, without a session, and is checked against that SHA-256; AppleArchive
  decrypts it and expands the disk image inside it next to it, and `simctl runtime add` registers that.
  The archive goes once expanded and the image once registered. A disk image
  is a `.dmg` on `download.developer.apple.com` behind the same ticket as an Xcode; it downloads like
  one into `~/.xcodectl/cache/` and `simctl runtime add` registers it, copying the image into
  CoreSimulator's own store, so the download is deleted afterwards. The add also leaves a staged copy
  in CoreSimulator's cryptex inbox, which would keep the image's full size after the runtime is
  removed; `simctl runtime scan-and-mount` right after the add clears it. Removal is
  `simctl runtime delete`, which frees the asset behind a runtime only once the last registration
  referencing it is gone and says nothing when it skips that, so the tool waits for the deletion to
  finish and then reports whether the space actually came back. When simctl reports the runtime removed
  but its asset not reclaimed (SimDiskImageError 30), the tool checks the asset directory itself, waits
  briefly for a purge still in flight, and fails only if the asset really stays.

Files: `~/.xcodectl/cache/` (downloads in flight, a runtime image being added, cached version list,
system requirements page and simulator runtime index), only during such an install
`~/.xcodectl/tmp/`, and `~/.config/xcodectl/config.toml` when `config init` wrote it. Nothing else.
