# Concepts

Background reasoning behind QLOmni's design — captured here so anyone working on QLOmni (or building something similar) doesn't have to re-derive it.

## What QuickLook actually does

A file gets a Uniform Type Identifier (UTI) assigned by Launch Services (`mdls -name kMDItemContentType somefile.foo` shows it). QuickLook then looks for a generator (or, in modern times, a Preview Extension) that claims that UTI or one of its ancestors in the conformance tree.

A UTI can conform to multiple parents, and conformance is transitive. For example, a `.txt` file is tagged `public.plain-text`, which conforms to `public.text`, which conforms to `public.content` and `public.data`, which all conform to `public.item`. Any handler claiming any of these can in principle be selected. QuickLook picks the *most specific* match.

## Why some files don't preview

Three failure modes, in roughly increasing order of subtlety:

### 1. Unknown extension → `dyn.*` UTI

If the file's extension is not declared by *any* installed bundle, Launch Services synthesizes a UTI of the form `dyn.ah62d4rv4ge81k5pu` whose conformance tree is bare: `[public.data, public.item]`. No system handler claims `public.data` or `public.item` generically (see "the wildcard-UTI trap" below), so no preview.

### 2. UTI that doesn't conform to `public.plain-text`

The system text generator (the one that previews `.txt`, `.md`, `.swift`, etc.) only claims `public.plain-text`. Some text-shaped formats have UTIs that conform to `public.text` *but not* `public.plain-text`:

- `public.yaml` — conforms to `public.text` directly.
- `public.toml` — same.

These files have a real UTI, the file is plain text, but the system text generator declines to handle them, and no other handler claims the more general `public.text`.

### 3. UTI declared by an app you don't have installed

Many "system" UTIs are actually declared by specific apps:

- `com.microsoft.typescript` (`.ts`, `.tsx`) — typically `Xcode.app`
- `public.toml` — typically `Xcode.app`
- `public.protobuf-source` — typically `Xcode.app`
- `net.daringfireball.markdown` (`.md`) — varies; sometimes `Xcode.app`, often a markdown editor
- `com.netscape.javascript-source` (`.js`) — typically a browser (Edge, Firefox, etc.)

The exact set depends on what's installed; verify with `lsregister -dump | grep -B1 -A4 'type id: *<uti> '` to find which bundle owns a given UTI.

On a Mac without those apps, the corresponding extensions fall through to case 1 (synthetic `dyn.*`). This is why declaring `.toml` etc. remains valuable even though "the system already knows about it" — *the system might not.*

## How the .appex routes (the wildcard-UTI trap)

We discovered, empirically, that **claiming a wildcard UTI (`public.data`, `public.item`) from a Preview Extension does not result in `dyn.*`-typed files being routed to the extension**, even though the conformance checks `dyn.* conformsTo public.data` and `dyn.* conformsTo public.item` both return true.

What appears to be happening:

- PluginKit dispatch finds our extension as a candidate (we show up in `pluginkit -m -p com.apple.quicklook.preview`).
- But QuickLook applies an additional filter that excludes wildcard-UTI matches, presumably to keep arbitrary third-party Preview Extensions from claiming every file on the user's disk.
- The result is a "Document" placeholder, not a route to our extension.

`public.data` and `public.item` are both flagged `is-wildcard` in `lsregister -dump` output (alongside `public.composite-content` and similar broad UTIs). The wildcard flag is the most likely trigger for the routing filter, though we haven't found Apple documentation that confirms this.

This isn't documented anywhere we could find; it's just observed behavior. QLStephen on legacy macOS may have benefited from looser routing in the `.qlgenerator` era.

**Implication:** there is no broad-net preview fallback. To preview an unknown extension, the extension must be declared somewhere — either exporting a `user.*` UTI or importing a canonical one. There is no "register once, catch everything" option.

## Sandbox limits on Preview Extensions

Modern Preview Extensions run inside a sandboxed XPC service. We verified the following empirically:

- `Data(contentsOf: url)` works for the file URL passed in `request.fileURL` (the QL framework grants access).
- `Process()` shelling out to `/usr/bin/file` (or anything else) is silently blocked. The subprocess never runs.
- Reading the file in chunks via `FileHandle(forReadingFrom:)` works.

Originally we planned to mirror QLStephen's `file --mime` content sniff for binary detection. We can't. In-process byte sniffing is the alternative — but in QLOmni's current scope the question is moot (we only claim text-shaped UTIs, so binary detection isn't needed).

## QLPreviewReply quirks

- `contentSize:` should be `.zero` for HTML/plainText replies. We saw `CGSize(width: 800, height: 600)` get rejected with "Context size invalid in preview generation" even though the docs imply it's a hint. `.zero` works.
- The data-creation block's signature in Swift is `(QLPreviewReply) throws -> Data`. Throwing from this block makes QuickLook fall through to the next handler (which is what we want for unreadable / non-text files).
- Plain text rendering is robust: if the framework can't decode the data as a string, it shows the system "no preview" placeholder rather than rendering garbage.

