.PHONY: build
build: test
	go build -o bin/ .

.PHONY: test
test:
	go test ./...