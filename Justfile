# xcodectl tasks

# Debug build
build:
    swift build

# Universal release build; path printed by `just release-bin`.
# One build per arch, then lipo: a single --arch arm64 --arch x86_64 build does not
# find the static libraries of the LibFido2Swift xcframeworks (ld: -lcbor).
release-build:
    #!/usr/bin/env bash
    set -euo pipefail
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    mkdir -p .build/universal
    lipo -create -output .build/universal/xcodectl \
        "$(swift build -c release --arch arm64 --show-bin-path)/xcodectl" \
        "$(swift build -c release --arch x86_64 --show-bin-path)/xcodectl"

# Directory of the universal release binary
release-bin:
    @echo "{{justfile_directory()}}/.build/universal"

# Run from source
run *ARGS:
    swift run xcodectl {{ARGS}}

test:
    swift test

# Format check
lint:
    swiftformat Sources Tests --lint

# Format in place
fmt:
    swiftformat Sources Tests

# Copy the release binary to ~/.local/bin
install: release-build
    mkdir -p ~/.local/bin
    cp "$(just release-bin)/xcodectl" ~/.local/bin/xcodectl

clean:
    rm -rf .build

# Bump Version.swift (patch by default, or VER), tag, push, build universal, publish GitHub release.
# mise (github:bonkey/xcodectl) and the brew formula resolve versions from GitHub releases.
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
    just release-build
    git tag "v$ver" 2>/dev/null || [ "$(git rev-parse "v$ver")" = "$(git rev-parse HEAD)" ]
    git push && git push origin "v$ver"
    asset="xcodectl-$ver-macos-universal.tar.gz"
    tar -C "$(just release-bin)" -czf "$asset" xcodectl
    shasum -a 256 "$asset" > "$asset.sha256"
    gh release create "v$ver" "$asset" "$asset.sha256" --title "v$ver" --generate-notes
    rm -f "$asset" "$asset.sha256"
