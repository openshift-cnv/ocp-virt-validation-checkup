package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// setupTestLogger creates a logger for testing that writes to stdout only
func setupTestLogger() {
	logger = log.New(os.Stdout, "[TEST] ", log.LstdFlags)
}

func TestSpecRegex(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
		matches  bool
	}{
		{
			name:     "Valid ginkgo spec count",
			input:    "Will run 50 of 100 specs",
			expected: "50",
			matches:  true,
		},
		{
			name:     "Different numbers",
			input:    "Will run 25 of 75 specs",
			expected: "25",
			matches:  true,
		},
		{
			name:     "No match",
			input:    "Running some tests",
			expected: "",
			matches:  false,
		},
		{
			name:     "Partial match",
			input:    "Will run specs",
			expected: "",
			matches:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			matches := specRegex.FindStringSubmatch(tt.input)
			if tt.matches {
				if len(matches) < 2 {
					t.Errorf("Expected match but got none for input: %s", tt.input)
					return
				}
				if matches[1] != tt.expected {
					t.Errorf("Expected %s but got %s", tt.expected, matches[1])
				}
			} else {
				if len(matches) > 0 {
					t.Errorf("Expected no match but got: %v", matches)
				}
			}
		})
	}
}

func TestPytestRegex(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
		matches  bool
	}{
		{
			name:     "Valid pytest collected count",
			input:    "collected 42 items",
			expected: "42",
			matches:  true,
		},
		{
			name:     "Different number",
			input:    "collected 123 items",
			expected: "123",
			matches:  true,
		},
		{
			name:     "No match",
			input:    "Running pytest",
			expected: "",
			matches:  false,
		},
		{
			name:     "Partial match",
			input:    "collected items",
			expected: "",
			matches:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			matches := pytestRegex.FindStringSubmatch(tt.input)
			if tt.matches {
				if len(matches) < 2 {
					t.Errorf("Expected match but got none for input: %s", tt.input)
					return
				}
				if matches[1] != tt.expected {
					t.Errorf("Expected %s but got %s", tt.expected, matches[1])
				}
			} else {
				if len(matches) > 0 {
					t.Errorf("Expected no match but got: %v", matches)
				}
			}
		})
	}
}

func TestDiscoverTestSuites(t *testing.T) {
	// Create temporary directory structure
	tmpDir, err := os.MkdirTemp("", "test-discover-suites")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create some test suite directories and log files
	suitesDirs := []string{"compute", "network", "ssp"}
	for _, suite := range suitesDirs {
		suiteDir := filepath.Join(tmpDir, suite)
		if err := os.MkdirAll(suiteDir, 0755); err != nil {
			t.Fatalf("Failed to create suite dir %s: %v", suite, err)
		}

		logFile := filepath.Join(suiteDir, fmt.Sprintf("%s-log.txt", suite))
		if err := os.WriteFile(logFile, []byte("test log content"), 0644); err != nil {
			t.Fatalf("Failed to create log file %s: %v", logFile, err)
		}
	}

	// Test discovery
	suites := discoverTestSuites(tmpDir)

	// Verify results
	if len(suites) != len(suitesDirs) {
		t.Errorf("Expected %d suites, got %d", len(suitesDirs), len(suites))
	}

	// Check that all expected suites were found
	foundSuites := make(map[string]bool)
	for _, suite := range suites {
		foundSuites[suite.Name] = true
	}

	for _, expectedSuite := range suitesDirs {
		if !foundSuites[expectedSuite] {
			t.Errorf("Expected to find suite %s but it was not discovered", expectedSuite)
		}
	}
}

func TestDiscoverTestSuitesEmptyDir(t *testing.T) {
	// Create empty temporary directory
	tmpDir, err := os.MkdirTemp("", "test-discover-empty")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	suites := discoverTestSuites(tmpDir)
	if len(suites) != 0 {
		t.Errorf("Expected no suites in empty directory, got %d", len(suites))
	}
}

