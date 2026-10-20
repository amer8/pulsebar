FORMAT_CONFIG := .swift-format
SWIFT_FORMAT_PATHS := Package.swift Sources Tests
-include version.env
MARKETING_VERSION ?= 0.1.0
BUILD_NUMBER ?= $(MARKETING_VERSION)
APP_NAME := PulseBar
APP_DISPLAY_NAME := PulseBar
APP_VERSION ?= $(MARKETING_VERSION)
RELEASE_DATE ?= $(shell awk -v version="$(APP_VERSION)" '$$1 == "\#\#" && $$2 == version && $$3 == "-" { print $$4; exit }' CHANGELOG.md)
BUNDLE_IDENTIFIER ?= dev.pulsebar.PulseBar
BUILD_CONFIGURATION := release
RELEASE_ARCH_ARGS ?=
BUILD_DIR := .build/$(BUILD_CONFIGURATION)
BUNDLE_DIR := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
FRAMEWORKS_DIR := $(CONTENTS_DIR)/Frameworks
INFO_PLIST := Packaging/Info.plist
ICON_SOURCE := Packaging/Icon.icon
ICON_COMPOSER_TOOL ?= $(shell xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool
ICON_EXPORT := $(BUILD_DIR)/$(APP_NAME)-AppIcon.png
ICON_FILE := AppIcon.icns
ICONSET_DIR := $(BUILD_DIR)/$(APP_NAME).iconset
README_ASSET_DIR := docs/assets
README_APP_ICON := $(README_ASSET_DIR)/app-icon.png
ARTIFACT_DIR := $(BUILD_DIR)/artifacts
DMG_ROOT_DIR := $(BUILD_DIR)/dmg-root
DMG_NAME ?= $(APP_NAME)-$(APP_VERSION).dmg
DMG_PATH := $(ARTIFACT_DIR)/$(DMG_NAME)
DMG_VOLUME_NAME ?= $(APP_DISPLAY_NAME)
ZIP_NAME ?= $(APP_NAME)-$(APP_VERSION).zip
ZIP_PATH := $(ARTIFACT_DIR)/$(ZIP_NAME)
DSYM_DIR := $(BUILD_DIR)/$(APP_NAME).dSYM
DSYM_ZIP_NAME ?= $(APP_NAME)-$(APP_VERSION).dSYM.zip
DSYM_ZIP_PATH := $(ARTIFACT_DIR)/$(DSYM_ZIP_NAME)
CODESIGN_IDENTITY ?=
CODESIGN_APP_OPTIONS ?= --timestamp --options runtime
CODESIGN_DMG_OPTIONS ?= --timestamp
NOTARY_PROFILE ?= pulsebar-notary
APPCAST_URL ?= https://raw.githubusercontent.com/amer8/pulsebar/main/appcast.xml
SPARKLE_PUBLIC_ED_KEY ?=
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
NOTARIZE_APP_ZIP := /tmp/$(APP_NAME)Notarize.zip

.PHONY: build test runtime-check format format-lint check readme-assets release bundle sign notarize-app dmg signed-dmg notarize-dmg notarize-dmg-only release-dmg zip signed-zip release-zip release-artifacts package-dmg package-zip package-dsym install uninstall
.NOTPARALLEL: release-dmg release-zip release-artifacts notarize-dmg

build:
	swift build -Xswiftc -warnings-as-errors

release:
	swift build -c $(BUILD_CONFIGURATION) $(RELEASE_ARCH_ARGS) -Xswiftc -warnings-as-errors

bundle: release
	rm -rf "$(BUNDLE_DIR)"
	rm -rf "$(ICONSET_DIR)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(FRAMEWORKS_DIR)"
	mkdir -p "$(ICONSET_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@if [ -d "$(BUILD_DIR)/Sparkle.framework" ]; then \
		/usr/bin/ditto "$(BUILD_DIR)/Sparkle.framework" "$(FRAMEWORKS_DIR)/Sparkle.framework"; \
		ln -sf "../Frameworks/Sparkle.framework" "$(MACOS_DIR)/Sparkle.framework"; \
	fi
	cp "$(INFO_PLIST)" "$(CONTENTS_DIR)/Info.plist"
	"$(ICON_COMPOSER_TOOL)" "$(ICON_SOURCE)" --export-image --output-file "$(ICON_EXPORT)" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
	sips -z 16 16 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_16x16.png"
	sips -z 32 32 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_16x16@2x.png"
	sips -z 32 32 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_32x32.png"
	sips -z 64 64 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_32x32@2x.png"
	sips -z 128 128 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_128x128.png"
	sips -z 256 256 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_128x128@2x.png"
	sips -z 256 256 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_256x256.png"
	sips -z 512 512 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_256x256@2x.png"
	sips -z 512 512 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_512x512.png"
	sips -z 1024 1024 "$(ICON_EXPORT)" --out "$(ICONSET_DIR)/icon_512x512@2x.png"
	iconutil -c icns "$(ICONSET_DIR)" -o "$(RESOURCES_DIR)/$(ICON_FILE)"
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(APP_DISPLAY_NAME)" "$(CONTENTS_DIR)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $(ICON_FILE)" "$(CONTENTS_DIR)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_IDENTIFIER)" "$(CONTENTS_DIR)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" "$(CONTENTS_DIR)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS_DIR)/Info.plist"
	/usr/libexec/PlistBuddy -c "Delete :PulseBarReleaseDate" "$(CONTENTS_DIR)/Info.plist" >/dev/null 2>&1 || true
	@if [ -n "$(RELEASE_DATE)" ]; then \
		/usr/libexec/PlistBuddy -c "Add :PulseBarReleaseDate string $(RELEASE_DATE)" "$(CONTENTS_DIR)/Info.plist"; \
	fi
	/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$(CONTENTS_DIR)/Info.plist" >/dev/null 2>&1 || true
	/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$(CONTENTS_DIR)/Info.plist" >/dev/null 2>&1 || true
	/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$(CONTENTS_DIR)/Info.plist" >/dev/null 2>&1 || true
	/usr/libexec/PlistBuddy -c "Delete :SUEnableInstallerLauncherService" "$(CONTENTS_DIR)/Info.plist" >/dev/null 2>&1 || true
	@if [ -n "$(SPARKLE_PUBLIC_ED_KEY)" ]; then \
		/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $(APPCAST_URL)" "$(CONTENTS_DIR)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(SPARKLE_PUBLIC_ED_KEY)" "$(CONTENTS_DIR)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$(CONTENTS_DIR)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool true" "$(CONTENTS_DIR)/Info.plist"; \
	fi
	printf 'APPL????' > "$(CONTENTS_DIR)/PkgInfo"

