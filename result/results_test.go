package result_test

import (
	"encoding/json"
	"strings"
	"testing"

	"junitparser/junit_parser/junit"
	"junitparser/result"
)

func TestCreatesResultWithValidJUnitResults(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    5,
			Failures: 1,
			Skipped:  1,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Classname: "Tests Suite", Failure: true},
				{Name: "test2", Classname: "Tests Suite"},
			},
		},
		"sig2": {
			Tests:    3,
			Failures: 0,
			Skipped:  0,
			Disabled: 0,
		},
	}

	res := result.New(junitResults)

	if len(res.SigMap) != 2 {
		t.Errorf("expected 2 sigs, got %d", len(res.SigMap))
	}

	sig1 := res.SigMap["sig1"]
	if sig1.Run != 4 {
		t.Errorf("expected 4 tests run for sig1 (5 total - 1 skipped), got %d", sig1.Run)
	}
	if sig1.Passed != 3 {
		t.Errorf("expected 3 tests passed for sig1 (4 run - 1 failed), got %d", sig1.Passed)
	}
	if sig1.Failures != 1 {
		t.Errorf("expected 1 failure for sig1, got %d", sig1.Failures)
	}
	uncategorized := sig1.FailedTests[""]
	if len(uncategorized) != 1 || uncategorized[0] != "test1" {
		t.Errorf("expected failed test 'test1' under empty category for sig1, got %v", sig1.FailedTests)
	}

	sig2 := res.SigMap["sig2"]
	if sig2.Run != 3 {
		t.Errorf("expected 3 tests run for sig2, got %d", sig2.Run)
	}
	if sig2.Passed != 3 {
		t.Errorf("expected 3 tests passed for sig2, got %d", sig2.Passed)
	}
	if sig2.Failures != 0 {
		t.Errorf("expected 0 failures for sig2, got %d", sig2.Failures)
	}
}

func TestHandlesEmptyJUnitResults(t *testing.T) {
	junitResults := map[string]junit.TestSuite{}

	res := result.New(junitResults)

	if len(res.SigMap) != 0 {
		t.Errorf("expected 0 sigs, got %d", len(res.SigMap))
	}
	if res.Summary.Run != 0 {
		t.Errorf("expected 0 total tests run, got %d", res.Summary.Run)
	}
	if res.Summary.Passed != 0 {
		t.Errorf("expected 0 total tests passed, got %d", res.Summary.Passed)
	}
	if res.Summary.Failed != 0 {
		t.Errorf("expected 0 total tests failed, got %d", res.Summary.Failed)
	}
	if res.Summary.Skipped != 0 {
		t.Errorf("expected 0 total tests skipped, got %d", res.Summary.Skipped)
	}
}

func TestExcludesSkippedFromRunCountForAnySuite(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"tier2": {
			Tests:    10,
			Failures: 1,
			Skipped:  3,
			Disabled: 0,
		},
	}

	res := result.New(junitResults)

	sig := res.SigMap["tier2"]
	if sig.Run != 7 {
		t.Errorf("expected 7 tests run (10 total - 3 skipped), got %d", sig.Run)
	}
	if sig.Passed != 6 {
		t.Errorf("expected 6 tests passed (7 run - 1 failed), got %d", sig.Passed)
	}
	if sig.Failures != 1 {
		t.Errorf("expected 1 failure, got %d", sig.Failures)
	}
}

func TestAllTestsSkippedDoesNotProduceNegativeCounts(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"tier2": {
			Tests:    0,
			Failures: 0,
			Skipped:  2,
			Disabled: 0,
		},
	}

	res := result.New(junitResults)

	sig := res.SigMap["tier2"]
	if sig.Run != 0 {
		t.Errorf("expected 0 tests run (all skipped), got %d", sig.Run)
	}
	if sig.Passed != 0 {
		t.Errorf("expected 0 tests passed, got %d", sig.Passed)
	}
	if sig.Skipped != 2 {
		t.Errorf("expected 2 skipped, got %d", sig.Skipped)
	}
}

