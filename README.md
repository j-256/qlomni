# QLOmni

A macOS QuickLook Preview Extension that previews the text files macOS itself doesn't.

## What it fixes

Press space on a `.txt` file and macOS shows you the contents. Press space on a few common file types and you get a generic icon and "Document – 4 bytes" instead. The most common cases:

- **Extensionless executables** (e.g. `myscript`, a shell script saved without `.sh`) – tagged `public.unix-executable`, which has no QuickLook handler.
- **Files tagged directly as `public.data`** – extensionless non-executables (a notes file named `shopping-list`) and dot-prefix-only filenames with no further dot (`.gitignore`, `.bashrc`, `.htaccess`, `.vimrc`). Launch Services has nothing to fingerprint, so it tags them with the system's most generic UTI; no other handler claims it.
- **Files with extensions macOS doesn't recognize** – including `.md`, `.jsonc`, `.har`, `.tsx`, `.editorconfig`, `.tf`, `.graphql`, common config formats, and source files for languages whose extensions aren't bundled with macOS (Rust, Go, Kotlin, etc.). See [SUPPORTED.md](SUPPORTED.md) for the full list.
- **Environment-variant configs** – `.env.production`, `docker-compose.yml.example`, `nginx.conf.staging`, `database.yml.test`, etc. The trailing variant suffix becomes the file's extension as far as macOS UTI lookup is concerned, and QLOmni declares a UTI for each common one (`.example`, `.local`, `.development`, `.dev`, `.production`, `.prod`, `.staging`, `.test`). See [DESIGN.md § environment-variant suffixes](DESIGN.md#environment-variant-suffixes) for the rationale.
- **YAML** (`.yaml`, `.yml`), **TOML** (`.toml`), **INI** (`.ini`), and **CSS** (`.css`) – have UTIs that conform to `public.text` but not `public.plain-text`. The system text generator only handles `public.plain-text`, so they fall through.

QLOmni handles all of these – with one notable exception.

