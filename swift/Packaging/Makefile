# Makefile for Tacet — build, package, sign, verify, clean, test.
# Rules use tabs (this file is written with tab-indented recipe lines).

PKG_DIR := Packaging
APP     := $(PKG_DIR)/Tacet.app

.PHONY: build app sign verify clean test

## build: compile the release binary
build:
	swift build -c release

## app: run the packaging script (build release + assemble + sign Tacet.app)
app:
	./$(PKG_DIR)/build-app.sh

## sign: re-sign the assembled bundle (ad-hoc unless TACET_SIGN_IDENTITY is set)
sign:
	codesign --force --deep --sign "$${TACET_SIGN_IDENTITY:--}" \
		--options runtime \
		--entitlements $(PKG_DIR)/entitlements.plist \
		$(APP)

## verify: codesign verification of the bundle
verify:
	codesign --verify --deep --strict --verbose=2 $(APP)

## clean: remove build products and the assembled bundle
clean:
	rm -rf .build $(APP)

## test: run the test suite
test:
	swift test