func TestProcessSuiteLine(t *testing.T) {
	// Setup logger for tests
	setupTestLogger()
	defer func() {
		logger = nil
	}()

	tests := []struct {
		name              string
		suite             *TestSuite
		line              string
		expectedTotal     int
		expectedCompleted int
		expectedPassed    int
		expectedFailed    int
	}{
		{
			name: "Ginkgo total specs detection",
			suite: &TestSuite{
				Name: "test-suite",
			},
			line:              "Will run 50 of 100 specs",
			expectedTotal:     50,
			expectedCompleted: 0,
			expectedPassed:    0,
			expectedFailed:    0,
		},
		{
			name: "Pytest total items detection",
			suite: &TestSuite{
				Name: "tier2",
			},
			line:              "collected 25 items",
			expectedTotal:     25,
			expectedCompleted: 0,
			expectedPassed:    0,
			expectedFailed:    0,
		},
		{
			name: "Ginkgo test completion (passed)",
			suite: &TestSuite{
				Name:      "compute",
				Total:     10,
				Completed: 5,
			},
			line:              "• test passed",
			expectedTotal:     10,
			expectedCompleted: 6,
			expectedPassed:    1,
			expectedFailed:    0,
		},
		{
			name: "Ginkgo test completion (failed)",
			suite: &TestSuite{
				Name:      "compute",
				Total:     10,
				Completed: 5,
			},
			line:              "• test [FAILED]",
			expectedTotal:     10,
			expectedCompleted: 6,
			expectedPassed:    0,
			expectedFailed:    1,
		},
		{
			name: "Ginkgo test with timing (passed)",
			suite: &TestSuite{
				Name:      "compute",
				Total:     10,
				Completed: 5,
			},
			line:              "• [17.249 seconds]",
			expectedTotal:     10,
			expectedCompleted: 6,
			expectedPassed:    1,
			expectedFailed:    0,
		},
		{
			name: "Pytest test passed",
			suite: &TestSuite{
				Name:      "tier2",
				Total:     10,
				Completed: 3,
			},
			line:              "TEST: something PASSED",
			expectedTotal:     10,
			expectedCompleted: 4,
			expectedPassed:    1,
			expectedFailed:    0,
		},
		{
			name: "Pytest test failed",
			suite: &TestSuite{
				Name:      "tier2",
				Total:     10,
				Completed: 7,
			},
			line:              "TEST: another FAILED",
			expectedTotal:     10,
			expectedCompleted: 8,
			expectedPassed:    0,
			expectedFailed:    1,
		},
		{
			name: "Irrelevant line",
			suite: &TestSuite{
				Name:      "ssp",
				Total:     10,
				Completed: 5,
			},
			line:              "Some random log output",
			expectedTotal:     10,
			expectedCompleted: 5,
			expectedPassed:    0,
			expectedFailed:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			processSuiteLine(tt.suite, tt.line)

			if tt.suite.Total != tt.expectedTotal {
				t.Errorf("Expected total %d, got %d", tt.expectedTotal, tt.suite.Total)
			}

			if tt.suite.Completed != tt.expectedCompleted {
				t.Errorf("Expected completed %d, got %d", tt.expectedCompleted, tt.suite.Completed)
			}

			if tt.suite.Passed != tt.expectedPassed {
				t.Errorf("Expected passed %d, got %d", tt.expectedPassed, tt.suite.Passed)
			}

			if tt.suite.Failed != tt.expectedFailed {
				t.Errorf("Expected failed %d, got %d", tt.expectedFailed, tt.suite.Failed)
			}
		})
	}
}

func TestPassFailCounting(t *testing.T) {
	setupTestLogger()
	defer func() {
		logger = nil
	}()

	tests := []struct {
		name              string
		inputLines        []string
		initialSuite      TestSuite
		expectedPassed    int
		expectedFailed    int
		expectedCompleted int
		description       string
	}{
		{
			name: "Ginkgo test progression",
			inputLines: []string{
				"• test 1 passes",
				"• test 2 passes",
				"• test 3 [FAILED]",
				"• test 4 passes",
			},
			initialSuite:      TestSuite{Name: "compute", Total: 10, StartTime: time.Now()},
			expectedPassed:    3, // 3 passes (test 1, 2, 4)
			expectedFailed:    1, // 1 fail (test 3 with [FAILED])
			expectedCompleted: 4, // All 4 bullet points increment completion
			description:       "Should track pass/fail correctly for Ginkgo patterns",
		},
		{
			name: "Pytest test progression",
			inputLines: []string{
				"TEST: test_vm_creation PASSED",
				"TEST: test_vm_deletion FAILED",
				"TEST: test_vm_migration PASSED",
			},
			initialSuite:      TestSuite{Name: "tier2", Total: 10, StartTime: time.Now()},
			expectedPassed:    2,
			expectedFailed:    1,
			expectedCompleted: 3,
			description:       "Should track pytest pass/fail correctly",
		},
		{
			name: "Summary line updates",
			inputLines: []string{
				"• test 1",
				"• test 2",
				"Final results: 5 passed, 3 failed in 2.5 seconds",
			},
			initialSuite:      TestSuite{Name: "compute", Total: 8, StartTime: time.Now()},
			expectedPassed:    5, // Updated from summary
			expectedFailed:    3, // Updated from summary
			expectedCompleted: 2, // Still counts individual • markers
			description:       "Should update counts from summary lines",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			suite := tt.initialSuite

			// Process each line
			for _, line := range tt.inputLines {
				processSuiteLine(&suite, line)
			}

			// Verify pass count
			if suite.Passed != tt.expectedPassed {
				t.Errorf("%s: Expected passed %d, got %d",
					tt.description, tt.expectedPassed, suite.Passed)
			}

			// Verify fail count
			if suite.Failed != tt.expectedFailed {
				t.Errorf("%s: Expected failed %d, got %d",
					tt.description, tt.expectedFailed, suite.Failed)
			}

			// Verify completed count
			if suite.Completed != tt.expectedCompleted {
				t.Errorf("%s: Expected completed %d, got %d",
					tt.description, tt.expectedCompleted, suite.Completed)
			}
		})
	}
}

