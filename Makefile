.PHONY: test test-app test-python lint lint-app lint-python format

RUFF = uvx ruff@0.15.0
# Warnings are errors, and data-race checks are on, without Swift 6's run-time checks.
SWIFT_FLAGS = -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
SWIFT_SOURCES = Sources Tests Package.swift CameraExtension

test: test-app test-python

test-app:
	cd mac && ./fetch-onnxruntime.sh
	cd mac && swift build --build-tests $(SWIFT_FLAGS)
	cd mac && swift test --skip-build $(SWIFT_FLAGS)

# The tests need only numpy, not MediaPipe or the macOS-only packages the scripts use.
test-python:
	uv run --no-project --python 3.12 --with "numpy>=2,<3" --with pytest pytest -q tests

lint: lint-app lint-python

lint-app:
	cd mac && swift format lint --strict --recursive $(SWIFT_SOURCES)

lint-python:
	$(RUFF) check
	$(RUFF) format --check
	uv lock --check

format:
	cd mac && swift format format --in-place --recursive $(SWIFT_SOURCES)
	$(RUFF) check --fix
	$(RUFF) format
