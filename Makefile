APP = build/NitroControl.app

.PHONY: all kext swift app test install uninstall clean

all: kext app

kext:
	sh kext/build.sh

swift:
	swift build -c release

app: swift
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/NitroControl $(APP)/Contents/MacOS/
	cp Resources/App-Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign -f -s - $(APP)

# Read-only: encoder self-check, then the live sensor test (needs the kext loaded).
test: swift
	.build/release/nitroctl selftest
	.build/release/nitroctl sensors

# Builds as you, installs as root (asks for your password).
install: all
	sudo sh scripts/install.sh

uninstall:
	sudo sh scripts/install.sh --uninstall

clean:
	rm -rf build .build
