//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation

/// One release the way data.json describes it.
func makeRelease(
    _ number: String,
    _ build: String,
    _ date: (Int, Int, Int),
    kind: Release.Kind = .init(release: true),
    requires: String? = nil)
    -> Release
{
    Release(
        name: "Xcode",
        version: .init(number: number, build: build, release: kind),
        date: .init(year: date.0, month: date.1, day: date.2),
        requires: requires,
        links: nil)
}

func makeApp(_ name: String, version: String, build: String) -> InstalledXcode {
    InstalledXcode(
        path: URL(fileURLWithPath: "/Applications").appendingPathComponent(name),
        version: version,
        build: build)
}
