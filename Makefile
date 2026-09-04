PROJECT     := QLOmni.xcodeproj
SCHEME      := QLOmni
CONFIG      := Release
BUILD_DIR   := build
APP_NAME    := QLOmni.app
INSTALL_DIR := /Applications
README      := README.md
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
NOTARY_PROFILE ?= qlomni-notary
SIGNING_IDENTITY ?= Developer ID Application: James Klein (NJ4W6LK8LG)
DEVELOPER_TEAM_ID ?= NJ4W6LK8LG

# Files that affect what integration tests verify (UTI routing per declared
# extension). `make release` re-runs integration tests automatically when a
# commit since the previous release tag touches any of these paths; otherwise
# the routing assertions can't have changed and the tests are skipped.
# Override with INTEGRATION=1 or INTEGRATION=0.
UTI_SURFACE := QLOmni/QLOmni/Info.plist QLOmniExtension/Info.plist integration/

.PHONY: all build install uninstall clean reinstall verify test test-release test-integration purge-ls version print-version print-uti-surface release release-dry-run release-resume release-integration retag supported check-supported check-docs-cover check-release-integration

all: build

# VERSION (optional): when set, overrides MARKETING_VERSION at build time so the
# bundle's CFBundleShortVersionString matches the requested release version
# CI dry runs and the guarded local release both set it explicitly
#
# EXTRA_EXTS (optional, build-from-source only): path to a file declaring extra
# file extensions to bake into the local bundle. See README "Building with extra
# extensions". Validation runs before xcodebuild so a bad file fails fast; the
# actual injection happens post-build, on the bundle's Info.plist (the source
# plist is never modified). Re-running with a different EXTRA_EXTS (or none)
# cleanly resets the bundle's extras since we strip user.qlomni-ext.* before
# adding new entries.
build:
	@$(if $(EXTRA_EXTS),./tools/extra-exts.sh validate "$(EXTRA_EXTS)")
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		$(if $(VERSION),MARKETING_VERSION=$(VERSION)) \
		build
	@bundle_plist="$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)/Contents/Info.plist"; \
	if [ -n "$(EXTRA_EXTS)" ]; then \
		./tools/extra-exts.sh apply "$(EXTRA_EXTS)" "$$bundle_plist"; \
		codesign --force --sign - $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME) >/dev/null 2>&1; \
	else \
		./tools/extra-exts.sh strip "$$bundle_plist" >/dev/null; \
		codesign --force --sign - $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME) >/dev/null 2>&1; \
	fi

# Xcode's RegisterWithLaunchServices build phase registers the build-output
# path with LS during `make build`. Without an unregister, that registration
# outlives the cp into $(INSTALL_DIR) and LS ends up knowing about both the
# build path and the live install -- which one wins for QuickLook dispatch
# is not guaranteed across rebuilds. Unregister the build path right after
# copying so LS only knows about $(INSTALL_DIR)/$(APP_NAME).
install: build
	rm -rf $(INSTALL_DIR)/$(APP_NAME)
	cp -R $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME) $(INSTALL_DIR)/
	xattr -dr com.apple.quarantine $(INSTALL_DIR)/$(APP_NAME) 2>/dev/null || true
	$(LSREGISTER) -u $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME) 2>/dev/null || true
	$(LSREGISTER) -f $(INSTALL_DIR)/$(APP_NAME)
	pluginkit -a $(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/QLOmniExtension.appex
	pluginkit -e use -i $$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/QLOmniExtension.appex/Contents/Info.plist) || true
	qlmanage -r
	qlmanage -r cache
	@echo "Installed $(APP_NAME) to $(INSTALL_DIR)"

reinstall: clean install

test: check-supported check-docs-cover test-release
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		test

test-release:
	bash -n scripts/package-release scripts/release scripts/verify-release Tests/Scripts/ReleaseCommandLineTests.sh Tests/Scripts/ReleaseWorkflowTests.sh
	bash Tests/Scripts/ReleaseCommandLineTests.sh
	bash Tests/Scripts/ReleaseWorkflowTests.sh

check-docs-cover:
	./tools/check-docs-cover.sh

test-integration:
	./integration/run.sh

