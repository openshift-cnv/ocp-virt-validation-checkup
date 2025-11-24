.PHONY: build
build: test
	go build -o bin/ ./...

.PHONY: test
test:
	go test -count=1 ./...

.PHONY: ci-validate
ci-validate:
	@bash ci/run-ci-validation.sh
