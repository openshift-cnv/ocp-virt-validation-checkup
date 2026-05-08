.PHONY: build
build: test
	go build -o bin/ ./...

.PHONY: test
test:
	go test -count=1 ./...

.PHONY: ci-validate
ci-validate:
	@bash ci/run-ci-validation.sh

.PHONY: ci-validate-disconnected
ci-validate-disconnected:
	@bash ci/run-ci-validation-disconnected.sh
