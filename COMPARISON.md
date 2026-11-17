# QLOmni vs. QLStephenSwift

A side-by-side of two macOS QuickLook Preview Extensions that descend from [QLStephen](https://github.com/whomwah/qlstephen): [QLOmni](README.md) (this project) and [QLStephenSwift](https://github.com/MyCometG3/QLStephenSwift). Both target the same general problem (text files that macOS won't preview out of the box) but make different choices about scope, dispatch strategy, and rendering.

## At a glance

|                              | QLStephenSwift                                 | QLOmni                                                   |
|------------------------------|------------------------------------------------|----------------------------------------------------------|
| Minimum macOS                | 15.0 (Sequoia)                                 | 12.0 (Monterey)                                          |
| Distribution                 | Homebrew Cask (personal tap), GitHub Releases  | Homebrew Cask (personal tap), GitHub Releases             |

## Scope: what each is trying to fix

|                                                                | QLStephenSwift                                                                          | QLOmni                                                                                                                                       |
|----------------------------------------------------------------|-----------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| Stated mission                                                 | Modern Swift rewrite of QLStephen for **plain-text files without extensions**.          | Preview the **set of text-shaped files macOS itself doesn't** – extensionless, unrecognized extensions, and UTIs that don't route to a handler. |
| Routing strategy: appex claims                                 | Wildcard UTIs `public.data`, `public.content`, and `public.unix-executable`. By the wildcard-claim dispatch rule, these only fire when the file's *concrete* UTI matches – i.e. genuinely extensionless files, dotfiles-with-no-further-dot, and Unix executables. | The same wildcards, plus specific non-wildcard UTIs the system text generator skips, including `public.yaml`, `public.toml`, `com.getdropbox.dropbox.dropboxignore`, and `public.ndjson`. |
| Routing strategy: host plist declarations                      | None.                                                                                   | Per-extension UTI declarations covering [the extensions in `SUPPORTED.md`](SUPPORTED.md) (`UTExportedTypeDeclarations` for novel UTIs, `UTImportedTypeDeclarations` for ones already in the ecosystem). These give unknown extensions a real UTI so they resolve to something other than `dyn.*`. |
| Where rendering happens                                        | Always inside the appex.                                                                | Mostly **outside** QLOmni – for declared extensions that conform to `public.plain-text`, the system's bundled text generator does the rendering. The appex only handles UTIs the system won't route on its own. |

## File-coverage matrix

Cells reflect each project's *design intent and declared UTIs*, not exhaustive empirical testing on every macOS version. "✅" means the project is designed to make this case preview; "❌" means it isn't. "Same" means the platform behavior is identical with or without the tool.

| Case                                                                                            | QLStephenSwift                                | QLOmni                                                  | Notes                                                                                                                                                                      |
|-------------------------------------------------------------------------------------------------|-----------------------------------------------|---------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Extensionless plain-text (`README`, `Makefile`, `LICENSE`, `CHANGELOG`)                          | ✅ via `public.data`                          | ✅ via `public.data`                                    | Both projects claim `public.data` from the appex.                                                                                                                          |
| Extensionless executable scripts (e.g. `myscript` with shebang, no `.sh`)                        | ✅ via `public.unix-executable`               | ✅ via `public.unix-executable`                         | Same approach.                                                                                                                                                             |
| Dotfiles (`.gitignore`, `.bashrc`, `.htaccess`, `.vimrc`)                                        | ✅ via `public.data`                          | ✅ via `public.data`                                    | macOS tags single-component dotfiles directly as `public.data`. Both catch them.                                                                                            |
| Unknown extensions, no other declarer (`.md`, `.jsonc`, `.har`, `.tf`, `.editorconfig`, etc.) | ❌                                            | ✅ via per-extension UTI declarations                   | Without a UTI declarer, macOS assigns a synthetic `dyn.*` type. `dyn.*` *does* conform to `public.data` in the type graph (you can see it in `mdls -name kMDItemContentTypeTree`), but QuickLook dispatches by concrete UTI rather than walking the conformance tree to find a wildcard claim, so a `public.data` claim doesn't catch it. QLOmni's per-extension declarations give these files real UTIs. See [DESIGN.md § how wildcard-UTI claims actually dispatch](DESIGN.md#how-wildcard-uti-claims-actually-dispatch). |
| Source-code extensions macOS doesn't ship (`.rs`, `.go`, `.kt`, `.cs`, `.scala`, `.dart`, `.vue`, `.svelte`, etc.) | ❌                                            | ✅                                                      | Same root cause as the row above.                                                                                                                                          |
| Environment-variant configs (`.env.production`, `docker-compose.yml.example`, `nginx.conf.staging`, etc.) | ❌                                            | ✅ via per-suffix UTI declarations                       | UTI lookup keys on the substring after the *last* dot, so `.env.production` is looked up as extension `production`. QLOmni declares common variant suffixes (`.example`, `.sample`, `.local`, `.development`, `.dev`, `.production`, `.prod`, `.staging`, `.test`) as `user.*` UTIs conforming to `public.plain-text`. See [DESIGN.md § environment-variant suffixes](DESIGN.md#environment-variant-suffixes). |
| YAML (`.yaml`, `.yml`)                                                                          | ❌                                            | ✅                                                      | YAML resolves to `public.yaml` (conforms to `public.text` but not `public.plain-text`). System text generator skips it; QLOmni's appex claims it directly.                  |
| TOML (`.toml`)                                                                                  | ❌                                            | ✅                                                      | Same shape as YAML.                                                                                                                                                        |
| INI (`.ini`)                                                                                    | ❌                                            | ✅                                                      | Same shape as YAML.                                                                                                                                                        |
| CSS (`.css`)                                                                                    | ❌                                            | ✅                                                      | Same shape as YAML.                                                                                                                                                        |
| JSON Lines (`.jsonl`, `.ndjson`)                                                                | ❌                                            | ✅                                                      | Two shapes here. `.jsonl` is the unknown-extension case (caught by QLOmni's `user.jsonl` declaration). `.ndjson` is the YAML case: macOS CoreTypes declares `public.ndjson` conforming to `public.text` but not `public.plain-text`, so the system text generator skips it; QLOmni's appex claims `public.ndjson` directly.                                                                |
| Dropbox ignore rules (`.dropboxignore`)                                                        | ❌                                            | ✅                                                      | Dropbox exports `com.getdropbox.dropbox.dropboxignore` with generic data parents rather than a text parent. QLOmni imports that canonical identifier as a fallback and claims it from the appex.                                           |
| Markdown (`.md`, `.markdown`)                                                                   | ❌                                            | ✅                                                      | QLOmni declares `net.daringfireball.markdown` as imported.                                                                                                                 |
| TypeScript (`.ts`)                                                                              | ❌                                            | ❌                                                      | Platform limitation: macOS CoreTypes claims `.ts` as `public.mpeg-2-transport-stream` and routes it to a built-in display bundle no third-party Preview Extension can displace. Neither project can fix this.                                            |
| TypeScript (`.tsx`)                                                                             | ❌                                            | ✅                                                      | `.tsx` doesn't collide with the MPEG-TS handler.                                                                                                                            |
| `.txt` and other extensions macOS already previews                                              | Same (system handler)                         | Same (system handler)                                   | Neither project tries to displace working system handlers.                                                                                                                  |

QLOmni publishes the full per-extension list in [`SUPPORTED.md`](SUPPORTED.md).

### Why the QLStephenSwift coverage is narrower

QLStephenSwift's gaps aren't in its rendering code – its `FileAnalyzer` and `TextFormatter` would happily decode and display any text-shaped bytes the appex receives. The gaps are in *routing*: the appex never gets the preview request in the first place.

QuickLook dispatches by a file's concrete UTI. It doesn't walk up the conformance tree to find a wildcard ancestor (see [DESIGN.md § how wildcard-UTI claims actually dispatch](DESIGN.md#how-wildcard-uti-claims-actually-dispatch)). So even though `public.data` is in the conformance tree of `.yaml` (concrete UTI `public.yaml`), `.css` (`public.css`), and unknown-extension files (`dyn.*`), QLStephenSwift's `public.data` claim doesn't catch any of them. The appex only fires when the concrete UTI is exactly one of its three claimed wildcards.

Two changes would close the gap on QLStephenSwift's side:

- Add specific non-wildcard UTIs (`public.yaml`, `public.css`, etc.) to its appex's `QLSupportedContentTypes`. This is what QLOmni does for concrete UTIs the system text generator skips.
- Declare per-extension UTIs in a host plist for unknown extensions, so they resolve to a real UTI instead of `dyn.*`. This is what QLOmni does for the extensions in [`SUPPORTED.md`](SUPPORTED.md).

QLStephenSwift's README explicitly declines the second, reasoning that declaring a UTI conforming to `public.plain-text` would invite the system text generator to take over.

### The precedence rule is asymmetric

The technical foundation for QLOmni's strategy: third-party Preview Extensions and the system's bundled handlers don't compete on equal terms. The rule cuts in opposite directions depending on which UTI is in play.

- **For UTIs the system has a strong handler for** (`public.plain-text` is the canonical case), the system wins. A third-party extension claiming `public.plain-text` would simply not fire for `.txt` files – the bundled text generator is preferred regardless. Declaring it has no effect.
- **For UTIs the system has no strong handler for** (`public.yaml`, `public.css`, `public.toml`, `com.microsoft.ini`), a third-party extension claiming the UTI *does* fire. This is what QLOmni's appex relies on to render those four formats.

QLStephenSwift's README applies the rule one-directionally: third-party loses to system, therefore declare nothing. QLOmni reads the rule as letting a project declare strategically: avoid the UTIs the system handles strongly, claim the ones it doesn't, and route everything else through the system text generator by way of conformance.

The QLStephenSwift README states specifically that declaring `public.plain-text` would let "the system's text handler take over for `.txt` files." In QLOmni's reading of the dispatch rule, declaring `public.plain-text` doesn't *broaden* the system's win – the system already handles `.txt` regardless of what any third-party extension declares, so the declaration has no effect either way. This is the load-bearing difference between the two projects' strategies: QLStephenSwift declines per-extension UTI declarations on the basis that they'd cede ground to the system; QLOmni's strategy is built on the observation that they don't.

## Rendering features

| Feature                                                                       | QLStephenSwift                                                       | QLOmni                                                      | Notes                                                                                                                                                                                  |
|-------------------------------------------------------------------------------|----------------------------------------------------------------------|-------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Plain-text rendering                                                          | ✅                                                                   | ✅                                                          |                                                                                                                                                                                        |
| Optional line numbers (configurable separator)                                | ✅                                                                   | ❌                                                          | QLStephenSwift offers space / colon / pipe / tab; auto-scaling digit width.                                                                                                            |
| RTF rendering with custom fonts, colors, tab widths                           | ✅                                                                   | ❌                                                          | QLStephenSwift renders styled output when toggled; UI exposes monospaced-font picker, light/dark mode color pairs.                                                                     |
| Light/Dark mode color separation                                              | ✅                                                                   | ❌                                                          | Only relevant when QLStephenSwift's RTF mode is on.                                                                                                                                    |
| Line-ending preservation (LF / CRLF / CR) | ✅ (explicit detection and preservation) | ✅ (preserved during decoding) | QLOmni decodes text and re-encodes it as UTF-8 without normalizing line endings. |
| Encoding detection | ✅ (Unicode BOMs, ISO-2022-JP, ICU statistical detection, CJK + Western fallbacks) | ✅ (Unicode BOMs, ISO-2022-JP, Foundation detection, CJK + Western fallbacks) | QLOmni's appex decodes supported input encodings and returns UTF-8. Files routed to the system text generator use that renderer's encoding support. |
| Lossy fallback for invalid sequences | ✅ (U+FFFD substitution) | ❌ | QLOmni uses non-lossy decoding and rejects malformed BOM-tagged input. BOM-less input goes through encoding detection and fallbacks. |
| Syntax highlighting                                                           | ❌                                                                   | ❌                                                          | Neither.                                                                                                                                                                                |

## Configuration & UX

| Aspect                                          | QLStephenSwift                                                                                              | QLOmni                                                                                                       |
|-------------------------------------------------|-------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| Host app | SwiftUI settings window for max file size, line numbers, and RTF settings | Minimal SwiftUI host window with an informational message; no settings |
| Settings persistence                            | App Group UserDefaults (`group.com.mycometg3.qlstephenswift`)                                                | None                                                                                                          |
| Per-user customization                          | ✅                                                                                                           | ❌                                                                                                            |
| Migration from original QLStephen               | ✅ (auto-migrates `maxFileSize` from `com.whomwah.quicklookstephen` on first launch)                         | ❌ (no settings to migrate – QLOmni doesn't expose any user-configurable values)                              |

## Architecture & implementation

| Aspect                                          | QLStephenSwift                                                         | QLOmni                                                                |
|-------------------------------------------------|------------------------------------------------------------------------|-----------------------------------------------------------------------|
| Extension type                                  | Modern App Extension (`.appex`) using `QLPreviewProvider`              | Modern App Extension (`.appex`) using `QLPreviewProvider`             |
| Reads the whole file? | Up to 5 MiB for analysis; up to user-set cap for render | Reads up to 1 MiB plus a small lookahead to handle truncated multibyte characters; returns at most 1 MiB of UTF-8 |
| External dependencies                           | None (pure Swift / Foundation / AppKit / Cocoa / Quartz)               | None (pure Swift / Foundation / Quartz)                               |
| Test surface | XCTest unit tests (`TextFormatterTests`, `QLStephenSwiftTests`) + UI tests; bundled `test_files/` fixtures (CJK encodings, binaries, scripts) | XCTest renderer tests; shell tests for release safeguards and documentation drift; local integration tests for UTI resolution and PluginKit registration |
| CI                                              | None (no user-authored build or test workflow; only GitHub-managed Copilot workflows exist) | `make test` runs in CI on push/PR; integration tests are local-only (require install + `mdls`) |
| Tooling shipped in repo                         | None beyond Xcode project                                              | `tools/uti.swift`, `tools/mdls-summary.sh`, `tools/gen-supported.sh`, `Makefile` targets including `make supported`, `make purge-ls`, `make test-integration` |

## Binary detection

| Aspect                                          | QLStephenSwift                                                          | QLOmni                                                          |
|-------------------------------------------------|-------------------------------------------------------------------------|-----------------------------------------------------------------|
| Sample window                                   | 8 KiB sniff for files >5 MiB; full file read for files ≤5 MiB           | 8 KiB sniff (`sniffSize = 8192`)                                |
| NUL-byte rejection | ✅ | ✅ (for input without a Unicode BOM) |
| Control-character ratio threshold | ✅ (>30% non-{TAB/LF/CR/FF/ESC} → binary) | ✅ (same threshold and allowed controls; applied to input without a Unicode BOM) |
| ESC allowance for ISO-2022-JP | ✅ | ✅ |
| Empty file behavior                             | Renders blank (zero-byte fast path)                                     | Renders blank (zero-byte read returns empty `Data`)             |
| `.DS_Store` handling                            | Explicit early-return guard in the appex – though unreachable in practice: `.DS_Store` resolves to `dyn.*`, which never reaches the wildcard claim.   | No guard; same outcome via the same `dyn.*` routing. |

## Truncation / size limits

| Aspect                                          | QLStephenSwift                                                         | QLOmni                                                  |
|-------------------------------------------------|------------------------------------------------------------------------|---------------------------------------------------------|
| Default text-preview cap                        | 100 KiB                                                                | 1 MiB (hardcoded)                                       |
| User-configurable cap                           | ✅ via UI / `defaults` (range 100 KiB – 10 MiB)                         | ❌                                                      |
| Two-stage limit (analysis ≠ render) | ✅ (5 MiB analysis cap is independent of render cap) | Binary sniff uses the first 8 KiB; decoding uses the bounded read; UTF-8 output is capped at 1 MiB |

## Install & uninstall

QLOmni's [installation guide](README.md#install), [release workflow](CONTRIBUTING.md#cutting-a-release), and [Homebrew cask](https://github.com/j-256/homebrew-tap/blob/main/Casks/qlomni.rb) describe the official distribution path. QLStephenSwift's installation and activation steps follow its [upstream README](https://github.com/MyCometG3/QLStephenSwift#installation).

| Aspect                                          | QLStephenSwift                                                                                              | QLOmni                                                                                                                  |
|-------------------------------------------------|-------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| One-line install | `brew install --cask MyCometG3/qlstephenswift/qlstephenswift` | `brew install --cask j-256/tap/qlomni` |
| Pre-built download | GitHub Releases | GitHub Releases (universal arm64 + x86_64 app, ZIP and SHA-256 checksum) |
| Code-signing | Signed with Apple Developer ID (hardened runtime enabled in project settings); cask installs cleanly without Gatekeeper bypass | Official releases are Developer ID signed with hardened runtime, notarized by Apple, and stapled for offline Gatekeeper validation. Homebrew installs the same release ZIP. Source builds and diagnostic CI artifacts use ad-hoc signing. |
| Post-install activation | Enable the extension in System Settings, then reset QuickLook caches and restart Finder, as described in the upstream README | Open `QLOmni.app` once after installation. For source builds, `make install` handles registration and resets QuickLook caches. |
| Uninstall | `brew uninstall --cask qlstephenswift` removes the `.app`. Does not explicitly unregister Launch Services entries or reset QuickLook caches. | Homebrew: `brew uninstall --cask qlomni`, then reset QuickLook caches. Manual removal is documented in [README](README.md#uninstall). `make uninstall` also unregisters QLOmni paths from Launch Services and restarts Finder. |

---

*This document is a snapshot. Both projects are under active development; details (deployment targets, supported extensions, feature sets) may have moved on by the time you read it.*
