APP  := micwatch.app
DEST := /Applications

.PHONY: build install identity selftest clean

## build the signed app bundle
build:
	@./build.sh

## replace the copy in /Applications and relaunch it
install: build
	@pkill -f '$(DEST)/$(APP)' || true
	@rm -rf '$(DEST)/$(APP)'
	@cp -R '$(APP)' '$(DEST)/'
	@codesign --verify --deep --strict '$(DEST)/$(APP)'
	@open '$(DEST)/$(APP)'
	@echo "installed and running from $(DEST)/$(APP)"

## one-time: create the local code signing identity
identity:
	@./build.sh --create-identity

## opens the mic and asserts the listener path notices
selftest: build
	@'$(APP)/Contents/MacOS/micwatch' --selftest

clean:
	@rm -rf '$(APP)' .mcache
	@echo "cleaned"
