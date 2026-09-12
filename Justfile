# xcodectl tasks

# Debug build
build:
    swift build

# Universal release build; path printed by `just release-bin`
release-build:
    swift build -c release --arch arm64 --arch x86_64

# Directory of the universal release binary
release-bin:
    @swift build -c release --arch arm64 --arch x86_64 --show-bin-path

# Run from source
run *ARGS:
    swift run xcodectl {{ARGS}}

test:
    swift test

# Format check
lint:
    swiftformat --lint Sources

# Format in place
fmt:
    swiftformat Sources

# Copy the release binary to ~/.local/bin
install: release-build
    mkdir -p ~/.local/bin
    cp "$(just release-bin)/xcodectl" ~/.local/bin/xcodectl

clean:
    rm -rf .build

# Bump Version.swift (patch by default, or VER), tag, push, build universal, publish GitHub release.
# mise (ubi:bonkey/xcodectl) and the brew formula resolve versions from GitHub releases.
release VER="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -z "$(git status --porcelain)" ] || { echo "working tree is dirty; commit first" >&2; exit 1; }
    current=$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/xcodectl/Version.swift)
    ver="{{VER}}"
    if [ -z "$ver" ]; then
        IFS=. read -r major minor patch <<<"$current"
        ver="$major.$minor.$((patch + 1))"
    fi
    echo "Releasing v$ver (was $current)"
    if [ "$ver" != "$current" ]; then
        sed -i '' "s/^let version = \".*\"$/let version = \"$ver\"/" Sources/xcodectl/Version.swift
        git commit -qam "Release $ver"
    fi
    swift build -c release --arch arm64 --arch x86_64
    git tag "v$ver"
    git push --follow-tags
    asset="xcodectl-$ver-macos-universal.tar.gz"
    tar -C "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)" -czf "$asset" xcodectl
    shasum -a 256 "$asset" > "$asset.sha256"
    gh release create "v$ver" "$asset" "$asset.sha256" --title "v$ver" --generate-notes
    rm -f "$asset" "$asset.sha256"