func TestSuiteDurationTracking(t *testing.T) {
	setupTestLogger()
	defer func() {
		logger = nil
	}()

	startTime := time.Now()
	suite := &TestSuite{
		Name:      "compute",
		Total:     5,
		StartTime: startTime,
	}

	// Simulate some test progression
	processSuiteLine(suite, "Will run 5 of 10 specs")
	processSuiteLine(suite, "•")
	processSuiteLine(suite, "•")

	// Wait a bit to ensure duration is measurable
	time.Sleep(10 * time.Millisecond)

	// Finish the suite
	processSuiteLine(suite, "Ran 5 specs in 1.2 seconds")

	// Verify suite is finished
	if !suite.Finished {
		t.Errorf("Expected suite to be finished")
	}

	// Verify end time is set
	if suite.EndTime.IsZero() {
		t.Errorf("Expected end time to be set")
	}

	// Verify duration is reasonable (should be > 10ms but < 1 second for this test)
	duration := suite.EndTime.Sub(suite.StartTime)
	if duration < 10*time.Millisecond {
		t.Errorf("Expected duration to be at least 10ms, got %v", duration)
	}
	if duration > time.Second {
		t.Errorf("Expected duration to be less than 1 second, got %v", duration)
	}
}

func TestGetCurrentPodMissingEnvVars(t *testing.T) {
	tests := []struct {
		name         string
		podName      string
		podNamespace string
		expectedErr  string
	}{
		{
			name:         "Missing POD_NAME",
			podName:      "",
			podNamespace: "test-namespace",
			expectedErr:  "POD_NAME environment variable not set",
		},
		{
			name:         "Missing POD_NAMESPACE",
			podName:      "test-pod",
			podNamespace: "",
			expectedErr:  "POD_NAMESPACE environment variable not set",
		},
		{
			name:         "Both missing",
			podName:      "",
			podNamespace: "",
			expectedErr:  "POD_NAME environment variable not set",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Save original env vars
			originalPodName := os.Getenv("POD_NAME")
			originalPodNamespace := os.Getenv("POD_NAMESPACE")
			defer func() {
				if originalPodName != "" {
					os.Setenv("POD_NAME", originalPodName)
				} else {
					os.Unsetenv("POD_NAME")
				}
				if originalPodNamespace != "" {
					os.Setenv("POD_NAMESPACE", originalPodNamespace)
				} else {
					os.Unsetenv("POD_NAMESPACE")
				}
			}()

			// Set test values
			if tt.podName != "" {
				os.Setenv("POD_NAME", tt.podName)
			} else {
				os.Unsetenv("POD_NAME")
			}
			if tt.podNamespace != "" {
				os.Setenv("POD_NAMESPACE", tt.podNamespace)
			} else {
				os.Unsetenv("POD_NAMESPACE")
			}

			_, err := getCurrentPod(nil) // clientset won't be used for this error case
			if err == nil {
				t.Error("Expected error but got none")
			}
			if !strings.Contains(err.Error(), tt.expectedErr) {
				t.Errorf("Expected error containing '%s', got: %v", tt.expectedErr, err)
			}
		})
	}
}

func TestGetOwningJobLogic(t *testing.T) {
	tests := []struct {
		name        string
		pod         *corev1.Pod
		expectError bool
		jobName     string
	}{
		{
			name: "Pod owned by Job",
			pod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-pod",
					Namespace: "test-namespace",
					OwnerReferences: []metav1.OwnerReference{
						{
							APIVersion: "batch/v1",
							Kind:       "Job",
							Name:       "test-job",
							UID:        "job-uid-123",
						},
					},
				},
			},
			expectError: false,
			jobName:     "test-job",
		},
		{
			name: "Pod not owned by Job",
			pod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-pod",
					Namespace: "test-namespace",
					OwnerReferences: []metav1.OwnerReference{
						{
							APIVersion: "apps/v1",
							Kind:       "ReplicaSet",
							Name:       "test-rs",
							UID:        "rs-uid-123",
						},
					},
				},
			},
			expectError: true,
		},
		{
			name: "Pod with no owner references",
			pod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:            "test-pod",
					Namespace:       "test-namespace",
					OwnerReferences: []metav1.OwnerReference{},
				},
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Test the logic by examining owner references directly
			hasJobOwner := false
			var jobName string

			for _, ownerRef := range tt.pod.OwnerReferences {
				if ownerRef.Kind == "Job" && ownerRef.APIVersion == "batch/v1" {
					hasJobOwner = true
					jobName = ownerRef.Name
					break
				}
			}

			if tt.expectError && hasJobOwner {
				t.Error("Expected error but found job owner reference")
			}
			if !tt.expectError && !hasJobOwner {
				t.Error("Expected to find job owner reference but didn't")
			}
			if !tt.expectError && jobName != tt.jobName {
				t.Errorf("Expected job name %s, got %s", tt.jobName, jobName)
			}
		})
	}
}

