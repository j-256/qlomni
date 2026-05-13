# QLOmni

A macOS QuickLook Preview Extension that previews the text files macOS itself doesn't.

## What it fixes

Press space on a `.txt` file and macOS shows you the contents. Press space on a few common file types and you get a generic icon and "Document — 4 bytes" instead. The most common cases:

- **Extensionless executables** (e.g. `myscript`, a shell script saved without `.sh`) — tagged `public.unix-executable`, which has no QuickLook handler.
- **YAML** (`.yaml`, `.yml`) — tagged `public.yaml`, which conforms to `public.text` but not `public.plain-text`. The system text generator only handles `public.plain-text`, so YAML falls through.
- **Files with extensions macOS doesn't recognize** — `.jsonc`, `.code-workspace`, `.env`, `.editorconfig`, `.tf`, `.graphql`, and others. (On Macs without Xcode.app, which contributes its own UTI declarations as a side effect, also `.toml`, `.ts`/`.tsx`, `.proto`, `.sql`, and `.md`.)

QLOmni handles all of these.

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

## Limitations

- Plain text rendering only — no syntax highlighting, no pretty-printing.
- Files larger than 1 MiB are truncated.
- Multi-extension files (e.g. `.env.production.local`) aren't routable on macOS at all; this is a platform limitation, not a QLOmni one.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Inspired by [QLStephen](https://github.com/whomwah/qlstephen).
