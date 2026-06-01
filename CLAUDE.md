# CLAUDE.md

Agent notes for working in this repo. README.md, DESIGN.md, and CONTRIBUTING.md cover the *why* and the human workflows; this file covers things that are easy for an agent to miss or rediscover.

## Adding a new format

Five required places, plus a couple of optional ones. Miss a required one and either the format won't preview, integration tests fail, or `make test` fails on the SUPPORTED.md drift check:

1. **`QLOmni/QLOmni/Info.plist`** – the UTI declaration. Use `UTExportedTypeDeclarations` with a `user.*` identifier for a novel UTI we own; use `UTImportedTypeDeclarations` with a real reverse-DNS identifier for a UTI that already exists in the ecosystem and we're declaring as a fallback (e.g. `net.daringfireball.markdown`, `org.iso.sql`). DESIGN.md "UTI identifier choice" and "Exported vs Imported declarations" cover the rationale for picking one shape over the other. For a `user.*` UTI, prefer listing `public.plain-text` as the only `UTTypeConformsTo` parent. Do **not** add `public.xml` as a sibling parent – it preempts the route to `qldisplay.Text` and breaks preview. See DESIGN.md "Sibling-parent preemption: the `public.xml` case" for why; other candidate siblings should be tested (e.g. via the install + spacebar cycle), not assumed safe.
2. **`QLOmniExtension/Info.plist`** (only sometimes) – add to `QLSupportedContentTypes` *only if* QLOmni needs to render the format itself. If the UTI from step 1 conforms to `public.plain-text`, the format routes through the system text generator and QLOmni never sees it. The appex's current list (`public.unix-executable`, `public.yaml`, `public.toml`, `com.microsoft.ini`, `public.css`, `public.ndjson`) is the set we've found macOS won't route to a usable text renderer on its own – the underlying reason is in DESIGN.md "Why some files don't preview" case 2 (UTIs that conform to `public.text` but not `public.plain-text`). To verify an entry is still needed, remove it, run `make install`, and spacebar-preview a fixture of that type; if it previews cleanly without us, the entry is dead. Separately, the appex also claims `public.data` and `public.content` to handle files tagged directly with those wildcard UTIs (extensionless files, dotfiles); see DESIGN.md "Files tagged directly as `public.data`."
3. **`integration/fixtures/sample.<ext>`** – a small, real-shape fixture.
4. **`integration/run.sh`** – `assert_strict` if no other declarer is expected to compete (the `user.*` case is almost always strict); `assert_lenient` if Xcode / CoreTypes / etc. may legitimately also claim the extension. Mechanically: `assert_strict` fails unless `mdls` reports the exact UTI we declared; `assert_lenient` fails only if the resolved UTI is `dyn.*` (synthetic / unrouted) and otherwise accepts whichever declarer won, reporting the winner. Picking strict when a competing declarer exists makes the test flaky on machines that have the competitor installed; picking lenient when nobody competes silently masks a regression where our declaration stops registering.
5. **`make supported`** – regenerate `SUPPORTED.md`. `make test` runs a drift check, so skipping this fails the next test run.

Optional:

- **README.md** – only if the format is interesting enough to call out in the "What it fixes" highlights. Routine additions live in `SUPPORTED.md` only.
- **`tools/gen-supported.sh`** – only if step 2 added a UTI to `QLSupportedContentTypes` that *isn't* declared in the host plist (`QLOmni/QLOmni/Info.plist`, the file from step 1). Today's only such case is `public.yaml`. Extend `supplemental_map()` with the new UTI and the extension/description pair(s); `extract_supplemental()` checks the appex's `QLSupportedContentTypes` at generation time and only emits rows for UTIs actually present there, so the new entry surfaces automatically once you add the UTI to the appex plist (and disappears if you remove it).

## `qlmanage -p` is not headless

It opens a QuickLook panel (same effect as pressing spacebar in Finder). Stdout is informational at best, and the exit code is mostly useless: it's `0` whether QL renders successfully, declines to render, or falls back to a generic placeholder. The one observed exception is when a system display bundle crashes mid-render (e.g. `public.image` on a text file aborts with `SIGABRT` and propagates a non-zero exit), but that's a narrow signal and doesn't generalize to "rendered correctly." Treat success-or-failure of rendering as visible only on the on-screen panel; when you need a human eye, ask the user to spacebar-preview a fixture.

For headless checks of UTI dispatch, use `mdls -name kMDItemContentType -name kMDItemContentTypeTree <file>` and `lsregister -dump`. The project ships `tools/uti.swift` and `tools/mdls-summary.sh` as wrappers; `tools/uti.swift` queries Launch Services live, so prefer it right after a registration change.

To survey contention across every declared extension at once (rather than one-at-a-time), run `make audit-collisions`. It splits output into different-UTI conflicts (real divergence with another bundle) and same-UTI imports (we and they import the same identifier, no effective conflict). Useful before adding new declarations, and after macOS updates.

## Cache layers

`mds` (Spotlight metadata), Launch Services, and QuickLook dispatch each cache state, and they don't always invalidate together. After a `make install`, `mdls` can lag the live Launch Services view by seconds; `integration/run.sh` already retries `read_uti` to absorb this. If a single observation contradicts what README.md or DESIGN.md says should happen, repeat it (and check `tools/uti.swift`) before concluding the docs are wrong – odds are it's a cache, not a real disagreement.

## Truncation cap

`PreviewRenderer.truncationLimit` in `QLOmniExtension/PreviewRenderer.swift` is currently 1 MiB. The number is arbitrary, not derived from any documented `QLPreviewReply` ceiling. Don't change it casually – it applies to every supported type, and the right value for a bump is empirical (generate fixtures at increasing sizes, have the user spacebar-preview each, find the comfortable max). The truncation tests in `QLOmniTests/PreviewRendererTests.swift` reference the constant directly, so they follow any change automatically.

## Build warnings to know about

If `xcodebuild` emits `warning: The Copy Bundle Resources build phase contains this target's Info.plist file ...`, that's the file-system-synchronized-group / new-app-template interaction documented in DESIGN.md "File-system-synchronized groups vs the new-app template." The fix is a `PBXFileSystemSynchronizedBuildFileExceptionSet` on the affected target.
