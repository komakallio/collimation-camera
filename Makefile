.PHONY: test run cli sdk app lint

test:
	swift run core-tests

run:
	swift run CollimationApp

cli:
	swift run capture-cli --list
	swift run capture-cli --simulator --output frame.tif

sdk:
	bash scripts/fetch-sdk.sh

app:
	bash scripts/package-app.sh

lint:
	bash scripts/check-core-imports.sh