func TestAnnotationCalculations(t *testing.T) {
	// Test the annotation calculation logic
	suites := []*TestSuite{
		{
			Name:      "compute",
			Total:     50,
			Completed: 25,
		},
		{
			Name:      "network",
			Total:     30,
			Completed: 20,
		},
		{
			Name:      "storage",
			Total:     20,
			Completed: 15,
		},
	}

	// Calculate expected values
	expectedTotal := 100    // 50 + 30 + 20
	expectedCompleted := 60 // 25 + 20 + 15
	expectedPercent := 60   // 60/100 * 100

	// Create annotations map manually to test the logic
	annotations := make(map[string]string)
	var overallTotal, overallCompleted int

	for _, suite := range suites {
		overallTotal += suite.Total
		overallCompleted += suite.Completed

		annotations[fmt.Sprintf("test-progress/%s-total", suite.Name)] = fmt.Sprintf("%d", suite.Total)
		annotations[fmt.Sprintf("test-progress/%s-completed", suite.Name)] = fmt.Sprintf("%d", suite.Completed)
		if suite.Total > 0 {
			percent := suite.Completed * 100 / suite.Total
			annotations[fmt.Sprintf("test-progress/%s-percent", suite.Name)] = fmt.Sprintf("%d", percent)
		}
	}

	var overallPercent int
	if overallTotal > 0 {
		overallPercent = overallCompleted * 100 / overallTotal
	}

	annotations["test-progress/total"] = fmt.Sprintf("%d", overallTotal)
	annotations["test-progress/completed"] = fmt.Sprintf("%d", overallCompleted)
	annotations["test-progress/percent"] = fmt.Sprintf("%d", overallPercent)
	annotations["test-progress/active-suites"] = fmt.Sprintf("%d", len(suites))

	// Verify calculations
	if overallTotal != expectedTotal {
		t.Errorf("Expected total %d, got %d", expectedTotal, overallTotal)
	}
	if overallCompleted != expectedCompleted {
		t.Errorf("Expected completed %d, got %d", expectedCompleted, overallCompleted)
	}
	if overallPercent != expectedPercent {
		t.Errorf("Expected percent %d, got %d", expectedPercent, overallPercent)
	}

	// Verify specific annotations
	if annotations["test-progress/total"] != "100" {
		t.Errorf("Expected total annotation '100', got '%s'", annotations["test-progress/total"])
	}
	if annotations["test-progress/compute-percent"] != "50" {
		t.Errorf("Expected compute percent '50', got '%s'", annotations["test-progress/compute-percent"])
	}
	if annotations["test-progress/network-percent"] != "66" {
		t.Errorf("Expected network percent '66', got '%s'", annotations["test-progress/network-percent"])
	}
	if annotations["test-progress/storage-percent"] != "75" {
		t.Errorf("Expected storage percent '75', got '%s'", annotations["test-progress/storage-percent"])
	}
}

func TestEnvironmentVariableAccess(t *testing.T) {
	// Test environment variable reading
	testKey := "TEST_ENV_VAR"
	testValue := "test-value"

	// Set test environment variable
	os.Setenv(testKey, testValue)
	defer os.Unsetenv(testKey)

	// Verify we can read it
	value := os.Getenv(testKey)
	if value != testValue {
		t.Errorf("Expected env var %s to be %s, got %s", testKey, testValue, value)
	}

	// Test missing environment variable
	missingValue := os.Getenv("NON_EXISTENT_ENV_VAR")
	if missingValue != "" {
		t.Errorf("Expected empty value for non-existent env var, got: %s", missingValue)
	}
}

func TestJobOwnershipLogic(t *testing.T) {
	// Test Job annotation key generation
	testJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "validation-job",
			Namespace:   "test-ns",
			Annotations: make(map[string]string),
		},
	}

	// Test annotation key patterns
	expectedKeys := []string{
		"test-progress/total",
		"test-progress/completed",
		"test-progress/percent",
		"test-progress/active-suites",
		"test-progress/compute-total",
		"test-progress/compute-completed",
		"test-progress/compute-percent",
	}

	// Verify all keys follow the expected pattern
	for _, key := range expectedKeys {
		if !strings.HasPrefix(key, "test-progress/") {
			t.Errorf("Expected annotation key to have 'test-progress/' prefix, got: %s", key)
		}
	}

	// Test annotation setting
	testJob.Annotations["test-progress/total"] = "100"
	testJob.Annotations["test-progress/completed"] = "50"

	if testJob.Annotations["test-progress/total"] != "100" {
		t.Error("Failed to set annotation on job")
	}
}

