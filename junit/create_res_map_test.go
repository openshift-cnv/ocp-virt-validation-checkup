package junit

import (
	"os"
	"path"
	"testing"
)

func generateResDir(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for subDir, content := range files {
		subDirPath := path.Join(dir, subDir)
		err := os.Mkdir(subDirPath, 0755)
		if err != nil {
			t.Fatalf("failed to create subdirectory: %v", err)
		}

		if len(content) == 0 {
			continue
		}

		filePath := path.Join(subDirPath, junitFileName)
		err = os.WriteFile(filePath, []byte(content), 0644)
		if err != nil {
			t.Fatalf("failed to create file: %v", err)
		}
	}
	return dir
}

func TestNewResultMapWithValidFiles(t *testing.T) {
	dir := generateResDir(t, map[string]string{
		"sig1": `<testsuite name="suite1"></testsuite>`,
		"sig2": `<testsuite name="suite2"></testsuite>`,
	})

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result) != 2 {
		t.Errorf("expected 2 results, got %d", len(result))
	}

	if _, ok := result["sig1"]; !ok {
		t.Errorf("expected result for sig1")
	}

	if _, ok := result["sig2"]; !ok {
		t.Errorf("expected result for sig2")
	}
}

func TestNewResultMapWithEmptyDirectory(t *testing.T) {
	dir := generateResDir(t, nil)

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result) != 0 {
		t.Errorf("expected 0 results, got %d", len(result))
	}
}

func TestNewResultMapWithMissingJunitFiles(t *testing.T) {
	dir := generateResDir(t, map[string]string{"sig1": "", "sig2": ""})

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result) != 0 {
		t.Errorf("expected 0 results, got %d", len(result))
	}
}

func TestNewResultMapWithInvalidJunitFiles(t *testing.T) {
	dir := generateResDir(t, map[string]string{
		"sig1": `<invalid>`,
		"sig2": `<invalid>`,
	})

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result) != 0 {
		t.Errorf("expected 0 results, got %d", len(result))
	}
}