func TestGinkgoSkippedOnlyInTestcasesDoesNotAffectRunCount(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"network": {
			Tests:    18,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Failure: true},
				{Name: "test2"},
				{Name: "skipped1", Skipped: true},
				{Name: "skipped2", Skipped: true},
				{Name: "skipped3", Skipped: true},
			},
		},
	}

	res := result.New(junitResults)

	sig := res.SigMap["network"]
	if sig.Run != 18 {
		t.Errorf("expected 18 tests run (header skipped=0, testcase skips should not reduce run count), got %d", sig.Run)
	}
	if sig.Passed != 17 {
		t.Errorf("expected 17 tests passed (18 run - 1 failed), got %d", sig.Passed)
	}
	if sig.Skipped != 3 {
		t.Errorf("expected 3 skipped for display (from testcase elements), got %d", sig.Skipped)
	}
}

func TestMarshalsResultToJSONCorrectly(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    2,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Classname: "Tests Suite", Failure: true},
			},
		},
	}

	res := result.New(junitResults)
	jsonData, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("unexpected error marshaling result to JSON: %v", err)
	}

	expected := `{"sig1":{"tests_run":2,"tests_passed":1,"tests_failures":1,"tests_skipped":0,"failed_tests":["test1"]},"summary":{"total_tests_run":2,"total_tests_passed":1,"total_tests_failed":1,"total_tests_skipped":0}}`
	if string(jsonData) != expected {
		t.Errorf("expected JSON %s, got %s", expected, string(jsonData))
	}
}

func TestSetupFailureExcludesSuiteFromResults(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"compute": {
			Tests:        63,
			Failures:     0,
			Errors:       0,
			SetupFailure: true,
		},
	}

	res := result.New(junitResults)

	if !res.SetupFailure {
		t.Error("expected SetupFailure to be true")
	}
	if len(res.SigMap) != 0 {
		t.Errorf("expected 0 sigs (setup failure should be excluded), got %d", len(res.SigMap))
	}
	if res.Summary.Run != 0 {
		t.Errorf("expected 0 total tests run, got %d", res.Summary.Run)
	}
}

func TestSetupFailureWithOtherValidSuites(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"compute": {
			Tests:        63,
			Failures:     0,
			SetupFailure: true,
		},
		"storage": {
			Tests:    10,
			Failures: 1,
			TestCases: []junit.TestCase{
				{Name: "test1", Failure: true},
			},
		},
	}

	res := result.New(junitResults)

	if !res.SetupFailure {
		t.Error("expected SetupFailure to be true")
	}
	if len(res.SigMap) != 1 {
		t.Errorf("expected 1 sig (only storage), got %d", len(res.SigMap))
	}
	if _, ok := res.SigMap["storage"]; !ok {
		t.Error("expected storage suite in results")
	}
	if res.Summary.Run != 10 {
		t.Errorf("expected 10 total tests run, got %d", res.Summary.Run)
	}
}

func TestCategorizesFailedTestsByClassname(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"tier2": {
			Tests:    5,
			Failures: 3,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test_hotplug_volume", Classname: "tests.storage.test_hotplug.TestHotPlug", Failure: true},
				{Name: "test_smbios_default", Classname: "tests.virt.cluster.general.test_smbios", Failure: true},
				{Name: "test_namespace_health", Classname: "tests.after_cluster_deploy_sanity.test_sanity", Failure: true},
				{Name: "test_passing", Classname: "tests.virt.node.test_node"},
				{Name: "test_also_passing", Classname: "tests.storage.test_resize"},
			},
		},
	}

	res := result.New(junitResults)

	sig := res.SigMap["tier2"]
	if sig.Failures != 3 {
		t.Errorf("expected 3 failures, got %d", sig.Failures)
	}

	if len(sig.FailedTests) != 3 {
		t.Errorf("expected 3 categories, got %d: %v", len(sig.FailedTests), sig.FailedTests)
	}

	storageTests := sig.FailedTests["storage"]
	if len(storageTests) != 1 || storageTests[0] != "test_hotplug_volume" {
		t.Errorf("expected storage category with 'test_hotplug_volume', got %v", storageTests)
	}

	virtTests := sig.FailedTests["virt/cluster"]
	if len(virtTests) != 1 || virtTests[0] != "test_smbios_default" {
		t.Errorf("expected virt/cluster category with 'test_smbios_default', got %v", virtTests)
	}

	sanityTests := sig.FailedTests["after_cluster_deploy_sanity"]
	if len(sanityTests) != 1 || sanityTests[0] != "test_namespace_health" {
		t.Errorf("expected after_cluster_deploy_sanity category with 'test_namespace_health', got %v", sanityTests)
	}
}