## UTI identifier choice

Three naming domains:

- **`public.*`** — Apple-reserved. Don't claim these as exported.
- **`com.example.*`** / reverse-DNS — third-party, when you're declaring *your* format.
- **`user.*`** — for declarations of *public formats* that nobody else has officially declared. Discouraged in Apple's docs but in widespread practice for exactly this case.

For QLOmni's bundled declarations:

- Formats with no widely-used canonical UTI → `user.<name>`. The `user.*` prefix is the established idiom for "this UTI is a community-installed declaration of a public format that nobody else has formally claimed" (vs `public.*` which is reserved for Apple, and reverse-DNS which connotes proprietary / vendor-owned formats).
- Formats with a widely-used canonical UTI (e.g. Xcode's `com.microsoft.typescript`, Apple's `public.toml`, John Gruber's `net.daringfireball.markdown`) → import that exact identifier. Don't shadow with our own `user.typescript`.

Imported declarations defer to any exported declaration of the same UTI. So if Xcode is installed later, Xcode's `public.toml` declaration wins automatically and our import becomes a no-op. No collision, no flipping behavior.

## Exported vs Imported declarations

Both keys live under the host app's `Info.plist`:

- `UTExportedTypeDeclarations` — "we are the authoritative declarer of this UTI." If multiple bundles export the same UTI, last registered wins (or some non-deterministic precedence).
- `UTImportedTypeDeclarations` — "this UTI exists, here's our fallback declaration. If anyone else exports it, theirs wins."

QLOmni uses **exported** for `user.*` UTIs (we are the authoritative declarer of `user.jsonc`, etc., until someone else publishes a more authoritative one).

QLOmni uses **imported** for canonical UTIs (`public.toml`, `com.microsoft.typescript`, `public.protobuf-source`, `net.daringfireball.markdown`). We define them as a courtesy for users who don't have Xcode/Edge/etc. installed. If those apps are installed, their declarations take precedence.

## Why .appex claims and host plist declarations are both needed

Each piece does a different job:

- **Host app's UTI declarations** — make sure the file gets tagged with a real, plain-text-conforming UTI instead of `dyn.*`. This enables the *system text generator* to preview it.
- **`.appex`'s `QLSupportedContentTypes`** — fills the gap for UTIs that exist but don't conform to `public.plain-text` (`public.yaml`, `public.toml`) and for UTIs that have no system preview handler at all (`public.unix-executable`).

The asymmetry: most extensions in our list (jsonc, jsx, properties, etc.) get plain-text-conforming UTIs via the host plist alone — no `.appex` involvement. Only `public.yaml`, `public.toml`, and `public.unix-executable` need the `.appex` to handle preview directly.

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

## The `.qlgenerator` graveyard

Before settling on `.appex`, we attempted to use QLStephen (`.qlgenerator` plugin format). Empirical findings on macOS 26 (Apple Silicon, both ad-hoc-signed and unsigned):

- `qlmanage -m plugins` shows only Apple's bundled `.qlgenerator` plugins. User-installed ones don't appear.
- `lsregister -f ~/Library/QuickLook/QLStephen.qlgenerator` returns exit code -10811 ("kLSUnknownErr").
- `pluginkit -m -p com.apple.quicklook.preview` shows only `.appex` Preview Extensions.

Conclusion: `.qlgenerator` is dead on modern macOS. Apple deprecated it in 10.15 in favor of Preview Extensions; loading support has since been removed (or restricted to Apple-bundled plugins). QLOmni shares QLStephen's core idea — surface the contents of files macOS itself doesn't preview — but extends it in two ways:

- Built on the Preview Extension (`.appex`) API that current macOS still loads, replacing the dead `.qlgenerator` bundle format.
- Bundles UTI declarations for common modern file types (`.jsonc`, `.code-workspace`, `.env`, `.editorconfig`, `.tf`, `.graphql`, etc.), so those files get a real plain-text-conforming UTI and route through the system text generator unchanged. QLStephen's approach (claim broadly, sniff with `file --mime`) couldn't address this category at all, since the wildcard-UTI trap blocks broad claims and modern Preview Extensions can't shell out to `/usr/bin/file` from inside the sandbox.

## Multi-extension files (e.g. `.env.integration.stg`)

UTI lookup keys on the substring after the *last* dot. There is no glob / regex / multi-extension support in `UTTypeTagSpecification`. A file named `foo.env.integration.stg` has extension `stg`, not `env`, and would need a `user.stg` declaration to be routed — which is wrong (`.stg` isn't generally an env file).

There's no clean way to handle this on macOS. Workarounds:

- Live without preview for those files.
- Symlink to a single-extension copy.
- Use a tool with its own filename-pattern matching (not QuickLook).

This is a long-standing platform limitation, not specific to QLOmni.
