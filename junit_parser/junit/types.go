package junit

import (
	"encoding/xml"
)

type TestSuites struct {
	XMLName    xml.Name    `xml:"testsuites"`
	TestSuites []TestSuite `xml:"testsuite"`
}

type TestSuite struct {
	XMLName   xml.Name   `xml:"testsuite"`
	Name      string     `xml:"name,attr"`
	Tests     int        `xml:"tests,attr"`
	Failures  int        `xml:"failures,attr"`
	Errors    int        `xml:"errors,attr"`
	Skipped   int        `xml:"skipped,attr"`
	Disabled  int        `xml:"disabled,attr"`
	Time      float64    `xml:"time,attr"`
	TestCases []TestCase `xml:"testcase"`

	// SetupFailure is set when the test binary exited non-zero but JUnit
	// reports zero failures, indicating a BeforeSuite or infrastructure error.
	SetupFailure bool `xml:"-"`
}

type TestCase struct {
	Name      string    `xml:"name,attr"`
	Classname string    `xml:"classname,attr"`
	Failure   TagExists `xml:"failure,omitempty"`
	Error     TagExists `xml:"error,omitempty"`
	SystemOut string    `xml:"system-out,omitempty"`
	Skipped   TagExists `xml:"skipped,omitempty"`
}

type TagExists bool

func (t *TagExists) UnmarshalXML(d *xml.Decoder, _ xml.StartElement) error {
	err := d.Skip()
	if err != nil {
		return err
	}

	*t = true
	return nil
}
