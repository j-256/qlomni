PROJECT     := QLOmni.xcodeproj
SCHEME      := QLOmni
CONFIG      := Release
BUILD_DIR   := build
APP_NAME    := QLOmni.app
INSTALL_DIR := /Applications

.PHONY: all build install clean reinstall verify test test-integration

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
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f $(INSTALL_DIR)/$(APP_NAME)
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

clean:
	rm -rf $(BUILD_DIR)
