PROJECT     := QLOmni.xcodeproj
SCHEME      := QLOmni
CONFIG      := Release
BUILD_DIR   := build
APP_NAME    := QLOmni.app
INSTALL_DIR := /Applications
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Files that affect what integration tests verify (UTI routing per declared
# extension). `make release` re-runs integration tests automatically when a
# commit since the previous release tag touches any of these paths; otherwise
# the routing assertions can't have changed and the tests are skipped.
# Override with INTEGRATION=1 or INTEGRATION=0.
UTI_SURFACE := QLOmni/QLOmni/Info.plist QLOmniExtension/Info.plist integration/

.PHONY: all build install uninstall clean reinstall verify test test-integration purge-ls version print-version release retag supported check-supported check-release-integration

all: build

# VERSION (optional): when set, overrides MARKETING_VERSION at build time so the
# bundle's CFBundleShortVersionString matches the release tag without needing a
# pbxproj edit. CI sets this from the tag; locally it's empty and pbxproj wins.
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		$(if $(VERSION),MARKETING_VERSION=$(VERSION)) \
		build

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
	pluginkit -e use -i dev.j-256.qlomni.QLOmniExtension || true
	qlmanage -r
	qlmanage -r cache
	@echo "Installed $(APP_NAME) to $(INSTALL_DIR)"

reinstall: clean install

test: check-supported
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		test

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
		/^identifier: +(dev\.j-256\.qlomni|dev\.jklein\.qlomni)/ { \
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
		/^identifier: +(dev\.j-256\.qlomni|dev\.jklein\.qlomni)/ { \
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
	leftover_ls=$$($(LSREGISTER) -dump 2>/dev/null | grep -E 'identifier: +(dev\.j-256\.qlomni|dev\.jklein\.qlomni)' | sort -u || true); \
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

# Cut a release: bump pbxproj, commit, tag, push. Use: make release V=X.Y.Z
#
# Preflight checks run first (no state changes if any fail). Then the steps
# that mutate state run with revert-on-failure for the early ones; the late
# ones (tag create, push) print resume instructions instead -- a network
# failure on push is the common case and we'd rather you retry the push
# than re-run tests and re-tag.
#
# Commit message and tag message are both bare-version (e.g. "1.2.3"),
# matching `npm version`'s default output for cross-project consistency.
# Tag is annotated, not lightweight.
release:
	@if [ -z "$(V)" ]; then echo "usage: make release V=<X.Y.Z>"; exit 2; fi
	@case "$(V)" in \
		[0-9]*.[0-9]*.[0-9]*) ;; \
		*) echo "V='$(V)' must be X.Y.Z (e.g. 1.2.3)"; exit 2 ;; \
	esac
	@branch=$$(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)"); \
	if [ "$$branch" != "main" ]; then \
		echo "Refusing to release from branch '$$branch'; switch to main first."; \
		exit 1; \
	fi
	@if ! git diff-index --quiet HEAD --; then \
		echo "Working tree has uncommitted changes. Stash or commit them first:"; \
		git status --short; \
		exit 1; \
	fi
	@if git rev-parse --verify --quiet "refs/tags/v$(V)" >/dev/null; then \
		echo "Tag v$(V) already exists locally. Pick a new version, or:"; \
		echo "  git tag -d v$(V) && git push origin :v$(V)"; \
		echo "  gh release delete v$(V)   # if a release was already created"; \
		exit 1; \
	fi
	@if git ls-remote --exit-code --tags origin "refs/tags/v$(V)" >/dev/null 2>&1; then \
		echo "Tag v$(V) already exists on origin. Pick a new version."; \
		exit 1; \
	fi
	@echo "==> preflight: running unit tests"
	@$(MAKE) test
	@INTEGRATION="$(INTEGRATION)" UTI_SURFACE="$(UTI_SURFACE)" ./tools/check-release-integration.sh; rc=$$?; \
	case "$$rc" in \
		0) ;; \
		1) exit 0 ;; \
		*) exit $$rc ;; \
	esac; \
	if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		existing_ver=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(INSTALL_DIR)/$(APP_NAME)/Contents/Info.plist" 2>/dev/null || echo "?"); \
		existing_date=$$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$(INSTALL_DIR)/$(APP_NAME)" 2>/dev/null || echo "?"); \
		echo "    integration preflight will run 'make install', which replaces"; \
		echo "    $(INSTALL_DIR)/$(APP_NAME) (currently v$$existing_ver, installed $$existing_date)"; \
		echo "    with a fresh Release build, and clears the QuickLook cache."; \
		if [ "$(ASSUME_YES)" != "1" ]; then \
			printf "    Continue? [y/N] "; read ans; \
			case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted. Use INTEGRATION=0 to skip integration tests, or ASSUME_YES=1 to skip this prompt."; exit 1 ;; esac; \
		else \
			echo "    ASSUME_YES=1 set; continuing without prompt."; \
		fi; \
	else \
		echo "    integration preflight will run 'make install' (no existing $(APP_NAME) to replace)."; \
	fi; \
	if ! $(MAKE) install; then echo "install failed during integration preflight"; exit 1; fi; \
	if ! $(MAKE) test-integration; then echo "integration tests failed"; exit 1; fi
	@echo "==> bumping pbxproj to $(V)"
	@if ! $(MAKE) version V=$(V); then \
		echo "Bump failed; reverting pbxproj."; \
		git checkout -- $(PROJECT)/project.pbxproj; \
		exit 1; \
	fi
	@echo "==> committing"
	@if ! git commit -am "$(V)"; then \
		echo "Commit failed; reverting pbxproj. Fix the underlying issue and rerun."; \
		git checkout -- $(PROJECT)/project.pbxproj; \
		exit 1; \
	fi
	@echo "==> tagging v$(V)"
	@if ! git tag -a "v$(V)" -m "$(V)"; then \
		echo "Tag creation failed. The release commit is in place but untagged."; \
		echo "To finish manually:"; \
		echo "  git tag -a v$(V) -m $(V) && git push origin main v$(V)"; \
		echo "Or to undo the commit and start over:"; \
		echo "  git reset --hard HEAD~1"; \
		exit 1; \
	fi
	@echo "==> pushing main + v$(V) to origin"
	@if ! git push origin main "v$(V)"; then \
		echo ""; \
		echo "Push failed. Commit and tag exist locally; nothing to redo."; \
		echo "When the network/auth issue is resolved, finish with:"; \
		echo "  git push origin main v$(V)"; \
		exit 1; \
	fi
	@echo ""
	@echo "Released v$(V). Watch CI: https://github.com/j-256/qlomni/actions"