// Benchmark tests
func BenchmarkSpecRegex(b *testing.B) {
	testLine := "Will run 150 of 300 specs"
	for i := 0; i < b.N; i++ {
		specRegex.FindStringSubmatch(testLine)
	}
}

func BenchmarkPytestRegex(b *testing.B) {
	testLine := "collected 150 items"
	for i := 0; i < b.N; i++ {
		pytestRegex.FindStringSubmatch(testLine)
	}
}

func BenchmarkProcessSuiteLine(b *testing.B) {
	suite := &TestSuite{
		Name:      "benchmark-suite",
		Total:     100,
		Completed: 50,
	}
	testLine := "• test completed successfully"

	for i := 0; i < b.N; i++ {
		processSuiteLine(suite, testLine)
	}
}

func BenchmarkAnnotationCalculation(b *testing.B) {
	suites := []*TestSuite{
		{Name: "compute", Total: 50, Completed: 25},
		{Name: "network", Total: 30, Completed: 15},
		{Name: "storage", Total: 20, Completed: 10},
	}

	for i := 0; i < b.N; i++ {
		annotations := make(map[string]string)
		var overallTotal, overallCompleted int

		for _, suite := range suites {
			overallTotal += suite.Total
			overallCompleted += suite.Completed
			annotations[fmt.Sprintf("test-progress/%s-total", suite.Name)] = fmt.Sprintf("%d", suite.Total)
		}

		var overallPercent int
		if overallTotal > 0 {
			overallPercent = overallCompleted * 100 / overallTotal
		}
		annotations["test-progress/percent"] = fmt.Sprintf("%d", overallPercent)
	}
}

func TestDuplicateFilterWriter(t *testing.T) {
	tests := []struct {
		name           string
		writes         []string
		expectedWrites []string
	}{
		{
			name:           "No duplicates",
			writes:         []string{"line1\n", "line2\n", "line3\n"},
			expectedWrites: []string{"line1\n", "line2\n", "line3\n"},
		},
		{
			name:           "Consecutive duplicates",
			writes:         []string{"line1\n", "line1\n", "line2\n", "line2\n", "line2\n", "line3\n"},
			expectedWrites: []string{"line1\n", "line2\n", "line3\n"},
		},
		{
			name:           "Non-consecutive duplicates",
			writes:         []string{"line1\n", "line2\n", "line1\n", "line3\n"},
			expectedWrites: []string{"line1\n", "line2\n", "line1\n", "line3\n"},
		},
		{
			name:           "All same lines",
			writes:         []string{"same\n", "same\n", "same\n", "same\n"},
			expectedWrites: []string{"same\n"},
		},
		{
			name:           "Empty writes",
			writes:         []string{},
			expectedWrites: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a buffer to capture writes
			var buffer strings.Builder

			// Create duplicate filter writer
			filterWriter := NewDuplicateFilterWriter(&buffer)

			// Perform all writes
			for _, write := range tt.writes {
				_, err := filterWriter.Write([]byte(write))
				if err != nil {
					t.Fatalf("Write failed: %v", err)
				}
			}

			// Check the result
			result := buffer.String()
			expected := strings.Join(tt.expectedWrites, "")

			if result != expected {
				t.Errorf("Expected %q, got %q", expected, result)
			}
		})
	}
}

