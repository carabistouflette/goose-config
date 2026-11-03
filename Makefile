GOOSE ?= .toolchain/goose/build/goose
BENCH_ITERATIONS ?= 1000
TESTS = config behavior toml overloads

.PHONY: setup format check test property sanitize bench
setup:
	./scripts/setup-goose.sh
format:
	$(GOOSE) format config.goose toml.goose vendor.goose examples tests bench
check:
	$(GOOSE) format --check config.goose toml.goose vendor.goose examples tests bench
	@set -e; for name in $(TESTS) property; do $(GOOSE) check tests/$$name.goose; done
	$(GOOSE) check examples/settings.goose
	$(GOOSE) check bench/bench.goose
test:
	mkdir -p .build
	@set -e; for name in $(TESTS); do \
		$(GOOSE) run tests/$$name.goose; \
		$(GOOSE) build tests/$$name.goose -o .build/$$name; ./.build/$$name; \
		$(GOOSE) build tests/$$name.goose --debug --no-bce -o .build/$$name-debug; ./.build/$$name-debug; \
	done
	$(GOOSE) run examples/settings.goose
	python3 tests/ownership.py $(GOOSE)
property:
	mkdir -p .build
	$(GOOSE) build tests/property.goose -o .build/property
	$(GOOSE) build tests/property.goose --debug --no-bce -o .build/property-debug
	python3 tests/property.py .build/property .build/property-debug
sanitize:
	mkdir -p .build
	@set -e; for name in $(TESTS); do \
		$(GOOSE) build tests/$$name.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/$$name-sanitized; \
		./.build/$$name-sanitized; \
	done
	$(GOOSE) build tests/property.goose --standalone --debug --no-bce --cc ./scripts/sanitizer-cc.sh -o .build/property-sanitized
	python3 tests/property.py .build/property-sanitized
bench:
	mkdir -p .build
	$(GOOSE) build bench/bench.goose --cc gcc -O2 -o .build/bench
	./.build/bench $(BENCH_ITERATIONS)