verify:
	@echo "=== pluginkit registration ==="
	pluginkit -m -p com.apple.quicklook.preview | grep -i qlomni || echo "NOT FOUND"
	@echo "=== qlmanage plugins (Preview Extensions appear via PluginKit, not here) ==="
	qlmanage -m plugins 2>&1 | grep -iE 'qlomni|stephen' || echo "(no .qlgenerator hits, expected)"

# Strips stale QLOmni LS registrations left behind by old build paths,
# DerivedData, trashed bundles, etc. Skips $(INSTALL_DIR)/$(APP_NAME)
# itself so the live install is preserved. Re-registers the live install
# at the end to repopulate clean entries.
#
# Pass DRY_RUN=1 to print what would be unregistered/re-registered without
# touching Launch Services or QuickLook state.
purge-ls:
	@set -e; \
	if [ "$(DRY_RUN)" = "1" ]; then echo "=== DRY RUN: no Launch Services or QuickLook state will change ==="; fi; \
	echo "=== Stale QLOmni paths registered with Launch Services ==="; \
	paths=$$($(LSREGISTER) -dump 2>/dev/null | awk ' \
		/^----+$$/ { delete rec; next } \
		/^path: / { p = $$0; sub(/^path: +/, "", p); sub(/ \(0x[0-9a-f]+\)$$/, "", p); rec["path"] = p } \
		/^identifier: +dev\.j-256\.qlomni/ { \
			if ("path" in rec) print rec["path"] \
		}' | sort -u | grep -v '^$(INSTALL_DIR)/$(APP_NAME)' || true); \
	if [ -z "$$paths" ]; then \
		echo "(none)"; \
	else \
		echo "$$paths"; \
		echo "=== Unregistering each ==="; \
		echo "$$paths" | while IFS= read -r p; do \
			echo "lsregister -u $$p"; \
			[ "$(DRY_RUN)" = "1" ] || $(LSREGISTER) -u "$$p" || true; \
		done; \
	fi; \
	echo "=== Re-registering live install (if present) ==="; \
	if [ -d $(INSTALL_DIR)/$(APP_NAME) ]; then \
		echo "lsregister -f $(INSTALL_DIR)/$(APP_NAME)"; \
		[ "$(DRY_RUN)" = "1" ] || $(LSREGISTER) -f $(INSTALL_DIR)/$(APP_NAME); \
		echo "Re-registered $(INSTALL_DIR)/$(APP_NAME)"; \
	else \
		echo "$(INSTALL_DIR)/$(APP_NAME) not present; skipping re-register"; \
	fi; \
	echo "qlmanage -r; qlmanage -r cache"; \
	[ "$(DRY_RUN)" = "1" ] || { qlmanage -r; qlmanage -r cache; }

clean:
	rm -rf $(BUILD_DIR)