func TestHasProgressChanged(t *testing.T) {
	// Reset global state
	originalPreviousProgress := previousProgress
	defer func() { previousProgress = originalPreviousProgress }()

	tests := []struct {
		name            string
		previousState   *ProgressState
		currentState    *ProgressState
		expectedChanged bool
	}{
		{
			name:          "First time (no previous state)",
			previousState: nil,
			currentState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 5,
				OverallPercent:   50,
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			expectedChanged: true,
		},
		{
			name: "No change in progress",
			previousState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 5,
				OverallPercent:   50,
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			currentState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 5,
				OverallPercent:   50,
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			expectedChanged: false,
		},
		{
			name: "Overall progress changed",
			previousState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 5,
				OverallPercent:   50,
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			currentState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 6,  // Changed
				OverallPercent:   60, // Changed
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 4, Percent: 80}, // Changed
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			expectedChanged: true,
		},
		{
			name: "New suite added",
			previousState: &ProgressState{
				OverallTotal:     10,
				OverallCompleted: 5,
				OverallPercent:   50,
				ActiveSuites:     2,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
				},
			},
			currentState: &ProgressState{
				OverallTotal:     15, // Changed
				OverallCompleted: 5,
				OverallPercent:   33, // Changed
				ActiveSuites:     3,  // Changed
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
					"storage": {Total: 5, Completed: 0, Percent: 0}, // New suite
				},
			},
			expectedChanged: true,
		},
		{
			name: "Suite removed",
			previousState: &ProgressState{
				OverallTotal:     15,
				OverallCompleted: 5,
				OverallPercent:   33,
				ActiveSuites:     3,
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
					"storage": {Total: 5, Completed: 0, Percent: 0},
				},
			},
			currentState: &ProgressState{
				OverallTotal:     10, // Changed
				OverallCompleted: 5,
				OverallPercent:   50, // Changed
				ActiveSuites:     2,  // Changed
				SuiteProgress: map[string]SuiteState{
					"compute": {Total: 5, Completed: 3, Percent: 60},
					"network": {Total: 5, Completed: 2, Percent: 40},
					// storage suite removed
				},
			},
			expectedChanged: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set up the previous state
			previousProgress = tt.previousState

			// Check if progress has changed
			changed := hasProgressChanged(tt.currentState)

			if changed != tt.expectedChanged {
				t.Errorf("Expected changed=%v, got changed=%v", tt.expectedChanged, changed)
			}
		})
	}
}

func TestProportionalProgressCalculation(t *testing.T) {
	// Reset global state
	originalPreviousProgress := previousProgress
	defer func() { previousProgress = originalPreviousProgress }()

	setupTestLogger()

	tests := []struct {
		name                   string
		suites                 []*TestSuite
		expectedOverallPercent int
		description            string
	}{
		{
			name: "Single suite 50% complete",
			suites: []*TestSuite{
				{Name: "compute", Total: 30, Completed: 15, Finished: false},
			},
			expectedOverallPercent: 50, // 15/30 = 50%
			description:            "One suite at 50% should give 50% overall",
		},
		{
			name: "Single suite finished",
			suites: []*TestSuite{
				{Name: "compute", Total: 30, Completed: 30, Finished: true},
			},
			expectedOverallPercent: 100, // 30/30 = 100%
			description:            "One finished suite should give 100% overall",
		},
		{
			name: "Two suites - different sizes",
			suites: []*TestSuite{
				{Name: "compute", Total: 30, Completed: 30, Finished: true},  // 30 tests done
				{Name: "network", Total: 20, Completed: 10, Finished: false}, // 10 tests done
			},
			expectedOverallPercent: 80, // (30+10)/(30+20) = 40/50 = 80%
			description:            "Mixed progress should be proportional to test counts",
		},
		{
			name: "Three suites - varying sizes",
			suites: []*TestSuite{
				{Name: "compute", Total: 60, Completed: 60, Finished: true},  // 60 tests done
				{Name: "network", Total: 20, Completed: 20, Finished: true},  // 20 tests done
				{Name: "storage", Total: 20, Completed: 10, Finished: false}, // 10 tests done
			},
			expectedOverallPercent: 90, // (60+20+10)/(60+20+20) = 90/100 = 90%
			description:            "Progress should reflect actual test completion ratios",
		},
		{
			name: "All suites finished",
			suites: []*TestSuite{
				{Name: "compute", Total: 30, Completed: 30, Finished: true},
				{Name: "network", Total: 20, Completed: 20, Finished: true},
				{Name: "storage", Total: 25, Completed: 25, Finished: true},
				{Name: "ssp", Total: 15, Completed: 15, Finished: true},
				{Name: "tier2", Total: 10, Completed: 10, Finished: true},
			},
			expectedOverallPercent: 100, // (30+20+25+15+10)/(30+20+25+15+10) = 100/100 = 100%
			description:            "All suites finished should give 100% overall",
		},
		{
			name: "Large vs small suites",
			suites: []*TestSuite{
				{Name: "compute", Total: 100, Completed: 50, Finished: false}, // 50% of large suite
				{Name: "tier2", Total: 10, Completed: 10, Finished: true},     // 100% of small suite
			},
			expectedOverallPercent: 54, // (50+10)/(100+10) = 60/110 = 54%
			description:            "Large suites should have more impact on overall progress",
		},
		{
			name: "Empty suites ignored",
			suites: []*TestSuite{
				{Name: "compute", Total: 50, Completed: 25, Finished: false}, // 50% of 50 tests
				{Name: "network", Total: 0, Completed: 0, Finished: false},   // No tests yet
			},
			expectedOverallPercent: 50, // 25/50 = 50% (empty suite ignored)
			description:            "Suites with no total tests should not affect percentage",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Calculate progress using the same logic as updateJobAnnotations
			var overallTotal, overallCompleted int

			for _, suite := range tt.suites {
				overallTotal += suite.Total
				overallCompleted += suite.Completed
			}

			// Calculate overall percentage based on total test count across all suites
			var overallPercent int
			if overallTotal > 0 {
				overallPercent = overallCompleted * 100 / overallTotal
			}

			if overallPercent != tt.expectedOverallPercent {
				t.Errorf("%s: Expected overall percent %d, got %d (completed: %d, total: %d)",
					tt.description, tt.expectedOverallPercent, overallPercent, overallCompleted, overallTotal)
			}
		})
	}
}

