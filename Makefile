.PHONY: test run run-portable cli sdk app app-portable lint

test:
	swift run core-tests

run:
	swift run CollimationApp

run-portable:
	swift run CollimationCamera

cli:
	swift run capture-cli --list
	swift run capture-cli --simulator --output frame.tif

sdk:
	bash scripts/fetch-sdk.sh

app:
	bash scripts/package-app.sh

app-portable:
	bash scripts/package-portable-mac.sh

lint:
	bash scripts/check-core-imports.sh