# Removes QLOmni completely from this machine. Unregisters every LS entry
# matching our bundle identifiers (live install, stale build paths, DerivedData,
# Trash leftovers), removes $(INSTALL_DIR)/$(APP_NAME), clears QuickLook caches,
# and restarts Finder so the change is visible immediately. Idempotent.
uninstall:
	@set -e; \
	echo "=== Unregistering all qlomni paths from Launch Services ==="; \
	paths=$$($(LSREGISTER) -dump 2>/dev/null | awk ' \
		/^----+$$/ { delete rec; next } \
		/^path: / { p = $$0; sub(/^path: +/, "", p); sub(/ \(0x[0-9a-f]+\)$$/, "", p); rec["path"] = p } \
		/^identifier: +dev\.j-256\.qlomni/ { \
			if ("path" in rec) print rec["path"] \
		}' | sort -u || true); \
	if [ -z "$$paths" ]; then \
		echo "(none registered)"; \
	else \
		echo "$$paths" | while IFS= read -r p; do \
			echo "lsregister -u $$p"; \
			$(LSREGISTER) -u "$$p" || true; \
		done; \
	fi; \
	echo "=== Removing $(INSTALL_DIR)/$(APP_NAME) ==="; \
	if [ -d $(INSTALL_DIR)/$(APP_NAME) ]; then \
		rm -rf $(INSTALL_DIR)/$(APP_NAME); \
		echo "Removed $(INSTALL_DIR)/$(APP_NAME)"; \
	else \
		echo "(not present)"; \
	fi; \
	echo "=== Clearing QuickLook cache and restarting Finder ==="; \
	qlmanage -r >/dev/null 2>&1; \
	qlmanage -r cache >/dev/null 2>&1; \
	killall Finder 2>/dev/null || true; \
	echo "=== Verification ==="; \
	if [ -d $(INSTALL_DIR)/$(APP_NAME) ]; then echo "FAIL: $(INSTALL_DIR)/$(APP_NAME) still present"; exit 1; fi; \
	leftover_pk=$$(pluginkit -m -p com.apple.quicklook.preview 2>/dev/null | grep -i qlomni || true); \
	leftover_ls=$$($(LSREGISTER) -dump 2>/dev/null | grep 'identifier: *dev\.j-256\.qlomni' | sort -u || true); \
	if [ -n "$$leftover_pk" ]; then echo "WARN: pluginkit still lists qlomni:"; echo "$$leftover_pk" | sed 's/^/  /'; fi; \
	if [ -n "$$leftover_ls" ]; then echo "WARN: lsregister still has qlomni entries:"; echo "$$leftover_ls" | sed 's/^/  /'; fi; \
	if [ -z "$$leftover_pk" ] && [ -z "$$leftover_ls" ]; then echo "(clean)"; fi; \
	echo "Uninstall complete."

# Bump MARKETING_VERSION across all targets/configs in pbxproj. Use:
#   make version V=1.2.3
#
# agvtool doesn't fit here -- it edits Info.plist's CFBundleShortVersionString,
# but our targets use GENERATE_INFOPLIST_FILE=YES, so the version comes from
# the MARKETING_VERSION build setting in pbxproj instead. We sed it directly,
# then verify the replacement count matches the original line count -- guards
# against future pbxproj format changes silently breaking the regex.
#
# The README's `pluginkit` verification example pins the same version (so the
# printed output matches a fresh install); it's synced here from the single
# `make release` bump rather than hand-edited each cut, applying the same
# before/after guard so a format drift fails loudly instead of going stale.
version:
	@if [ -z "$(V)" ]; then echo "usage: make version V=<X.Y.Z>"; exit 2; fi
	@case "$(V)" in \
		[0-9]*.[0-9]*.[0-9]*) ;; \
		*) echo "V='$(V)' must be X.Y.Z (e.g. 1.2.3)"; exit 2 ;; \
	esac
	@before=$$(grep -c '^[[:space:]]*MARKETING_VERSION = ' $(PROJECT)/project.pbxproj); \
	if [ "$$before" -eq 0 ]; then echo "no MARKETING_VERSION lines found in pbxproj"; exit 1; fi; \
	sed -i '' -E 's/^([[:space:]]*MARKETING_VERSION = )[^;]+;/\1$(V);/' $(PROJECT)/project.pbxproj; \
	after=$$(grep -c "^[[:space:]]*MARKETING_VERSION = $(V);" $(PROJECT)/project.pbxproj); \
	if [ "$$before" -ne "$$after" ]; then \
		echo "MARKETING_VERSION mismatch: $$before lines before, $$after at $(V) after"; \
		echo "pbxproj may have been left in an inconsistent state -- check git diff"; \
		exit 1; \
	fi; \
	echo "Updated $$after MARKETING_VERSION line(s) to $(V)"
	@rbefore=$$(grep -cE 'QLOmniExtension\([0-9]+\.[0-9]+\.[0-9]+\)' $(README)); \
	if [ "$$rbefore" -eq 0 ]; then echo "no versioned QLOmniExtension example found in $(README)"; exit 1; fi; \
	sed -i '' -E 's/QLOmniExtension\([0-9]+\.[0-9]+\.[0-9]+\)/QLOmniExtension($(V))/' $(README); \
	rafter=$$(grep -cE "QLOmniExtension\($(V)\)" $(README)); \
	if [ "$$rbefore" -ne "$$rafter" ]; then \
		echo "$(README) version mismatch: $$rbefore example(s) before, $$rafter at $(V) after"; \
		echo "$(README) may have been left inconsistent -- check git diff"; \
		exit 1; \
	fi; \
	echo "Updated $$rafter $(README) version example(s) to $(V)"

