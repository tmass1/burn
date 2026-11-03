.PHONY: build run install package release clean deploy-check deploy deploy-staging

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

# The site. The only way to deploy it: checks that nothing live would be lost first. docs/deploying.md explains it.
deploy-check:
	scripts/deploy_site.py --check

deploy:
	scripts/deploy_site.py

deploy-staging:
	scripts/deploy_site.py --staging

clean:
	rm -rf .build build