func TestCategorizedStringOutputIsHierarchical(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"tier2": {
			Tests:    4,
			Failures: 3,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test_hotplug", Classname: "tests.storage.test_hotplug.TestHotPlug", Failure: true},
				{Name: "test_smbios", Classname: "tests.virt.cluster.general.test_smbios", Failure: true},
				{Name: "test_cpu", Classname: "tests.virt.node.cpu_sockets_threads.test_cpu", Failure: true},
				{Name: "test_passing", Classname: "tests.virt.node.test_node"},
			},
		},
	}

	res := result.New(junitResults)
	output := res.String()

	if !strings.Contains(output, "  storage:\n") {
		t.Errorf("expected output to contain 'storage:' category header, got:\n%s", output)
	}
	if !strings.Contains(output, "  virt/cluster:\n") {
		t.Errorf("expected output to contain 'virt/cluster:' category header, got:\n%s", output)
	}
	if !strings.Contains(output, "  virt/node:\n") {
		t.Errorf("expected output to contain 'virt/node:' category header, got:\n%s", output)
	}
	if !strings.Contains(output, "    - test_hotplug") {
		t.Errorf("expected output to contain indented test_hotplug, got:\n%s", output)
	}
	if !strings.Contains(output, "    - test_smbios") {
		t.Errorf("expected output to contain indented test_smbios, got:\n%s", output)
	}
	if !strings.Contains(output, "    - test_cpu") {
		t.Errorf("expected output to contain indented test_cpu, got:\n%s", output)
	}
}

func TestUncategorizedStringOutputIsFlat(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"compute": {
			Tests:    2,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test_migration", Classname: "Tests Suite", Failure: true},
				{Name: "test_passing", Classname: "Tests Suite"},
			},
		},
	}

	res := result.New(junitResults)
	output := res.String()

	if !strings.Contains(output, "  - test_migration") {
		t.Errorf("expected output to contain flat '  - test_migration', got:\n%s", output)
	}
	if strings.Contains(output, ":\n    -") {
		t.Errorf("expected no category headers in uncategorized output, got:\n%s", output)
	}
}

func TestCategorizedJSONOutputUsesMap(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"tier2": {
			Tests:    3,
			Failures: 2,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test_hotplug", Classname: "tests.storage.test_hotplug.TestHotPlug", Failure: true},
				{Name: "test_smbios", Classname: "tests.virt.cluster.general.test_smbios", Failure: true},
				{Name: "test_passing", Classname: "tests.virt.node.test_node"},
			},
		},
	}

	res := result.New(junitResults)
	jsonData, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("unexpected error marshaling result to JSON: %v", err)
	}

	jsonStr := string(jsonData)
	if !strings.Contains(jsonStr, `"storage":["test_hotplug"]`) {
		t.Errorf("expected JSON to contain categorized storage tests, got %s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"virt/cluster":["test_smbios"]`) {
		t.Errorf("expected JSON to contain categorized virt/cluster tests, got %s", jsonStr)
	}
}

func TestConvertsResultToYAMLCorrectly(t *testing.T) {
	junitResults := map[string]junit.TestSuite{
		"sig1": {
			Tests:    2,
			Failures: 1,
			Skipped:  0,
			Disabled: 0,
			TestCases: []junit.TestCase{
				{Name: "test1", Classname: "Tests Suite", Failure: true},
			},
		},
	}

	res := result.New(junitResults)
	yamlData, err := res.GetYaml()
	if err != nil {
		t.Fatalf("unexpected error converting result to YAML: %v", err)
	}

	expected := `sig1:
  failed_tests:
  - test1
  tests_failures: 1
  tests_passed: 1
  tests_run: 2
  tests_skipped: 0
summary:
  total_tests_failed: 1
  total_tests_passed: 1
  total_tests_run: 2
  total_tests_skipped: 0
`

	if string(yamlData) != expected {
		t.Errorf("expected YAML:\n%s\n\ngot:\n%s", expected, string(yamlData))
	}
}
