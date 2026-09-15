# Claude Switcher — build system
#
# Layout:
#   Sources/ClaudeSwitcherCore  library "ClaudeSwitcherCore" (pure logic, tested)
#   Sources/ClaudeSwitcher      executable "claude-switcher" (AppKit UI)
#   Tests/ClaudeSwitcherTests   tests against ClaudeSwitcherCore

SHELL := /bin/bash
APP_NAME := Claude Switcher
APP_BUNDLE := build/$(APP_NAME).app
INSTALL_DIR := /Applications

.DEFAULT_GOAL := build
.PHONY: build test icon bundle install notarize dmg notarize-dmg release-artifacts dist clean dry-run

build:
	swift build -c release

test:
	swift test

# Regenerate assets/AppIcon.icns from assets/AppIcon.png. The .icns is committed,
# so this is only needed when the artwork changes.
icon:
	scripts/make-icon.sh

bundle: build
	scripts/bundle.sh

install: bundle
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/"
	@echo ""
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Note: Launch at Login is toggled from the menu bar menu, not from this installer."

# Notarize + staple the bundled app. Requires a Developer ID Application
# signature (see scripts/bundle.sh) and notarytool credentials.
notarize:
	scripts/notarize.sh

# A drag-to-Applications disk image, signed with the same identity as the app.
dmg: bundle
	scripts/dmg.sh

notarize-dmg:
	TARGET=dmg scripts/notarize.sh

# The full path to a shippable download: sign, notarize + staple the app, wrap it
# in a disk image, then notarize + staple the image itself.
release-artifacts: bundle
	$(MAKE) notarize
	scripts/dmg.sh
	$(MAKE) notarize-dmg

# A zip other people can actually download. Notarize first if you are shipping it.
dist: bundle
	rm -f "build/$(APP_NAME).zip"
	/usr/bin/ditto -c -k --keepParent "$(APP_BUNDLE)" "build/$(APP_NAME).zip"
	@echo ""
	@echo "Wrote build/$(APP_NAME).zip"
	@codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep -q 'Signature=adhoc' \
	  && echo "WARNING: ad-hoc signed - Gatekeeper will block this on other Macs." \
	  || echo "Signed for distribution. Run 'make notarize' before publishing."

clean:
	rm -rf .build build

dry-run:
	swift run -c release claude-switcher --dry-run
