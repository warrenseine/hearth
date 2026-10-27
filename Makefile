VERSION ?= 0.1.1

.PHONY: gen build test run clean release icon

# Regenerate Hearth.xcodeproj from project.yml (requires `brew install xcodegen`).
gen:
	xcodegen generate

# Run the HearthKit unit test suite (fast, no Xcode project needed).
test:
	cd HearthKit && swift test

# Build the app in Debug via xcodebuild (regenerates the project first).
build: gen
	xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Debug -destination 'platform=macOS' build

# Build and launch the app.
run: build
	open "$$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname 'Hearth-*' -print -quit)/Build/Products/Debug/Hearth.app"

clean:
	rm -rf Hearth.xcodeproj HearthKit/.build build dist

# Build an unsigned Release .app, zip it (ditto, so it stays double-clickable and Gatekeeper-sane
# to the extent an unsigned app can be), and write its sha256 for the Homebrew cask manifest.
# CURRENT_PROJECT_VERSION (CFBundleVersion) is stamped with the current time rather than left
# static: macOS's icon/LaunchServices caches key off bundle identity + version, so reinstalling
# over the same path with an unchanged version can leave a stale icon in the Dock/Quick Look
# even though the files on disk are current.
# Usage: make release VERSION=0.2.0
release: gen
	xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Release \
		-destination 'platform=macOS' -derivedDataPath build/DerivedData \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(shell date +%s) build
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent \
		"build/DerivedData/Build/Products/Release/Hearth.app" \
		"dist/Hearth-$(VERSION).zip"
	shasum -a 256 "dist/Hearth-$(VERSION).zip" | tee "dist/Hearth-$(VERSION).zip.sha256"
	@echo "Built dist/Hearth-$(VERSION).zip"

# Regenerate the app icon PNGs into the asset catalog.
icon:
	swift scripts/make-icon.swift Hearth/Resources/Assets.xcassets/AppIcon.appiconset
