package junit

import (
	"encoding/xml"
	"testing"
)

func TestUnmarshalsValidTestSuites(t *testing.T) {
	data := `
 <testsuites>
   <testsuite name="suite1" tests="2" failures="1" skipped="0" disabled="0">
     <testcase name="test1" classname="class1"/>
     <testcase name="test2" classname="class2">
       <failure/>
     </testcase>
   </testsuite>
 </testsuites>`

	var testSuites TestSuites
	err := xml.Unmarshal([]byte(data), &testSuites)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(testSuites.TestSuites) != 1 {
		t.Errorf("expected 1 testsuite, got %d", len(testSuites.TestSuites))
	}

	suite := testSuites.TestSuites[0]
	if suite.Name != "suite1" {
		t.Errorf("expected suite name to be 'suite1', got '%s'", suite.Name)
	}
	if suite.Tests != 2 {
		t.Errorf("expected 2 tests, got %d", suite.Tests)
	}
	if suite.Failures != 1 {
		t.Errorf("expected 1 failure, got %d", suite.Failures)
	}
	if len(suite.TestCases) != 2 {
		t.Errorf("expected 2 test cases, got %d", len(suite.TestCases))
	}

	if suite.TestCases[0].Failure {
		t.Errorf("expected first test case to not have failure, got true")
	}
	if !suite.TestCases[1].Failure {
		t.Errorf("expected second test case to have failure, got false")
	}
}

func TestUnmarshalsEmptyTestSuites(t *testing.T) {
	data := `<testsuites></testsuites>`

	var testSuites TestSuites
	err := xml.Unmarshal([]byte(data), &testSuites)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(testSuites.TestSuites) != 0 {
		t.Errorf("expected 0 testsuites, got %d", len(testSuites.TestSuites))
	}
}

func TestUnmarshalsTestCaseWithFailure(t *testing.T) {
	data := `
 <testcase name="test1" classname="class1">
   <failure>the test failed</failure>
 </testcase>`

	var testCase TestCase
	err := xml.Unmarshal([]byte(data), &testCase)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if testCase.Name != "test1" {
		t.Errorf("expected test name to be 'test1', got '%s'", testCase.Name)
	}
	if !testCase.Failure {
		t.Errorf("expected failure to be true, got false")
	}
}

func TestUnmarshalsTestCaseWithSkip(t *testing.T) {
	data := `
 <testcase name="test1" classname="class1">
   <skipped></skipped>
 </testcase>`

	var testCase TestCase
	err := xml.Unmarshal([]byte(data), &testCase)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if testCase.Name != "test1" {
		t.Errorf("expected test name to be 'test1', got '%s'", testCase.Name)
	}
	if !testCase.Skipped {
		t.Errorf("expected skipped to be true, got false")
	}
}

func TestUnmarshalsTestCaseWithError(t *testing.T) {
	data := `
 <testcase name="test1" classname="class1">
   <error>a critical error!</error>
 </testcase>`

	var testCase TestCase
	err := xml.Unmarshal([]byte(data), &testCase)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if testCase.Name != "test1" {
		t.Errorf("expected test name to be 'test1', got '%s'", testCase.Name)
	}
	if !testCase.Error {
		t.Errorf("expected error to be true, got false")
	}
}

func TestUnmarshalsTestCaseWithoutFailure(t *testing.T) {
	data := `<testcase name="test1" classname="class1"></testcase>`

	var testCase TestCase
	err := xml.Unmarshal([]byte(data), &testCase)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if testCase.Name != "test1" {
		t.Errorf("expected test name to be 'test1', got '%s'", testCase.Name)
	}
	if testCase.Failure {
		t.Errorf("expected failure to be false, got true")
	}
}
