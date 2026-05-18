PROJECT     := QLOmni.xcodeproj
SCHEME      := QLOmni
CONFIG      := Release
BUILD_DIR   := build
APP_NAME    := QLOmni.app
INSTALL_DIR := /Applications
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build install clean reinstall verify test test-integration purge-ls

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
		build

install: build
	rm -rf $(INSTALL_DIR)/$(APP_NAME)
	cp -R $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME) $(INSTALL_DIR)/
	xattr -dr com.apple.quarantine $(INSTALL_DIR)/$(APP_NAME) 2>/dev/null || true
	$(LSREGISTER) -f $(INSTALL_DIR)/$(APP_NAME)
	pluginkit -e use -i dev.j-256.qlomni.QLOmniExtension || true
	qlmanage -r
	qlmanage -r cache
	@echo "Installed $(APP_NAME) to $(INSTALL_DIR)"

reinstall: clean install

test:
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
purge-ls:
	@set -e; \
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
			$(LSREGISTER) -u "$$p" || true; \
		done; \
	fi; \
	echo "=== Re-registering live install (if present) ==="; \
	if [ -d $(INSTALL_DIR)/$(APP_NAME) ]; then \
		$(LSREGISTER) -f $(INSTALL_DIR)/$(APP_NAME); \
		echo "Re-registered $(INSTALL_DIR)/$(APP_NAME)"; \
	else \
		echo "$(INSTALL_DIR)/$(APP_NAME) not present; skipping re-register"; \
	fi; \
	qlmanage -r; \
	qlmanage -r cache

clean:
	rm -rf $(BUILD_DIR)
