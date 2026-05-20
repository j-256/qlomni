# CLAUDE.md

Agent notes for working in this repo. README.md, DESIGN.md, and CONTRIBUTING.md cover the *why* and the human workflows; this file covers things that are easy for an agent to miss or rediscover.

## Adding a new format

Five required places, plus a couple of optional ones. Miss a required one and either the format won't preview, integration tests fail, or `make test` fails on the SUPPORTED.md drift check:

1. **`QLOmni/QLOmni/Info.plist`** – the UTI declaration. Use `UTExportedTypeDeclarations` with a `user.*` identifier for a novel UTI we own; use `UTImportedTypeDeclarations` with a real reverse-DNS identifier for a UTI that already exists in the ecosystem and we're declaring as a fallback (e.g. `net.daringfireball.markdown`, `org.iso.sql`).
2. **`QLOmniExtension/Info.plist`** (only sometimes) – add to `QLSupportedContentTypes` *only if* QLOmni needs to render the format itself. If the UTI from step 1 conforms to `public.plain-text`, the format routes through the system text generator and QLOmni never sees it. The appex's current list (`public.unix-executable`, `public.yaml`, `public.toml`, `com.microsoft.ini`) is exactly the formats macOS won't route on its own.
3. **`integration/fixtures/sample.<ext>`** – a small, real-shape fixture.
4. **`integration/run.sh`** – `assert_strict` if no other declarer is expected to compete (the `user.*` case is almost always strict); `assert_lenient` if Xcode / CoreTypes / etc. may legitimately also claim the extension.
5. **`make supported`** – regenerate `SUPPORTED.md`. `make test` runs a drift check, so skipping this fails the next test run.

Optional:

- **README.md** – only if the format is interesting enough to call out in the "What it fixes" highlights. Routine additions live in `SUPPORTED.md` only.
- **`tools/gen-supported.sh`** – only if step 2 added a UTI to `QLSupportedContentTypes` that *isn't* declared in the host plist. Today's only such case is `public.yaml`. Extend `supplemental_map()` with the new UTI and the extension/description pair(s); the gating in `extract_supplemental()` will pick it up automatically.

## `qlmanage -p` is not headless

It opens a QuickLook panel (same effect as pressing spacebar in Finder) and returns nothing the agent can read. Don't use it as evidence in your own reasoning; when you need a human eye on rendering, ask the user to spacebar-preview a fixture.

For headless checks of UTI dispatch, use `mdls -name kMDItemContentType -name kMDItemContentTypeTree <file>` and `lsregister -dump`. The project ships `tools/uti.swift` and `tools/mdls-summary.sh` as wrappers; `tools/uti.swift` queries Launch Services live, so prefer it right after a registration change.

## Cache layers

`mds` (Spotlight metadata), Launch Services, and QuickLook dispatch each cache state, and they don't always invalidate together. After a `make install`, `mdls` can lag the live Launch Services view by seconds; `integration/run.sh` already retries `read_uti` to absorb this. If a single observation contradicts what README.md or DESIGN.md says should happen, repeat it (and check `tools/uti.swift`) before concluding the docs are wrong – odds are it's a cache, not a real disagreement.

## Truncation cap

`PreviewRenderer.truncationLimit` in `QLOmniExtension/PreviewRenderer.swift` is currently 1 MiB. The number is arbitrary, not derived from any documented `QLPreviewReply` ceiling. Don't change it casually – it applies to every supported type, and the right value for a bump is empirical (generate fixtures at increasing sizes, have the user spacebar-preview each, find the comfortable max). The truncation tests in `QLOmniTests/PreviewRendererTests.swift` reference the constant directly, so they follow any change automatically.
