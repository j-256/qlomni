# QLOmni

A macOS QuickLook Preview Extension that previews the text files macOS itself doesn't.

## What it fixes

Press space on a `.txt` file and macOS shows you the contents. Press space on a few common file types and you get a generic icon and "Document – 4 bytes" instead. The most common cases:

- **Extensionless executables** (e.g. `myscript`, a shell script saved without `.sh`) – tagged `public.unix-executable`, which has no QuickLook handler.
- **YAML** (`.yaml`, `.yml`), **TOML** (`.toml`), and **INI** (`.ini`) – have UTIs that conform to `public.text` but not `public.plain-text`. The system text generator only handles `public.plain-text`, so they fall through.
- **Files with extensions macOS doesn't recognize** – `.jsonc`, `.code-workspace`, `.env`, `.editorconfig`, `.tf`, `.tfvars`, `.graphql`, `.gql`, `.jsx`, `.properties`, `.tsx`, `.proto`, `.sql`, `.md`, `.markdown`, `.err`, `.out`, Google Apps Script (`.gs`), and a long list of programming languages and config formats: `.rs` (Rust), `.go`, `.kt`/`.kts` (Kotlin), `.cs` (C#), `.scala`, `.dart`, `.vue`, `.svelte`, `.sass`/`.scss`, `.less`, `.hcl`, `.clj`/`.cljs`/`.cljc` (Clojure), `.hs` (Haskell), `.ps1`/`.psm1` (PowerShell), `.ex` (Elixir), `.coffee`, `.groovy`, `.fish`, `.feature` (Gherkin), `.hbs`/`.handlebars`, and `.cjs`. Some of these (e.g. `.tsx`, `.proto`, `.md`) get UTI declarations from Xcode.app if installed; QLOmni provides the same declarations as a fallback for Macs without it, so preview works either way.

QLOmni handles all of these – with two notable exceptions.

