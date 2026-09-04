# Contributing

## Running tests

Two test suites have different scopes and side effects:

| Suite | Command | Verifies | Side effects | Runs in CI |
| --- | --- | --- | --- | --- |
| Unit | `make test` | Swift behavior, documentation drift, and release safeguards | None outside `build/` | Yes |
| Integration | `make install && make test-integration` | Each declared extension resolves to its expected UTI and PluginKit sees QLOmni | Replaces `/Applications/QLOmni.app`, registers it, and clears Quick Look caches | No |

Integration tests do not verify rendering correctness. That still requires opening a Quick Look preview.

### When integration tests need to run

UTI routing is controlled by the host and extension plists plus the integration harness. The guarded release checks those paths since the previous version tag and runs integration tests only when their result could have changed. Override the decision with `INTEGRATION=1` to force them or `INTEGRATION=0` to skip them. When they run, the command explains that it will replace the installed app and asks first; `ASSUME_YES=1` skips that prompt.

## Local release credentials

Official releases are signed and notarized on a maintainer Mac. GitHub Actions has no Apple credentials and cannot publish an official release.

The Mac needs the Developer ID Application identity in its login Keychain. Confirm that `security find-identity -v -p codesigning` lists the identity configured by `SIGNING_IDENTITY` in the Makefile.

Store the dedicated notarization credential directly in Keychain through `notarytool`:

```sh
xcrun notarytool store-credentials qlomni-notary \
  --apple-id <apple-account-email> \
  --team-id <developer-team-id>
```

The command securely prompts for the app-specific password. Do not put that password in an environment variable, shell history, repository file, or exported credential bundle. Validate the stored profile without exposing it:

```sh
xcrun notarytool history --keychain-profile qlomni-notary --output-format json
```

Override `NOTARY_PROFILE`, `SIGNING_IDENTITY`, or `DEVELOPER_TEAM_ID` on the `make` command line if the local names differ.

## Testing the complete local package gate

Before publishing, exercise the same build, signing, notarization, stapling, and verification path without changing Git or GitHub:

```sh
make release-dry-run V=1.2.3
```

The result is written under `build/releases/dry-run/` with its SHA-256 checksum. The version supplied to `V` is stamped into both bundles and verified exactly. Remove or move an earlier dry-run artifact before retrying the same version.

## Cutting a release

Start from a clean `main` whose remote history is not ahead or divergent, then run:

```sh
make release V=1.2.3
```

The guarded command performs this sequence:

1. Confirm the branch, clean tree, remote state, GitHub authentication, unused version tag, and absence of `EXTRA_EXTS`.
2. Run unit and release tests, then any required local integration tests.
3. Update the project version and build a universal app with that exact version.
4. Sign the nested Quick Look extension before the host app, using hardened runtime, secure timestamps, and the explicit release entitlements.
5. Submit to Apple with the named Keychain profile, require acceptance, staple the ticket, and build the final ZIP.
6. Verify both bundle versions, arm64 and x86_64 slices, deployment targets, Developer ID signatures, hardened runtime, timestamps, entitlements, staple validity, Gatekeeper acceptance, and the SHA-256 checksum.
7. Commit the version files and create the annotated local tag.
8. Reverify the artifact, atomically publish `main` and the tag, reverify once more, and create the GitHub Release with the ZIP and checksum.

No commit, tag, release, or asset is sent to GitHub before the signed artifact passes the local gate. The GitHub Release is the final publication step.

### Failure recovery

Failures before the release commit automatically restore the version files and remove partial release outputs. Fix the reported problem and rerun `make release V=...`.

Failures after the release commit preserve the verified artifact and any local tag. Do not rerun the fresh release command and do not move the tag. Resolve the network, authentication, or GitHub problem, then run:

```sh
make release-resume V=1.2.3
```

Resume requires the matching version commit at `HEAD`. It verifies an existing ZIP and checksum again, or rebuilds them if both are absent, then creates only the missing local tag, remote refs, Release, or assets. If only one output exists or verification fails, move the incomplete files aside for investigation and rerun resume. If remote `main` diverged, reconcile it without rewriting the release tag, then resume.

Published version tags are immutable. Cut a new version for a correction; `make retag` intentionally refuses to move a release tag.

## CI workflow modes

CI remains secretless:

- Pushes and pull requests run `make test`.
- Version tags also build and verify a universal ad-hoc app, then upload a clearly named `qlomni-adhoc-dry-run` workflow artifact.
- Manual `test` and `dry-run` modes provide the same checks without Apple credentials.

The ad-hoc workflow artifact is diagnostic only. It is not Developer ID signed, notarized, stapled, or attached to a GitHub Release.

## Version and local build commands

`make version V=X.Y.Z` updates every `MARKETING_VERSION` build setting and the versioned README example, with guards against a partial replacement. The targets use generated Info.plists, so `agvtool` is not appropriate here. `make print-version` reports disagreement between project settings.

Other useful commands:

- `make build` builds a universal ad-hoc app under `build/`.
- `make build VERSION=1.2.3` overrides the bundle version without editing the project.
- `make build EXTRA_EXTS=<file>` injects personal UTI declarations only into a local bundle. Release commands reject it.
- `make test-release` exercises credential isolation, signing order, notarization failures, cleanup, verification, and publication ordering with mocks.
- `make purge-ls` unregisters stale Launch Services entries.
- `make clean` removes `build/`.