**Doesn't fix `.ts`.** TypeScript files have a hard problem: macOS itself (CoreTypes, the bundled type registry) tags every `.ts` file as `public.mpeg-2-transport-stream` (an MPEG-2 video container – `.ts` predates TypeScript as a video extension). QuickLook routes that UTI to the bundled Movie display bundle, which sits ahead of any third-party Preview Extension and cannot be displaced. `.ts` files won't preview as text on any modern macOS, with or without QLOmni. `.tsx` is unaffected and previews fine. See [DESIGN.md § the system display bundle trap](DESIGN.md#the-system-display-bundle-trap).

### Already covered by macOS

If you came here looking for an extension that isn't in the list above, check whether macOS already handles it before assuming you need QLOmni. Some that surprise people:

- **Logs and diffs**: `.log`, `.diff`, `.patch` all conform to `public.plain-text` and route through the system text generator.
- **Scripts with conventional extensions**: `.sh`, `.bash`, `.zsh`, `.py`, `.rb`, `.pl`, `.swift`, `.lua`, `.r` – same.
- **Tabular**: `.csv` and `.tsv` get dedicated handlers (Apple's bundled `Office.qlgenerator` – not to be confused with Microsoft Office – and the system text generator respectively).

To find out whether macOS already covers a given extension on your machine:

```sh
mdls -name kMDItemContentType -name kMDItemContentTypeTree yourfile.foo
```

If `kMDItemContentType` is a real UTI (not `dyn.*`) and `kMDItemContentTypeTree` includes `public.plain-text`, the system *should* preview it. If that's true and pressing space still doesn't show a preview, the issue is at the QuickLook dispatch layer, not the UTI layer – different problem than QLOmni solves. (Some UTIs that conform to `public.plain-text` still route to dedicated generators that may not render cleanly in all contexts; `.xml` is one such case.)

## How

Two pieces, both shipped in a single bundle:

- A **Preview Extension** (`.appex`) that handles `public.unix-executable`, `public.yaml`, `public.toml`, `com.microsoft.ini`, `public.css`, and `public.data` / `public.content` directly – rendering each as plain text. (`public.content` is a supertype of `public.data`; both are listed for belt-and-suspenders coverage of files macOS tags with the bare wildcard.) Binary content is detected in-process via a NUL byte check and falls through to the system "no preview" placeholder rather than rendering garbage.
- A **set of UTI declarations** for common formats macOS doesn't natively know about. Most extensions get assigned a plain-text-conforming UTI and route through the system text generator unchanged; QLOmni's role is just making sure the file *gets* a sensible UTI.

For the technical details – including why some plausible approaches don't work – see [DESIGN.md](DESIGN.md).

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

Pre-built binaries are on the [Releases page](https://github.com/j-256/qlomni/releases) – ad-hoc signed (not notarized), so on first launch Gatekeeper will block the app. Either right-click → Open the first time, or run `xattr -dr com.apple.quarantine /Applications/QLOmni.app`.

## Uninstall

```sh
rm -rf /Applications/QLOmni.app
qlmanage -r && qlmanage -r cache
```

Note that this removes both the Preview Extension *and* the UTI declarations – files that were resolving to a real UTI (e.g. `user.jsonc`) will revert to a synthetic `dyn.*` type after the next Launch Services scan, and lose preview support along with it. `public.data`-tagged files (extensionless non-executables, dotfiles like `.gitignore` – see [DESIGN.md § files tagged directly as `public.data`](DESIGN.md#files-tagged-directly-as-publicdata) for why they end up with that UTI) will also stop previewing, since they were routing through the appex's `public.data` claim rather than getting a UTI from the host plist.

## Verify

After installing, check that the Preview Extension is registered:

```sh
pluginkit -m -p com.apple.quicklook.preview | grep qlomni
```

Should print:

```
+    dev.j-256.qlomni.QLOmniExtension(1.0.0)
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

`make test` is hermetic – it builds and runs without touching `/Applications`, and runs in CI on every push to `main` and every pull request. `make test-integration` requires QLOmni to be installed (it asks PluginKit and Launch Services about the live system) and asks `mdls` what UTI each fixture in `integration/fixtures/` resolves to. It does not run in CI – `mdls` and PluginKit aren't reliable on headless runners. Two assertion modes:

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
- Files with an extension that isn't declared anywhere on your machine resolve to a synthetic `dyn.*` UTI. QuickLook dispatches by concrete UTI, not via the conformance tree, so wildcard claims like `public.data` don't catch them. To preview such files, the extension must be declared specifically (which is what every entry in [SUPPORTED.md](SUPPORTED.md) does). This is distinct from the *no-extension* case – `shopping-list` (no extension at all) does preview, since macOS tags it directly as `public.data`. See [DESIGN.md § how wildcard-UTI claims actually dispatch](DESIGN.md#how-wildcard-uti-claims-actually-dispatch).
- Some extensions QLOmni deliberately doesn't declare because they have no consistent shape. `.tmp` is the obvious case: vim swap files and notes are text, but Word autosaves, Excel scratch files, partial downloads, and Photoshop history snapshots are binary. Declaring `.tmp` as plain-text would briefly try to decode every binary `.tmp` file before falling back to the "no preview" placeholder. If you need previews for a specific text-shaped extension that isn't declared, file an issue with the extension and what kind of files actually use it. Workaround: rename or symlink with a known extension.
- `.ts` caveat above is also a limitation, not a bug.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run tests, cut a release, and use the CI workflow's manual modes (test / dry-run / release).

## License

MIT – see [LICENSE](LICENSE).

## Acknowledgements

Inspired by [QLStephen](https://github.com/whomwah/qlstephen). For differences from [QLStephenSwift](https://github.com/MyCometG3/QLStephenSwift) – another modern descendant of QLStephen – see [COMPARISON.md](COMPARISON.md).