sign: bundle
	@if [ -z "$(CODESIGN_IDENTITY)" ]; then \
		echo "CODESIGN_IDENTITY is required for signing." >&2; \
		exit 1; \
	fi
	@if [ -d "$(FRAMEWORKS_DIR)/Sparkle.framework" ]; then \
		if [ -d "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ]; then \
			codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"; \
		fi; \
		if [ -d "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" ]; then \
			codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) --preserve-metadata=entitlements "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"; \
		fi; \
		if [ -f "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/Autoupdate" ]; then \
			codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/Autoupdate"; \
		fi; \
		if [ -d "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/Updater.app" ]; then \
			codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) "$(FRAMEWORKS_DIR)/Sparkle.framework/Versions/B/Updater.app"; \
		fi; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) "$(FRAMEWORKS_DIR)/Sparkle.framework"; \
	fi
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_APP_OPTIONS) "$(BUNDLE_DIR)"
	codesign --verify --strict --verbose=2 "$(BUNDLE_DIR)"

notarize-app: sign
	rm -f "$(NOTARIZE_APP_ZIP)"
	/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$(BUNDLE_DIR)" "$(NOTARIZE_APP_ZIP)"
	xcrun notarytool submit "$(NOTARIZE_APP_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(BUNDLE_DIR)"
	xcrun stapler validate "$(BUNDLE_DIR)"
	spctl -a -t exec -vv "$(BUNDLE_DIR)"

dmg: bundle package-dmg

signed-dmg: sign package-dmg

notarize-dmg: signed-dmg notarize-dmg-only

notarize-dmg-only:
	xcrun notarytool submit "$(DMG_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	spctl --assess --type open --context context:primary-signature --verbose=4 "$(DMG_PATH)"

release-dmg: notarize-app package-dmg notarize-dmg-only

zip: bundle package-zip

signed-zip: sign package-zip

release-zip: notarize-app package-zip package-dsym

release-artifacts: release-zip package-dmg notarize-dmg-only

package-dmg:
	rm -rf "$(DMG_ROOT_DIR)"
	mkdir -p "$(DMG_ROOT_DIR)" "$(ARTIFACT_DIR)"
	cp -R "$(BUNDLE_DIR)" "$(DMG_ROOT_DIR)/"
	ln -s /Applications "$(DMG_ROOT_DIR)/Applications"
	hdiutil create -volname "$(DMG_VOLUME_NAME)" -srcfolder "$(DMG_ROOT_DIR)" -ov -format UDZO "$(DMG_PATH)"
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_DMG_OPTIONS) "$(DMG_PATH)"; \
		codesign --verify --verbose=2 "$(DMG_PATH)"; \
	fi
	@echo "Created $(DMG_PATH)"

package-zip:
	mkdir -p "$(ARTIFACT_DIR)"
	rm -f "$(ZIP_PATH)"
	/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$(BUNDLE_DIR)" "$(ZIP_PATH)"
	@echo "Created $(ZIP_PATH)"

package-dsym:
	@if [ ! -d "$(DSYM_DIR)" ]; then \
		echo "dSYM is required for release but was not found at $(DSYM_DIR)." >&2; \
		exit 1; \
	fi
	mkdir -p "$(ARTIFACT_DIR)"
	rm -f "$(DSYM_ZIP_PATH)"
	/usr/bin/ditto -c -k --keepParent "$(DSYM_DIR)" "$(DSYM_ZIP_PATH)"
	@echo "Created $(DSYM_ZIP_PATH)"

install: bundle
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(BUNDLE_DIR)" "$(INSTALL_DIR)/"

uninstall:
	rm -rf "$(INSTALLED_APP)"

test:
	swift test -Xswiftc -warnings-as-errors

format:
	swift format format --in-place --configuration $(FORMAT_CONFIG) --recursive $(SWIFT_FORMAT_PATHS)

format-lint:
	swift format lint --strict --configuration $(FORMAT_CONFIG) --recursive $(SWIFT_FORMAT_PATHS)

runtime-check: build
	swift run --skip-build PulseBar --check-runtime

check: format-lint build test runtime-check

readme-assets:
	mkdir -p "$(README_ASSET_DIR)"
	"$(ICON_COMPOSER_TOOL)" "$(ICON_SOURCE)" --export-image --output-file "$(README_APP_ICON)" --platform macOS --rendition Default --width 512 --height 512 --scale 1
	swift run pulsebar-tools render-readme-assets