# Print the current MARKETING_VERSION. Errors if the 6 entries disagree --
# `make version` keeps them in lockstep, so disagreement means a hand-edit.
print-version:
	@versions=$$(grep -E '^[[:space:]]*MARKETING_VERSION = ' $(PROJECT)/project.pbxproj \
		| sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | sort -u); \
	count=$$(echo "$$versions" | wc -l | tr -d ' '); \
	if [ "$$count" -ne 1 ]; then \
		echo "MARKETING_VERSION entries disagree:"; \
		echo "$$versions" | sed 's/^/  /'; \
		echo "Run: make version V=<X.Y.Z> to resync."; \
		exit 1; \
	fi; \
	echo "$$versions"

# Print the paths that determine whether release integration tests should run
print-uti-surface:
	@printf '%s\n' "$(UTI_SURFACE)"

# Build, notarize, verify, then publish a release from this Mac
release:
	./scripts/release --version "$(V)" --keychain-profile "$(NOTARY_PROFILE)" --signing-identity "$(SIGNING_IDENTITY)" --team-id "$(DEVELOPER_TEAM_ID)"

# Exercise the complete local package gate without changing Git or GitHub
release-dry-run:
	./scripts/release --dry-run --version "$(V)" --keychain-profile "$(NOTARY_PROFILE)" --signing-identity "$(SIGNING_IDENTITY)" --team-id "$(DEVELOPER_TEAM_ID)"

# Resume only the missing publication steps after revalidating local bytes
release-resume:
	./scripts/release --resume --version "$(V)" --keychain-profile "$(NOTARY_PROFILE)" --signing-identity "$(SIGNING_IDENTITY)" --team-id "$(DEVELOPER_TEAM_ID)"

# Install the candidate and exercise UTI routing when the release guard asks
release-integration:
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		existing_ver=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(INSTALL_DIR)/$(APP_NAME)/Contents/Info.plist" 2>/dev/null || echo "?"); \
		existing_date=$$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$(INSTALL_DIR)/$(APP_NAME)" 2>/dev/null || echo "?"); \
		echo "    integration preflight will replace $(INSTALL_DIR)/$(APP_NAME)"; \
		echo "    currently v$$existing_ver, installed $$existing_date"; \
		if [ "$(ASSUME_YES)" != "1" ]; then \
			printf "    Continue? [y/N] "; read ans; \
			case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted. Use INTEGRATION=0 to skip, or ASSUME_YES=1 to skip this prompt."; exit 1 ;; esac; \
		fi; \
	fi
	$(MAKE) install
	$(MAKE) test-integration

# Published release tags are immutable; recovery uses release-resume instead
retag:
	@echo "Refusing to move a published release tag. Cut a new version instead."
	@exit 1

# Regenerate SUPPORTED.md from the Info.plists. Cheap (millisecond-scale);
# safe to run any time. The plists are canonical; SUPPORTED.md is a generated
# artifact -- hand-edits get clobbered.
supported:
	./tools/gen-supported.sh

# Drift check: fails if SUPPORTED.md is out of date relative to the plists.
# Wired as a dependency of `make test` so the check runs locally and in CI
# without a separate workflow step.
check-supported:
	./tools/gen-supported.sh --check

# Predict whether `make release` would run integration tests right now,
# without changing any state. Honors the same INTEGRATION env var. Exits 0
# if integration would run, 1 if it would skip. The release orchestrator
# invokes this target for its decision, so the two stay in sync
check-release-integration:
	@INTEGRATION="$(INTEGRATION)" UTI_SURFACE="$(UTI_SURFACE)" ./tools/check-release-integration.sh

# Audit: report extensions QLOmni declares that also have an active claim
# from another bundle on this machine (Apple CoreTypes, Xcode, etc.). Splits
# output into different-UTI conflicts (real divergence) and same-UTI imports
# (informational). Local-only -- depends on the LS state of the machine.
audit-collisions:
	./tools/audit-collisions.sh
