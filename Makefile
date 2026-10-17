.DEFAULT_GOAL := run

AVD ?= Medium_Phone
API_BASE_URL ?= http://10.0.2.2:8000/api/v1
FLUTTER ?= flutter

.PHONY: run
run: ## Start the named Android emulator and run the app.
	@AVD="$(AVD)" API_BASE_URL="$(API_BASE_URL)" FLUTTER="$(FLUTTER)" bash scripts/run-emulator.sh