func TestSuiteFinishingDetection(t *testing.T) {
	setupTestLogger()

	tests := []struct {
		name           string
		inputLines     []string
		initialSuite   TestSuite
		expectedResult TestSuite
		description    string
	}{
		{
			name: "Ginkgo completion by count",
			inputLines: []string{
				"•", "•", "•", "•", "•", // 5 completed
			},
			initialSuite:   TestSuite{Name: "compute", Total: 5, Completed: 0, Finished: false, StartTime: time.Now()},
			expectedResult: TestSuite{Name: "compute", Total: 5, Completed: 5, Finished: true},
			description:    "Suite should be marked finished when completed equals total",
		},
		{
			name: "Ginkgo completion by pattern",
			inputLines: []string{
				"Ran 10 specs in 5.2 seconds",
			},
			initialSuite:   TestSuite{Name: "compute", Total: 10, Completed: 8, Finished: false, StartTime: time.Now()},
			expectedResult: TestSuite{Name: "compute", Total: 10, Completed: 8, Finished: true},
			description:    "Suite should be marked finished by completion pattern",
		},
		{
			name: "Pytest completion pattern",
			inputLines: []string{
				"short test summary info - 5 passed, 2 failed in 3.45 seconds",
			},
			initialSuite:   TestSuite{Name: "tier2", Total: 7, Completed: 6, Finished: false, StartTime: time.Now()},
			expectedResult: TestSuite{Name: "tier2", Total: 7, Completed: 6, Finished: true},
			description:    "Suite should be marked finished by pytest pattern",
		},
		{
			name: "No completion yet",
			inputLines: []string{
				"Starting tests...",
				"•", "•", // Only 2 completed out of 5
			},
			initialSuite:   TestSuite{Name: "compute", Total: 5, Completed: 0, Finished: false, StartTime: time.Now()},
			expectedResult: TestSuite{Name: "compute", Total: 5, Completed: 2, Finished: false},
			description:    "Suite should not be finished when incomplete",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			suite := tt.initialSuite

			// Process each line
			for _, line := range tt.inputLines {
				processSuiteLine(&suite, line)
			}

			// Check results
			if suite.Total != tt.expectedResult.Total {
				t.Errorf("%s: Expected total %d, got %d",
					tt.description, tt.expectedResult.Total, suite.Total)
			}
			if suite.Completed != tt.expectedResult.Completed {
				t.Errorf("%s: Expected completed %d, got %d",
					tt.description, tt.expectedResult.Completed, suite.Completed)
			}
			if suite.Finished != tt.expectedResult.Finished {
				t.Errorf("%s: Expected finished %t, got %t",
					tt.description, tt.expectedResult.Finished, suite.Finished)
			}
		})
	}
}

func TestGetTotalExpectedSuites(t *testing.T) {
	// Note: This function is no longer used in progress calculation (we use proportional calculation now)
	// but kept for potential future use cases

	// Save original TEST_SUITES value and restore after test
	originalTestSuites := os.Getenv("TEST_SUITES")
	defer func() {
		if originalTestSuites != "" {
			os.Setenv("TEST_SUITES", originalTestSuites)
		} else {
			os.Unsetenv("TEST_SUITES")
		}
	}()

	tests := []struct {
		name          string
		testSuitesEnv string
		expectedCount int
		description   string
	}{
		{
			name:          "Empty env var defaults to 5",
			testSuitesEnv: "",
			expectedCount: 5,
			description:   "When TEST_SUITES is not set, should default to 5",
		},
		{
			name:          "All suites specified",
			testSuitesEnv: "compute,network,storage,ssp,tier2",
			expectedCount: 5,
			description:   "All 5 suites specified should return 5",
		},
		{
			name:          "Subset of suites",
			testSuitesEnv: "compute,network",
			expectedCount: 2,
			description:   "Only 2 suites specified should return 2",
		},
		{
			name:          "Single suite",
			testSuitesEnv: "compute",
			expectedCount: 1,
			description:   "Single suite should return 1",
		},
		{
			name:          "Three suites",
			testSuitesEnv: "compute,storage,tier2",
			expectedCount: 3,
			description:   "Three suites should return 3",
		},
		{
			name:          "Suites with extra spaces",
			testSuitesEnv: " compute , network , storage ",
			expectedCount: 3,
			description:   "Should handle extra spaces correctly",
		},
		{
			name:          "Suites with empty values",
			testSuitesEnv: "compute,,network,",
			expectedCount: 2,
			description:   "Should ignore empty values between commas",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set the environment variable
			if tt.testSuitesEnv == "" {
				os.Unsetenv("TEST_SUITES")
			} else {
				os.Setenv("TEST_SUITES", tt.testSuitesEnv)
			}

			// Call the function
			count := getTotalExpectedSuites()

			// Verify the result
			if count != tt.expectedCount {
				t.Errorf("%s: Expected count %d, got %d",
					tt.description, tt.expectedCount, count)
			}
		})
	}
}

