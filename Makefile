.PHONY: help app run test release clean

help:
	@echo "make run                       build and launch ColimaDock.app"
	@echo "make release VERSION=x.y.z     signed + notarized GitHub release (needs a CHANGELOG entry)"
	@echo ""
	@echo "also: make test (debug and release), make app (build only), make clean"

# Release too: the shipped app is a release build, and a release-only miscompile
# once rejected every remote host while the debug tests passed.
test:
	swift test
	swift test -c release -Xswiftc -enable-testing

app: test
	./build-app.sh

run: app
	-pkill -x ColimaDock
	open ColimaDock.app

release: test
	Scripts/release.sh "$(VERSION)"

clean:
	rm -rf .build ColimaDock.app dist
