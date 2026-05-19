#!/usr/bin/env swift
// uti.swift -- query LaunchServices' live UTI table for a filename extension.
//
// Why this exists: `mdls -name kMDItemContentType <file>` reads from a Spotlight
// metadata cache that survives `lsregister` updates. Right after a registration
// change (e.g. unregistering Xcode to test how a contested extension would behave
// without it), `mdls` can return stale UTIs for minutes. Even rename round-trips
// and `mdimport` may fail to bust the cache. The UTType API hits LaunchServices
// directly and returns whatever the system would dispatch on right now.
//
// Usage:
//   ./tools/uti.swift gs
//   ./tools/uti.swift jsonc toml ini
//
// Output for each extension:
//   <ext>: <UTI> [ +plainText | +text | -text ]
//          supertypes: <sorted UTI list>

import Foundation
import UniformTypeIdentifiers

let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: uti.swift <ext> [<ext> ...]\n".data(using: .utf8)!)
    exit(2)
}

for ext in args {
    let bare = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
    guard let type = UTType(filenameExtension: bare) else {
        print(".\(bare): no UTType")
        continue
    }
    let plain = type.conforms(to: .plainText) ? "+plainText" : (type.conforms(to: .text) ? "+text" : "-text")
    let supers = type.supertypes.map { $0.identifier }.sorted().joined(separator: ", ")
    print(".\(bare): \(type.identifier) [\(plain)]")
    print("    supertypes: \(supers)")
}
