package junit

import (
	"os"
	"path"
	"strings"
	"testing"
)

func TestSelectiveFilterWindowsExit5NotSetupFailure(t *testing.T) {
	dir := t.TempDir()
	tier2Dir := path.Join(dir, "tier2")
	if err := os.Mkdir(tier2Dir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	phase1 := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="pytest" tests="1" failures="0" errors="0" skipped="0">
  <testcase classname="tests.storage.test_a" name="test_path_ok"/>
</testsuite>`

	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(path.Join(tier2Dir, name), []byte(content), 0644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	write(junitFileName, phase1)
	write("junit.phase1.xml", phase1)
	write(".exit_code", "0\n")
	write(".exit_code_phase1", "0\n")
	// Runner normalizes selective-filter exit 5 to 0 before the parser runs.
	write(".exit_code_windows", "0\n")
	// No junit.windows.xml: focus matched path tests only.

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	suite := result["tier2"]
	if suite.SetupFailure {
		t.Fatal("normalized Windows exit 0 with empty collection must not be SetupFailure")
	}
	if suite.Tests != 1 {
		t.Fatalf("expected path-phase tests retained, got %d", suite.Tests)
	}
}

func TestNonSplitRunIgnoresMissingPhaseMarkers(t *testing.T) {
	dir := t.TempDir()
	tier2Dir := path.Join(dir, "tier2")
	if err := os.Mkdir(tier2Dir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	ok := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="pytest" tests="2" failures="0" errors="0" skipped="0">
  <testcase classname="tests.storage.test_a" name="test_a"/>
  <testcase classname="tests.storage.test_b" name="test_b"/>
</testsuite>`
	if err := os.WriteFile(path.Join(tier2Dir, junitFileName), []byte(ok), 0644); err != nil {
		t.Fatalf("write junit: %v", err)
	}
	if err := os.WriteFile(path.Join(tier2Dir, ".exit_code"), []byte("0\n"), 0644); err != nil {
		t.Fatalf("write exit: %v", err)
	}
	// No split-phase markers: simulates a non-split rerun after clearing prior artifacts.

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	suite := result["tier2"]
	if suite.SetupFailure {
		t.Fatal("non-split successful run must not be SetupFailure")
	}
	if suite.Tests != 2 {
		t.Fatalf("expected 2 tests, got %d", suite.Tests)
	}
}

func TestPhaseSetupFailureMaskedByOtherPhaseFailures(t *testing.T) {
	dir := t.TempDir()
	tier2Dir := path.Join(dir, "tier2")
	if err := os.Mkdir(tier2Dir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// Merged report has Windows test failures, but path phase was a setup failure.
	merged := `<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="1" failures="1" errors="0" skipped="0">
  <testsuite name="pytest-windows" tests="1" failures="1" errors="0" skipped="0">
    <testcase classname="tests.virt.test_win" name="test_win_fail">
      <failure>windows failed</failure>
    </testcase>
  </testsuite>
</testsuites>`
	windows := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="pytest-windows" tests="1" failures="1" errors="0" skipped="0">
  <testcase classname="tests.virt.test_win" name="test_win_fail">
    <failure>windows failed</failure>
  </testcase>
</testsuite>`

	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(path.Join(tier2Dir, name), []byte(content), 0644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	write(junitFileName, merged)
	write("junit.windows.xml", windows)
	write(".exit_code", "1\n")
	write(".exit_code_phase1", "1\n")
	write(".exit_code_windows", "1\n")
	// No junit.phase1.xml → path phase setup failure

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	suite, ok := result["tier2"]
	if !ok {
		t.Fatal("expected tier2 suite")
	}
	if !suite.SetupFailure {
		t.Fatal("expected SetupFailure when path phase exited without JUnit")
	}
	if suite.Failures != 1 {
		t.Fatalf("expected merged Windows failure to remain visible, got failures=%d", suite.Failures)
	}
}

func TestPhaseSetupFailureAbsentWhenPhasesReportTestFailures(t *testing.T) {
	dir := t.TempDir()
	tier2Dir := path.Join(dir, "tier2")
	if err := os.Mkdir(tier2Dir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	phase1 := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="pytest" tests="1" failures="1" errors="0" skipped="0">
  <testcase classname="tests.storage.test_a" name="test_path_fail">
    <failure>path failed</failure>
  </testcase>
</testsuite>`
	windows := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="pytest-windows" tests="1" failures="0" errors="0" skipped="0">
  <testcase classname="tests.virt.test_win" name="test_win_ok"/>
</testsuite>`
	merged := `<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="2" failures="1" errors="0" skipped="0">
  <testsuite name="pytest" tests="1" failures="1" errors="0" skipped="0">
    <testcase classname="tests.storage.test_a" name="test_path_fail">
      <failure>path failed</failure>
    </testcase>
  </testsuite>
  <testsuite name="pytest-windows" tests="1" failures="0" errors="0" skipped="0">
    <testcase classname="tests.virt.test_win" name="test_win_ok"/>
  </testsuite>
</testsuites>`

	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(path.Join(tier2Dir, name), []byte(content), 0644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	write(junitFileName, merged)
	write("junit.phase1.xml", phase1)
	write("junit.windows.xml", windows)
	write(".exit_code", "1\n")
	write(".exit_code_phase1", "1\n")
	write(".exit_code_windows", "0\n")

	result, err := NewResultMap(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	suite := result["tier2"]
	if suite.SetupFailure {
		t.Fatal("did not expect SetupFailure when path phase reported test failures")
	}
}

func TestReadTestSuiteAggregatesMultipleSuites(t *testing.T) {
	xmlContent := `<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="3" failures="1" errors="0" skipped="0">
  <testsuite name="pytest" tests="1" failures="0" errors="0" skipped="0" time="0.100">
    <testcase classname="tests.storage.test_a" name="test_path" time="0.100"/>
  </testsuite>
  <testsuite name="pytest-windows" tests="2" failures="1" errors="0" skipped="0" time="0.200">
    <testcase classname="tests.virt.test_b" name="test_win_ok" time="0.100"/>
    <testcase classname="tests.virt.test_c" name="test_win_fail" time="0.100">
      <failure>windows failed</failure>
    </testcase>
  </testsuite>
</testsuites>`

	suite, err := readTestSuite(strings.NewReader(xmlContent))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if suite.Tests != 3 {
		t.Errorf("expected 3 tests, got %d", suite.Tests)
	}
	if suite.Failures != 1 {
		t.Errorf("expected 1 failure, got %d", suite.Failures)
	}
	if len(suite.TestCases) != 3 {
		t.Errorf("expected 3 test cases, got %d", len(suite.TestCases))
	}

	names := map[string]bool{}
	for _, tc := range suite.TestCases {
		names[tc.Name] = true
	}
	for _, want := range []string{"test_path", "test_win_ok", "test_win_fail"} {
		if !names[want] {
			t.Errorf("expected test case %q in aggregated suite", want)
		}
	}
	if !suite.TestCases[2].Failure {
		t.Errorf("expected Windows failure case to retain <failure>")
	}
}

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
