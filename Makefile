.PHONY: help app run release clean

help:
	@echo "make run                       build and launch ColimaDock.app"
	@echo "make release VERSION=x.y.z     signed + notarized GitHub release (needs a CHANGELOG entry)"
	@echo ""
	@echo "also: make app (build only), make clean"

app:
	./build-app.sh

run: app
	-pkill -x ColimaDock
	open ColimaDock.app

release:
	Scripts/release.sh "$(VERSION)"

clean:
	rm -rf .build ColimaDock.app dist
