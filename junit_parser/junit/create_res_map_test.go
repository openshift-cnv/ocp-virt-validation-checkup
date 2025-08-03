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

func TestNewResultMapSkipsLostAndFoundDirectory(t *testing.T) {
	validJunitContent := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite tests="1" failures="0" time="0.001" name="test.suite">
    <testcase classname="test.class" name="test.name" time="0.001"></testcase>
</testsuite>`

	dir := generateResDir(t, map[string]string{
		"sig1": validJunitContent,
		"sig2": validJunitContent,
	})

	// Create a lost+found directory (without junit file)
	lostFoundPath := path.Join(dir, "lost+found")
	err := os.Mkdir(lostFoundPath, 0755)
	if err != nil {
		t.Fatalf("failed to create lost+found directory: %v", err)
	}

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should only have 2 results (sig1 and sig2), lost+found should be skipped
	if len(result) != 2 {
		t.Errorf("expected 2 results, got %d", len(result))
	}

	// Verify that lost+found is not in the results
	if _, exists := result["lost+found"]; exists {
		t.Error("lost+found directory should have been skipped but was found in results")
	}

	// Verify that the valid directories are present
	if _, exists := result["sig1"]; !exists {
		t.Error("sig1 should be present in results but was not found")
	}
	if _, exists := result["sig2"]; !exists {
		t.Error("sig2 should be present in results but was not found")
	}
}
