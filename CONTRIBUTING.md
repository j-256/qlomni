# Contributing

## Running tests

Two test suites with different scopes and side effects:

| Suite | Command | Verifies | Side effects | Runs in CI |
| --- | --- | --- | --- | --- |
| Unit | `make test` | `PreviewRenderer` truncation/IO logic in isolation | None (hermetic) | Yes – every push to `main` and every PR |
| Integration | `make install && make test-integration` | Each declared file extension resolves to its expected UTI on this machine via `mdls`, and `pluginkit` shows the extension is registered | `make install` writes `/Applications/QLOmni.app`, registers PluginKit, clears the QuickLook cache | No – `mdls` and PluginKit aren't reliable on headless runners |

Integration tests **do not** verify rendering correctness – that requires `qlmanage -p <fixture>` and a human eye (or a spacebar preview).

### When integration tests need to run

Integration tests exercise UTI routing, which is determined by:

- `QLOmni/QLOmni/Info.plist` – the host app's exported and imported UTI declarations.
- `QLOmniExtension/Info.plist` – the `.appex`'s `QLSupportedContentTypes`.
- `integration/run.sh` and `integration/fixtures/` – the harness itself and the files it asserts against.

If a release doesn't touch any of those, integration tests will pass the same as the previous release and re-running them is busywork. `make release` checks for changes to those paths since the last `v*` tag and runs integration tests automatically only when there's a reason to. Override with `INTEGRATION=1` (force run) or `INTEGRATION=0` (force skip); see [Cutting a release](#cutting-a-release) below.

## Cutting a release

Releases are GitHub Actions jobs that build a universal `QLOmni.app`, ad-hoc sign it, package it as a zip with `ditto`, and attach it to a GitHub Release.

```sh
make release V=1.2.3
```

This runs preflight checks (clean tree, on `main`, tag doesn't already exist locally or on origin, unit tests pass), conditionally runs integration tests (see below), bumps `MARKETING_VERSION`, commits `release: v1.2.3`, tags `v1.2.3`, and pushes `main` and the tag to `origin`. The tag push triggers CI's full pipeline (`test` → `package` → `release`) and a GitHub Release is created automatically with auto-generated notes plus the SHA-256 and Gatekeeper instructions.

If any step fails, `make release` either rolls back automatically (early steps – pbxproj revert) or prints a resume command (late steps – e.g. push). Notably: a network failure during push leaves the commit and tag in place locally, so you finish with a single `git push origin main vX.Y.Z` rather than re-running tests.

### Integration tests during release

`make release` decides whether to run integration tests based on whether any commit since the previous `v*` tag touched the UTI surface (see [When integration tests need to run](#when-integration-tests-need-to-run)). The decision and reason are printed at the start of the run.

| `INTEGRATION` | Behavior |
| --- | --- |
| unset (default) | Run if UTI surface changed since the previous tag, or if there is no previous tag (first release). Skip otherwise. |
| `INTEGRATION=1` | Force run, regardless of the UTI surface state. |
| `INTEGRATION=0` | Force skip. Prints a warning if the UTI surface changed since the previous tag. |

When integration tests run, `make release` runs `make install` first – this **replaces** `/Applications/QLOmni.app` (if present) with a fresh Release build and clears the QuickLook cache. To protect against silently clobbering a debug build you might be in the middle of investigating, the release prompts before doing this and shows the existing bundle's version and install date. Confirm with `y` to proceed, anything else aborts. Pass `ASSUME_YES=1` to skip the prompt for non-interactive use, or `INTEGRATION=0` to skip integration tests entirely.

### What `make version` does, and why it's not `agvtool`

`make version V=X.Y.Z` (the bump step inside `make release`) rewrites `MARKETING_VERSION` across all 6 target/config entries in `QLOmni.xcodeproj/project.pbxproj` (3 targets × Debug/Release), and verifies the replacement count matches the original line count – so you get an error rather than a silently partial bump if the regex ever stops matching. Requires three-level semver (`X.Y.Z`); two-level is rejected.

Apple's `agvtool` doesn't fit this project: it edits `CFBundleShortVersionString` in `Info.plist`, but our targets use `GENERATE_INFOPLIST_FILE = YES` and don't carry version keys in the source plists – the version comes from the `MARKETING_VERSION` build setting at build time. `make version` edits pbxproj directly for that reason.

CI also passes `MARKETING_VERSION=$VERSION` to `xcodebuild` from the tag, so the version stamped into `CFBundleShortVersionString` always matches the tag even if pbxproj somehow drifts. The pbxproj bump still matters because local `make build` / `make install` reads pbxproj.

To check the current version: `make print-version`. (It errors if the 6 entries disagree.)

### Moving an existing tag

If you tagged the wrong commit (e.g. forgot to include a hotfix that's now on `main`):

```sh
make retag V=1.2.3
```

Force-moves `v1.2.3` to current `HEAD` and force-pushes. CI re-runs and the release asset for `v1.2.3` is replaced (the workflow's release step is idempotent: `gh release create … || gh release upload --clobber`). Prompts before force-pushing.

The version number itself doesn't change. If you need a new version, use `make release V=1.2.4` instead.

### CI workflow modes

`.github/workflows/ci.yml` runs in three modes. Two are automatic:

- **push to `main` / pull request** – runs `test` only. Catches breakage early.
- **push tag `v*`** – runs `test` → `package` → `release`. This is how releases ship.

The third is manual via the Actions tab ("Run workflow" → pick a `mode`):

- **`test`** – unit tests only. Same as a push to `main`.
- **`dry-run`** – runs `test` and `package`, then stops. Produces a zip artifact (downloadable from the run page for 14 days) but creates no Release. Useful for verifying a build before tagging. Version is taken from the dispatch ref if it's a `v*` tag, otherwise stamped as `0.0.0-dryrun-<sha7>`.
- **`release`** – runs the full pipeline. Requires the dispatch ref to be a `v*` tag; fails fast otherwise. Useful for re-running a release that failed mid-pipeline without re-tagging.

### What the CI does *not* do

- **No notarization.** Releases are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`), not Developer ID signed and not notarized. First-launch Gatekeeper instructions are baked into the Release notes.
- **No integration tests.** See [Running tests](#running-tests). `make release` runs them locally when needed.
- **No automated changelog.** Release notes use `gh release create --generate-notes`, which assembles them from PR titles since the previous tag.

## Local build commands

Key `make` targets beyond `test` and `install`:

- `make build` – build only, no install. Output under `build/Build/Products/Release/`.
- `make build VERSION=1.2.3` – build with `MARKETING_VERSION` overridden, matching what CI does.
- `make print-version` – print the current `MARKETING_VERSION` (errors if entries disagree).
- `make purge-ls` – unregister stale Launch Services entries (see [README](README.md#install)).
- `make clean` – remove `build/`.