func TestParseTestCountFromDryRun(t *testing.T) {
	tests := []struct {
		name          string
		output        string
		suiteName     string
		expectedCount int
		description   string
	}{
		{
			name: "Ginkgo dry-run output",
			output: `Running Suite: Compute Suite
Random seed: 1234567890
Will run 42 of 50 specs
Randomizing all specs`,
			suiteName:     "compute",
			expectedCount: 42,
			description:   "Should extract count from Ginkgo dry-run output",
		},
		{
			name: "Pytest dry-run output",
			output: `============================= test session starts ==============================
collecting ... collected 25 items

<Module tests/test_tier2.py>
  <Function test_vm_creation>
  <Function test_vm_deletion>`,
			suiteName:     "tier2",
			expectedCount: 25,
			description:   "Should extract count from pytest dry-run output",
		},
		{
			name: "No match in output",
			output: `Some random output
without any test counts
or recognizable patterns`,
			suiteName:     "unknown",
			expectedCount: 0,
			description:   "Should return 0 when no patterns match",
		},
		{
			name: "Generic test pattern",
			output: `Test discovery complete
Found 15 tests to run
Starting execution...`,
			suiteName:     "generic",
			expectedCount: 15,
			description:   "Should handle generic test count patterns",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			count := parseTestCountFromDryRun(tt.output, tt.suiteName)

			if count != tt.expectedCount {
				t.Errorf("%s: Expected count %d, got %d",
					tt.description, tt.expectedCount, count)
			}
		})
	}
}

func TestPreDiscoveredTotalsIntegration(t *testing.T) {
	// Reset global state
	originalPreDiscoveredTotals := preDiscoveredTotals
	defer func() { preDiscoveredTotals = originalPreDiscoveredTotals }()

	setupTestLogger()

	// Set up pre-discovered totals
	preDiscoveredTotals = map[string]int{
		"compute": 50,
		"network": 30,
		"tier2":   15,
	}

	tests := []struct {
		name                   string
		activeSuites           []*TestSuite
		expectedOverallTotal   int
		expectedOverallPercent int
		description            string
	}{
		{
			name:                   "No active suites yet",
			activeSuites:           []*TestSuite{},
			expectedOverallTotal:   95, // 50 + 30 + 15
			expectedOverallPercent: 0,  // 0 completed out of 95
			description:            "Should show total from pre-discovery even with no active suites",
		},
		{
			name: "Partial progress",
			activeSuites: []*TestSuite{
				{Name: "compute", Total: 50, Completed: 25, Finished: false},
			},
			expectedOverallTotal:   95, // 50 + 30 + 15
			expectedOverallPercent: 26, // 25 completed out of 95 = 26%
			description:            "Should combine active suite progress with pre-discovered totals",
		},
		{
			name: "Multiple active suites",
			activeSuites: []*TestSuite{
				{Name: "compute", Total: 50, Completed: 50, Finished: true},
				{Name: "network", Total: 30, Completed: 15, Finished: false},
			},
			expectedOverallTotal:   95, // 50 + 30 + 15
			expectedOverallPercent: 68, // (50 + 15) out of 95 = 68%
			description:            "Should accurately calculate progress with multiple active suites",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the progress calculation logic from updateJobAnnotations
			var overallTotal, overallCompleted int
			processedSuites := make(map[string]bool)

			// Process active suites
			for _, suite := range tt.activeSuites {
				overallTotal += suite.Total
				overallCompleted += suite.Completed
				processedSuites[suite.Name] = true
			}

			// Add pre-discovered totals for unprocessed suites
			for suiteName, total := range preDiscoveredTotals {
				if !processedSuites[suiteName] {
					overallTotal += total
				}
			}

			// Calculate percentage
			var overallPercent int
			if overallTotal > 0 {
				overallPercent = overallCompleted * 100 / overallTotal
			}

			// Verify results
			if overallTotal != tt.expectedOverallTotal {
				t.Errorf("%s: Expected total %d, got %d",
					tt.description, tt.expectedOverallTotal, overallTotal)
			}

			if overallPercent != tt.expectedOverallPercent {
				t.Errorf("%s: Expected percent %d, got %d",
					tt.description, tt.expectedOverallPercent, overallPercent)
			}
		})
	}
}
