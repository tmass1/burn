.PHONY: build run install package release clean

build:
	scripts/bundle.sh --debug

run: build
	pkill -x Burn 2>/dev/null || true
	open build/Burn.app

install:
	scripts/bundle.sh --install

# A signed, notarized build/Burn.dmg (and Burn.zip) to hand to someone, without publishing anything.
package:
	scripts/release.sh --dry-run

release:
	scripts/release.sh

clean:
	rm -rf .build build
