# Concepts

Background reasoning behind QLOmni's design – captured here so anyone working on QLOmni (or building something similar) doesn't have to re-derive it.

## What QuickLook actually does

A file gets a Uniform Type Identifier (UTI) assigned by Launch Services (`mdls -name kMDItemContentType somefile.foo` shows it). QuickLook then looks for a generator (or, in modern times, a Preview Extension) that claims that UTI or one of its ancestors in the conformance tree.

A UTI can conform to multiple parents, and conformance is transitive. For example, a `.txt` file is tagged `public.plain-text`, which conforms to `public.text`, which conforms to `public.content` and `public.data`, which all conform to `public.item`. Any handler claiming any of these can in principle be selected. QuickLook picks the *most specific* match.

## Why some files don't preview

Three failure modes, in roughly increasing order of subtlety:

### 1. Unknown extension → `dyn.*` UTI

If the file's extension is not declared by *any* installed bundle, Launch Services synthesizes a UTI of the form `dyn.ah62d4rv4ge81k5pu` whose conformance tree is bare: `[public.data, public.item]`. The synthesized UTI is opaque and per-extension – meaning a third-party handler can't claim *that specific synthetic UTI* in advance, since each unrecognized extension produces a different one. The fix is to add a UTI declaration for the extension itself (what QLOmni's host plist does for the extensions listed in [`SUPPORTED.md`](SUPPORTED.md)); LS will then tag matching files with the declared UTI rather than synthesizing. What's *not* available is a single broad-claim shortcut: the only ancestors of `dyn.*` are `public.data` and `public.item`, both wildcard UTIs, and `.appex` claims on wildcards don't dispatch via conformance walks. The concrete-match path also doesn't help here, since the file's concrete UTI is the opaque `dyn.*`, not `public.data`. See [How wildcard-UTI claims actually dispatch](#how-wildcard-uti-claims-actually-dispatch) below.

### 2. UTI that doesn't conform to `public.plain-text`

The system text generator (the one that previews `.txt`, `.md`, `.swift`, etc.) only claims `public.plain-text`. Some text-shaped formats have UTIs that conform to `public.text` *but not* `public.plain-text`:

- `public.yaml` – conforms to `public.text` directly.
- `public.toml` – same.
- `com.microsoft.ini` – same.
- `public.css` – same.

These files have a real UTI, the file is plain text, but the system text generator declines to handle them, and no other handler claims the more general `public.text`.

### 3. UTI declared by an app you don't have installed

Many "system" UTIs are actually declared by specific apps:

- `com.microsoft.typescript` (`.ts`, `.tsx`) – typically `Xcode.app`
- `public.toml` – typically `Xcode.app`
- `public.protobuf-source` – typically `Xcode.app`
- `net.daringfireball.markdown` (`.md`) – varies; sometimes `Xcode.app`, often a markdown editor
- `com.netscape.javascript-source` (`.js`) – typically a browser (Edge, Firefox, etc.)

The exact set depends on what's installed; verify with `lsregister -dump | grep -B1 -A4 'type id: *<uti> '` to find which bundle owns a given UTI.

On a Mac without those apps, the corresponding extensions fall through to case 1 (synthetic `dyn.*`). This is why declaring `.toml` etc. remains valuable even though "the system already knows about it" – *the system might not.*

A subtler case: an app may *handle* a file type without *declaring* its UTI. The `Info.plist` key `CFBundleDocumentTypes` binds extensions to apps for "Open With" routing; `UTExportedTypeDeclarations` / `UTImportedTypeDeclarations` declare what the UTI itself is (and what it conforms to). Only the latter teaches Launch Services anything about the type graph. An app can list `.md` under `CFBundleDocumentTypes` – making it the default editor for the extension – without ever asserting the file is `net.daringfireball.markdown` or that it conforms to `public.plain-text`. From a UTI-resolution standpoint, that app contributes nothing, and the file still lands at `dyn.*`. As of writing (VS Code 1.120), this is the case for VS Code: it claims `.md` only via `CFBundleDocumentTypes`, with no UTI declarations of any kind. So "I have a Markdown-aware editor installed" is not a reliable proxy for "Markdown has a real UTI on this machine."

## The `.qlgenerator` graveyard

Before settling on `.appex`, we attempted to use QLStephen (`.qlgenerator` plugin format). Empirical findings on macOS 26 (Tahoe – Apple's 2025 renumber to align with iOS, succeeding macOS 15 Sequoia) on Apple Silicon, both ad-hoc-signed and unsigned:

- `qlmanage -m plugins` shows only Apple's bundled `.qlgenerator` plugins. User-installed ones don't appear.
- `lsregister -f ~/Library/QuickLook/QLStephen.qlgenerator` returns exit code -10811 ("kLSUnknownErr").
- `pluginkit -m -p com.apple.quicklook.preview` shows only `.appex` Preview Extensions.

Conclusion: `.qlgenerator` is dead on modern macOS. Apple deprecated it in 10.15 in favor of Preview Extensions; loading support has since been removed (or restricted to Apple-bundled plugins). QLOmni shares QLStephen's core idea – surface the contents of files macOS itself doesn't preview – but extends it in two ways:

- Built on the Preview Extension (`.appex`) API that current macOS still loads, replacing the dead `.qlgenerator` bundle format.
- Bundles UTI declarations for common modern file types (`.jsonc`, `.code-workspace`, `.editorconfig`, `.tf`, `.graphql`, etc.), so those files get a real plain-text-conforming UTI and route through the system text generator unchanged. The named-extension category – "macOS doesn't know what `.jsonc` is" – is unreachable from a content-sniffing approach alone, since there's no path from "this file's bytes look like text" back to "rewrite the UTI assignment." Host-plist declarations are the layer that solves it.

Worth flagging on content sniffing specifically, since QLStephen leaned on it heavily: the *shell-out* implementation (`Process()` on `/usr/bin/file`) is unreachable from a sandboxed Preview Extension (see [Sandbox limits on Preview Extensions](#sandbox-limits-on-preview-extensions) below for the empirical verification), but in-process byte inspection works fine and is what both QLOmni and QLStephenSwift use. Content sniffing as an idea isn't dead, only the shell-out implementation is.

## How wildcard-UTI claims actually dispatch

`public.data`, `public.item`, `public.content`, and a handful of other broad UTIs are flagged `is-wildcard` in `lsregister -dump` output. Whether and how `.appex` claims on these UTIs dispatch is undocumented; the empirical rule we observe:

**A wildcard-UTI claim dispatches only when the file's *concrete* UTI is exactly the claimed wildcard. It does not dispatch via conformance from a more specific concrete UTI.**

Three cases that illustrate the rule:

- A file tagged `public.data` directly (extensionless non-executable, dotfile-with-no-further-dot) → claimed `public.data` → **dispatches**. The concrete UTI matches the claim.
- A file tagged `dyn.ah62...` (unknown extension) → conforms to `public.data` → **does not dispatch**. The concrete UTI is the synthetic `dyn.*`, not `public.data`.
- A file tagged `public.css` → conforms to `public.data` (and `public.text`, and `public.content`) → **does not dispatch through a wildcard claim**. The concrete UTI is `public.css`; QL routes by that, not via conformance walk to a wildcard ancestor. (`.css` files do still preview, since the appex claims `public.css` directly as a non-wildcard entry – this is what the wildcard-claim path *isn't* doing.)

This is why broad claims work for the narrow case (files genuinely tagged with the wildcard UTI itself) but don't form a catch-all fallback. To preview a file whose concrete UTI is `dyn.*` or any non-wildcard, that specific UTI must be declared or claimed somewhere – there's no "register once, catch all unknowns" option.

The most likely mechanism is that QL dispatches by concrete-UTI lookup against `QLSupportedContentTypes` entries, with no conformance walk on the file's UTI tree when the candidate claim is `is-wildcard`. We haven't confirmed this against Apple source, but it's consistent with every observation.

## The system display bundle trap

Sibling to the wildcard-UTI dispatch rule (see [How wildcard-UTI claims actually dispatch](#how-wildcard-uti-claims-actually-dispatch)), and just as undocumented: **third-party Preview Extensions cannot override UTIs that have a system display bundle.**

Discovered while trying to handle `public.mpeg-2-transport-stream` (which CoreTypes assigns to all `.ts` files, including TypeScript source). Adding it to our `QLSupportedContentTypes` had no effect – our `.appex` was never consulted. The QL log showed:

```
got displayBundleID com.apple.qldisplay.Movie for <private>
...
Falling back on Generic preview for: <private>
```

QuickLook resolves the UTI through an internal **display-bundle table** (UTI → `com.apple.qldisplay.*`) that is consulted *before* PluginKit. If a system display bundle claims the UTI, QL routes there directly; if that handler bails, QL falls back to the generic placeholder, never asking PluginKit-registered `.appex` extensions.

Display bundles live in SIP-protected system frameworks and can't be displaced by third parties.

UTIs known to have system display bundles include `public.movie` and everything conforming to it (so `public.mpeg-2-transport-stream`, `public.mpeg`, `public.mpeg-4`, `public.avi`, `public.quicktime-movie`, etc.), `public.image`, `public.audio`, `public.pdf`, `public.html`, `com.apple.iwork.*`, and presumably others. We have not enumerated the full list.

**Implication for QLOmni:** any extension that gets tagged with a UTI claimed by a system display bundle is unrecoverable from a third-party `.appex`. `.ts` is the case we hit (CoreTypes maps `.ts → public.mpeg-2-transport-stream`, which routes to the Movie display bundle). Files with these extensions on macOS as of writing won't preview as text no matter what we declare.

## Files tagged directly as `public.data`

Two filename shapes get tagged `public.data` directly by Launch Services, with `kMDItemContentTypeTree = [public.data, public.item]` – no synthetic `dyn.*`:

- **No extension, no `+x` bit** – e.g. a notes file named `shopping-list`. Without an extension, executable bit, or MIME-type hint, LS has nothing to fingerprint, so it falls back to the most generic UTI in the system.
- **Dot-prefix only, no further dot** – e.g. `.gitignore`, `.bashrc`, `.zshrc`, `.htaccess`, `.vimrc`. UTI lookup keys on the substring after the *last* dot, but a leading dot marks the file as hidden (per Unix convention) rather than starting an extension. With no other dot in the name, LS treats these as having no extension at all.

Compare to `something.gitignore` (regular filename with `gitignore` as the extension): that resolves to a synthetic `dyn.*`, since `gitignore` isn't declared as an extension by any installed bundle. The two filename shapes look similar but route differently.

Both `public.data`-tagged shapes route to the appex via the `public.data` claim in `QLSupportedContentTypes`, per the rule in [How wildcard-UTI claims actually dispatch](#how-wildcard-uti-claims-actually-dispatch). The concrete UTI on the file is `public.data`, the appex claims `public.data`, the concrete-match path applies.

This is the case QLStephen handled with `file --mime` content sniffing inside its `.qlgenerator`. We don't need to sniff to *route* this case – the file is already tagged with a UTI we can claim. We do still sniff to *render* it: `public.data` catches arbitrary binary blobs as well as text, so `PreviewRenderer` runs an in-process NUL byte check and bails on binary content rather than dumping bytes into the preview.

The remaining limitation is the `dyn.*` case from [§ Why some files don't preview](#why-some-files-dont-preview), case 1: an unrecognized *extension* (not an absent one) still produces an opaque per-extension synthetic UTI. The mechanism is fully addressable per-extension by adding a UTI declaration to the host plist (most of QLOmni's declarations exist for this reason); what's not addressable is a single broad-claim catch-all. Some extensions QLOmni deliberately doesn't declare because their content shape isn't reliably text – `.tmp` is the canonical example, since vim swap files and notes are text but Word autosaves, partial downloads, and similar are binary. Declaring those as plain-text would briefly try to decode binary content before falling back to the no-preview placeholder. Workaround for files we don't declare: rename or symlink with a known extension.

## Environment-variant suffixes

A class of file shapes that look like multi-extension cases but are well-handled by single-extension UTI declarations: configs that get duplicated per environment with a trailing variant suffix. The dotenv ecosystem is the canonical case (`.env.production`, `.env.development`, `.env.local`, `.env.example`), but the pattern shows up wherever you keep parallel configs by environment – `docker-compose.yml.example`, `nginx.conf.staging`, `database.yml.production`, `Gemfile.test`.

UTI lookup keys on the substring after the *last* dot, so `.env.production` is looked up as extension `production`. A `user.production` declaration claims it. There's no need for any multi-extension matching machinery to reach this case; one ordinary `UTTypeTagSpecification` per suffix is enough.

QLOmni declares eight of these as `user.*` UTIs conforming to `public.plain-text`: `.example`, `.local`, `.development`, `.dev`, `.production`, `.prod`, `.staging`, `.test`. Each is a `UTExportedTypeDeclaration` named `user.<extension>` (`user.example`, `user.local`, etc.). The descriptions are uniform – "Environment-variant config (`.<ext>` suffix)" – because the UTI doesn't claim to know what file shape the *variant* contains, only that the variant marker is text-shaped in practice.

### Why these eight

The pattern is "this extension, on a file, is essentially always an environment-variant marker on a text config." Verified by checking conventions in the dotenv ecosystem (Next.js, Vite, Rails, dotenv-cli) and in tooling that uses suffix-based environment overrides (Docker Compose, `*.example` template conventions across many projects).

- `.example` – template / sample copy of a config. Universal "commit this, gitignore the real one" convention.
- `.local` – machine-local override. Next.js and Vite both treat `.env.local` as the highest-priority dotenv file.
- `.development`, `.dev` – dev-environment variant. `.development` is the canonical Next.js / Vite name; `.dev` is the common shortening that humans actually type.
- `.production`, `.prod` – prod-environment variant. Same canonical/shortening pair.
- `.staging` – staging-environment variant. Less frameworks-blessed but in widespread practice.
- `.test` – test-environment variant. Used by Next.js, Jest setups, and the broader Ruby/Rails ecosystem.

These all conform to `public.plain-text` (not `public.source-code`) deliberately. The variant marker doesn't say anything about what the file *contains* – `.env.production` is a dotenv file, but `nginx.conf.production` is nginx config, and `Gemfile.test` is Ruby. Promising "plain text" is the strongest claim that's true of all of them.

### What we deliberately don't declare

Certain candidate suffixes were considered and rejected:

- **Backup / temp suffixes (`.bak`, `.orig`, `.old`, `.tmp`, `.swp`, `.save`)** – the original file could be binary. `image.png.bak` is a binary backup, `recipe.docx.orig` is a Word doc. Declaring these as plain-text would silently try to decode binary content before falling back to the no-preview placeholder, with worse UX than just leaving the generic icon.
- **Disabled / suspended suffixes (`.disabled`, `.off`, `.suspended`)** – real pattern (e.g. `nginx.conf.disabled` to deactivate a vhost), but uncommon enough that the noise floor outweighs the catch rate. Add later if requested.
- **Shorter staging shortenings (`.stage`, `.stg`)** – `.staging` is the canonical form; `.stage` and `.stg` exist but are rare in practice. Skipping until specifically requested.
- **Other environment shortenings (`.qa`, `.uat`, `.demo`)** – same reasoning. Real but org-specific; not common enough to be worth the LS registration cost.
- **Generic config-version suffixes (`.v1`, `.v2`, `.draft`)** – not environment markers, and `.draft` in particular has too many non-config uses (text drafts, design files).

The general gate: **the suffix has to mean "text config variant, original is text" with very high probability across users**. If 1 in 50 occurrences is a binary file, it's not worth declaring; the user sees worse UX than they would have without the declaration.

### Interaction with multi-extension files

The "extension is the substring after the last dot" rule means these declarations work cleanly for 2-segment names (`.env.production`, `docker-compose.yml.example`) but not for 3+ segments. A file named `.env.production.local` is looked up as extension `local` – `user.local` claims it, so it does preview, but only by collapsing the variant chain to the last marker. See [Multi-extension files](#multi-extension-files-eg-envintegrationstg) below for the deeper case where no last-segment declaration is appropriate.

## Multi-extension files (e.g. `.env.integration.stg`)

UTI lookup keys on the substring after the *last* dot. There is no glob / regex / multi-extension support in `UTTypeTagSpecification`. A file named `foo.env.integration.stg` has extension `stg`, not `env`, and would need a `user.stg` declaration to be routed – which is wrong (`.stg` isn't generally an env file).

The 2-segment subcase – `.env.production`, `docker-compose.yml.example`, etc. – *is* handled, since the last segment is meaningful and well-known. See [Environment-variant suffixes](#environment-variant-suffixes) above. The unsolvable shape is 3+ segments where the trailing chunk is opaque in the absence of the leading chunks.

There's no clean way to handle this on macOS. Workarounds:

- Live without preview for those files.
- Symlink to a single-extension copy.
- Use a tool with its own filename-pattern matching (not QuickLook).

This is a long-standing platform limitation, not specific to QLOmni.

## Sandbox limits on Preview Extensions

Modern Preview Extensions run inside a sandboxed XPC service. We verified the following empirically:

- `Data(contentsOf: url)` works for the file URL passed in `request.fileURL` (the QL framework grants access).
- `Process()` shelling out to `/usr/bin/file` (or anything else) is silently blocked. The subprocess never runs.
- Reading the file in chunks via `FileHandle(forReadingFrom:)` works.

Originally we planned to mirror QLStephen's `file --mime` content sniff for binary detection. We can't shell out, but in-process byte sniffing works (we read the prefix via `FileHandle` and look for a NUL – the same heuristic `git diff` uses). `PreviewRenderer` does this and throws on binary content, which makes QuickLook fall through to the no-preview placeholder rather than rendering garbage. The text-shaped UTIs we claim normally won't be binary, but `public.unix-executable` covers Mach-O binaries too, and pressing space on one of those should fail gracefully rather than dumping bytes.

## UTI identifier choice

Three naming domains:

- **`public.*`** – Apple-reserved. Don't claim these as exported.
- **`com.example.*`** / reverse-DNS – third-party, when you're declaring *your* format.
- **`user.*`** – for declarations of *public formats* that nobody else has officially declared. Discouraged in Apple's docs but in widespread practice for exactly this case.

For QLOmni's bundled declarations:

- Formats with no widely-used canonical UTI → `user.<name>`. The `user.*` prefix is the established idiom for "this UTI is a community-installed declaration of a public format that nobody else has formally claimed" (vs `public.*` which is reserved for Apple, and reverse-DNS which connotes proprietary / vendor-owned formats).
- Formats with a widely-used canonical UTI (e.g. Xcode's `com.microsoft.typescript`, Apple's `public.toml`, John Gruber's `net.daringfireball.markdown`) → import that exact identifier. Don't shadow with our own `user.typescript`.

Imported declarations defer to any exported declaration of the same UTI. So if Xcode is installed later, Xcode's `public.toml` declaration wins automatically and our import becomes a no-op. No collision, no flipping behavior.

## Exported vs Imported declarations

Both keys live under the host app's `Info.plist`:

- `UTExportedTypeDeclarations` – "we are the authoritative declarer of this UTI." If multiple bundles export the same UTI, last registered wins (or some non-deterministic precedence).
- `UTImportedTypeDeclarations` – "this UTI exists, here's our fallback declaration. If anyone else exports it, theirs wins."

QLOmni uses **exported** for `user.*` UTIs (we are the authoritative declarer of `user.jsonc`, etc., until someone else publishes a more authoritative one).

QLOmni uses **imported** for canonical UTIs (`public.toml`, `com.microsoft.typescript`, `public.protobuf-source`, `net.daringfireball.markdown`). We define them as a courtesy for users who don't have Xcode/Edge/etc. installed. If those apps are installed, their declarations take precedence.

## Extension collisions across declarers

Distinct from the import/export decision above, there's a third axis: two declarers can claim the *same extension* with *different UTIs*. This isn't a backup relationship – neither is the canonical declarer of the other's UTI. They each just happen to use the extension.

Examples QLOmni encounters:

- `.gs` – QLOmni: `user.gs` (Google Apps Script). Xcode: `org.khronos.glsl.geometry-shader` (OpenGL geometry shader).
- `.ts` – QLOmni imports `com.microsoft.typescript` (TypeScript). `CoreTypes` (bundled in macOS) exports `public.mpeg-2-transport-stream` (MPEG-2 video container).

Launch Services breaks ties using flags on each registration. Roughly: `apple-internal trusted` > `exported trusted` > `imported trusted` > `untrusted`. Apple's own bundles (`CoreTypes`, `Xcode`) are flagged `apple-internal`, so any claim they make wins regardless of whether it's exported or imported. A third-party `exported trusted` declaration (ours) cannot win against `apple-internal`.

Practical implications for QLOmni:

- **Macs without Xcode** (our primary audience): no competing claim. `.gs` resolves to `user.gs`, `.tsx` resolves to our `com.microsoft.typescript` import (and previews because `public.script` ultimately conforms to `public.plain-text` via `public.text-script`).
- **Macs with Xcode**: `.gs` resolves to `org.khronos.glsl.geometry-shader`. The conformance chain `glsl.geometry-shader → glsl-source → public.source-code → public.plain-text` does reach plain text (Xcode declares the GLSL UTIs `apple-internal trusted`, and `public.source-code` is a CoreTypes-declared text type), so `.gs` previews as text via the system text generator either way – just with the wrong "kind" label ("OpenGL Geometry Source" instead of "Google Apps Script"). `.tsx` resolves to Xcode's `com.microsoft.typescript` (same conformance as ours), still previews.
- **`.ts` on any modern macOS**: `CoreTypes` always wins with `public.mpeg-2-transport-stream`. Even worse, that UTI has a system display bundle (see [the system display bundle trap](#the-system-display-bundle-trap)), so we can't even handle it via `.appex`. Our `com.microsoft.typescript` import is moot in practice; kept only because removing it costs nothing and Apple could conceivably remove the MPEG-2 claim in a future macOS release.

To investigate a contested extension on a given machine:

```sh
lsregister -dump | awk '/^----/{block=""; next} {block=block"\n"$0} /^tags:.*\.gs[,$]/{print block; print "==="}'
```

The integration harness (`integration/run.sh`) categorizes contested extensions as `assert_lenient`: it accepts any non-`dyn.*` UTI and reports the winner instead of failing when we lose.

## Why .appex claims and host plist declarations are both needed

Each piece does a different job:

- **Host app's UTI declarations** – make sure the file gets tagged with a real, plain-text-conforming UTI instead of `dyn.*`. This enables the *system text generator* to preview it.
- **`.appex`'s `QLSupportedContentTypes`** – fills the gap for UTIs that exist but don't conform to `public.plain-text` (`public.yaml`, `public.toml`, `com.microsoft.ini`, `public.css`), for UTIs that have no system preview handler at all (`public.unix-executable`), and for the wildcard `public.data` / `public.content` claims that route files tagged directly with those UTIs (see [Files tagged directly as `public.data`](#files-tagged-directly-as-publicdata)).

The asymmetry: most extensions in our list (jsonc, jsx, properties, etc.) get plain-text-conforming UTIs via the host plist alone – no `.appex` involvement. Only the UTIs listed above need the `.appex` to handle preview directly.

## QLPreviewReply quirks

- `contentSize:` should be `.zero` for HTML/plainText replies. We saw `CGSize(width: 800, height: 600)` get rejected with "Context size invalid in preview generation" even though the docs imply it's a hint. `.zero` works.
- The data-creation block's signature in Swift is `(QLPreviewReply) throws -> Data`. Throwing from this block makes QuickLook fall through to the next handler (which is what we want for unreadable / non-text files).
- Plain text rendering is robust: if the framework can't decode the data as a string, it shows the system "no preview" placeholder rather than rendering garbage.

## Stale PluginKit and Launch Services entries

Renaming a bundle identifier, deleting a `.app` from `/Applications/`, or building+installing+rebuilding repeatedly can leave stale entries in the PluginKit/LaunchServices registry. These outlast the binaries on disk and can cause QuickLook to route to (or believe in) phantom Preview Extensions that no longer exist.

Symptoms:

- `pluginkit -m -p com.apple.quicklook.preview` lists identifiers that don't correspond to any bundle on disk.
- `lsregister -dump` shows the old identifier bound to a path under `~/Library/Developer/Xcode/DerivedData/...` or `~/.Trash/...`.
- QuickLook routes to an old version of the extension instead of the freshly-installed one.

Cleanup:

```sh
# Find paths still bound to a stale identifier:
lsregister -dump | grep -B5 'old.bundle.identifier' | grep 'path:'

# Unregister each path individually (pluginkit -r -i sometimes doesn't work):
lsregister -u '/path/from/above'

# Reset QuickLook so quicklookd re-discovers extensions:
qlmanage -r && qlmanage -r cache
```

`lsregister` lives at `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`. It's not on `$PATH` by default.

The Xcode build pipeline auto-registers the Debug build product via `lsregister -f -R -trusted` on every build. If you renamed the bundle, that DerivedData path may still hold the old registration; clean DerivedData (or unregister the path explicitly) to avoid confusion.

## File-system-synchronized groups vs the new-app template

Xcode 16 added *file-system-synchronized groups* (`PBXFileSystemSynchronizedRootGroup`), which auto-discover folder contents instead of requiring every file to be listed explicitly in `project.pbxproj`. Lower maintenance, less merge conflict surface – good feature.

The new-app project template (which has been Xcode's default for years) generates a nested layout: target `QLOmni/` contains an inner folder `QLOmni/`, with `Info.plist`, `*.swift`, and `Assets.xcassets` inside that. Two different parts of Xcode disagree about what to do with this:

- The **build settings** point at `QLOmni/QLOmni/Info.plist` via `INFOPLIST_FILE`, embedding it into the bundle as `Info.plist`.
- The **synchronized group** rooted at `QLOmni/` recurses into the nested folder and auto-includes `Info.plist` in the Copy Bundle Resources phase.

Both paths active simultaneously triggers the warning:

```
warning: The Copy Bundle Resources build phase contains this target's
Info.plist file '.../QLOmni/QLOmni/Info.plist'.
```

Apple was aware of the conflict – they added the `membershipExceptions` mechanism specifically for it, and they applied it for QLOmni's **extension** target when generating the project. But the same fix wasn't applied for the **app** target, despite both using the nested-folder template. The result is a project that warns on every build out of the box.

The fix is small (add a `PBXFileSystemSynchronizedBuildFileExceptionSet` for the app target excluding `QLOmni/Info.plist`, mirroring the one already in place for the extension), and matches what Xcode *would have* generated if the template author had been consistent.

Flattening the nested folder (`QLOmni/QLOmni/*` → `QLOmni/*`) would also work and removes the redundancy entirely, but means rewriting `INFOPLIST_FILE` paths and Assets catalog references across pbxproj. Not worth it for a single warning.