**Doesn't fix `.ts`.** TypeScript files have a hard problem: macOS itself (CoreTypes, the bundled type registry) tags every `.ts` file as `public.mpeg-2-transport-stream` (an MPEG-2 video container – `.ts` predates TypeScript as a video extension). QuickLook routes that UTI to the bundled Movie display bundle, which sits ahead of any third-party Preview Extension and cannot be displaced. `.ts` files won't preview as text on any modern macOS, with or without QLOmni. `.tsx` is unaffected and previews fine. See [DESIGN.md § the system display bundle trap](DESIGN.md#the-system-display-bundle-trap).

**Doesn't fix `.gs` if Xcode is installed.** Xcode declares `.gs` as an OpenGL geometry shader, which doesn't preview as text. On Macs without Xcode, `.gs` previews as Google Apps Script. See [DESIGN.md § extension collisions across declarers](DESIGN.md#extension-collisions-across-declarers).

### Already covered by macOS

If you came here looking for an extension that isn't in the list above, check whether macOS already handles it before assuming you need QLOmni. Some that surprise people:

- **Logs and diffs**: `.log`, `.diff`, `.patch` all conform to `public.plain-text` and route through the system text generator.
- **Scripts with conventional extensions**: `.sh`, `.bash`, `.zsh`, `.py`, `.rb`, `.pl`, `.swift`, `.lua`, `.r` – same.
- **Tabular**: `.csv` and `.tsv` get dedicated handlers (`Office.qlgenerator` and the system text generator respectively).
- **Markdown** (`.md`): only on Macs with a markdown UTI declarer. Xcode counts; QLOmni includes one as a fallback.

To find out whether macOS already covers a given extension on your machine:

```sh
mdls -name kMDItemContentType -name kMDItemContentTypeTree yourfile.foo
```

If `kMDItemContentType` is a real UTI (not `dyn.*`) and `kMDItemContentTypeTree` includes `public.plain-text`, the system *should* preview it. If that's true and pressing space still doesn't show a preview, the issue is at the QuickLook dispatch layer, not the UTI layer – different problem than QLOmni solves. (Some UTIs that conform to `public.plain-text` still route to dedicated generators that may not render cleanly in all contexts; `.xml` is one such case.)

## How

Two pieces, both shipped in a single bundle:

- A **Preview Extension** (`.appex`) that handles `public.unix-executable`, `public.yaml`, and `public.toml` directly — rendering each as plain text.
- A **set of UTI declarations** for common formats macOS doesn't natively know about. Most extensions get assigned a plain-text-conforming UTI and route through the system text generator unchanged; QLOmni's role is just making sure the file *gets* a sensible UTI.

For the technical details — including why some plausible approaches don't work — see [DESIGN.md](DESIGN.md).

## Install

Requires:

- macOS 12 (Monterey) or later
- [Xcode.app](https://developer.apple.com/download/all/?q=Xcode%2e) (the full IDE, not just the Command Line Tools)

```sh
git clone https://github.com/j-256/qlomni.git
cd qlomni
make install
```

This builds a universal binary (arm64 + x86_64), ad-hoc signs it, copies `QLOmni.app` to `/Applications/`, registers the Preview Extension with PluginKit, and resets QuickLook so the changes take effect immediately.

Pre-built binaries are not currently provided.

## Uninstall

```sh
rm -rf /Applications/QLOmni.app
qlmanage -r && qlmanage -r cache
```

Note that this removes both the Preview Extension *and* the UTI declarations — files that were resolving to a real UTI (e.g. `user.jsonc`) will revert to a synthetic `dyn.*` type after the next Launch Services scan, and lose preview support along with it.

## Verify

After installing, check that the Preview Extension is registered:

```sh
pluginkit -m -p com.apple.quicklook.preview | grep qlomni
```

Should print:

```
+    dev.j-256.qlomni.QLOmniExtension(1.0)
```

The leading `+` means it's enabled. Then test against any of the formats listed above.

If you've built and installed QLOmni multiple times, Launch Services may accumulate stale registrations pointing at old build paths (DerivedData, prior `/Applications/QLOmni.app` versions, etc.). Symptoms: `pluginkit -m -p com.apple.quicklook.preview | grep qlomni` prints multiple entries, or QuickLook routes to a phantom build. To clean them up:

```sh
make purge-ls
```

This unregisters every QLOmni-related path Launch Services knows about *except* `/Applications/QLOmni.app`, then re-registers the live install.

## Tests

```sh
make test              # Swift unit tests (PreviewRenderer truncation/IO)
make install           # required before integration tests
make test-integration  # asserts mdls returns the expected UTI for each declared extension
```

`make test` is hermetic – it builds and runs without touching `/Applications`. `make test-integration` requires QLOmni to be installed (it asks PluginKit and Launch Services about the live system) and asks `mdls` what UTI each fixture in `integration/fixtures/` resolves to. Two assertion modes:

- **Strict** – extensions where no other declarer is expected to compete. The fixture must resolve exactly to the UTI QLOmni declared.
- **Lenient** – extensions where another bundle may legitimately also claim them (e.g. `.ts` vs CoreTypes' MPEG-2, `.gs` vs Xcode's GLSL shader). Any non-`dyn.*` UTI passes; the harness reports who won.

It does not assert rendering correctness – that requires `qlmanage -p <fixture>` and a human eye. In particular, "Lenient passed" doesn't mean the file *previews* on this machine, only that some real UTI got assigned.

## Investigating UTI dispatch

Two helpers under `tools/` for poking at how the system resolves a given extension or file:

```sh
./tools/uti.swift rs ini gs              # live LaunchServices lookup per extension
./tools/mdls-summary.sh some-file.foo    # one-line mdls summary for a path
```

`uti.swift` queries the live LaunchServices API and is the right tool right after a registration change (`lsregister -u/-f`). `mdls` reads from a Spotlight metadata cache that can stay stale for minutes after registrations change, so prefer `uti.swift` when investigating contested extensions.

## Limitations

- Plain text rendering only – no syntax highlighting, no pretty-printing.
- Files larger than 1 MiB are truncated.
- Multi-extension files (e.g. `.env.production.local`) aren't routable on macOS at all; this is a platform limitation, not a QLOmni one.
- Extensionless non-executable files (e.g. a notes file named `shopping-list` with no extension and no `+x` bit) can't be previewed. macOS tags them as `public.data`, which is a wildcard UTI that QuickLook refuses to route to third-party Preview Extensions. Workaround: `chmod +x` the file (it'll route through our `public.unix-executable` handler), or symlink it with a real extension. See [DESIGN.md § extensionless non-executable files](DESIGN.md#extensionless-non-executable-files).
- `.ts` and `.gs`-on-Xcode caveats above are also limitations, not bugs.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Inspired by [QLStephen](https://github.com/whomwah/qlstephen).