# Move tag vX.Y.Z to current HEAD and force-push it. Use when you've already
# released a version but need to point the tag at a different commit (e.g.
# you tagged the wrong commit or pushed a hotfix). CI re-runs and replaces
# the release asset; the version number itself doesn't change.
retag:
	@if [ -z "$(V)" ]; then echo "usage: make retag V=<X.Y.Z>"; exit 2; fi
	@case "$(V)" in \
		[0-9]*.[0-9]*.[0-9]*) ;; \
		*) echo "V='$(V)' must be X.Y.Z"; exit 2 ;; \
	esac
	@if ! git rev-parse --verify --quiet "refs/tags/v$(V)" >/dev/null; then \
		echo "Tag v$(V) doesn't exist locally. Use 'make release V=$(V)' for a fresh release."; \
		exit 1; \
	fi
	@old=$$(git rev-parse "v$(V)"); new=$$(git rev-parse HEAD); \
	if [ "$$old" = "$$new" ]; then \
		echo "Tag v$(V) already points at HEAD ($${new:0:7}); nothing to do."; \
		exit 0; \
	fi; \
	echo "About to move tag v$(V):"; \
	echo "  from $${old:0:7} $$(git log -1 --format='%s' $$old)"; \
	echo "  to   $${new:0:7} $$(git log -1 --format='%s' $$new)"; \
	echo "and force-push to origin. This re-triggers CI and overwrites the"; \
	echo "release asset for v$(V)."; \
	printf "Continue? [y/N] "; read ans; \
	case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 1 ;; esac
	@git tag -a -f "v$(V)" -m "$(V)"
	@if ! git push origin "v$(V)" --force; then \
		echo ""; \
		echo "Push failed. Local tag now points at HEAD; remote unchanged."; \
		echo "Retry with: git push origin v$(V) --force"; \
		exit 1; \
	fi
	@echo "Retagged v$(V). Watch CI: https://github.com/j-256/qlomni/actions"

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
# if integration would run, 1 if it would skip. The release: target shells
# out to the same script for its decision, so the two stay in sync.
check-release-integration:
	@INTEGRATION="$(INTEGRATION)" UTI_SURFACE="$(UTI_SURFACE)" ./tools/check-release-integration.sh

# Audit: report extensions QLOmni declares that also have an active claim
# from another bundle on this machine (Apple CoreTypes, Xcode, etc.). Splits
# output into different-UTI conflicts (real divergence) and same-UTI imports
# (informational). Local-only -- depends on the LS state of the machine.
audit-collisions:
	./tools/audit-collisions.sh
