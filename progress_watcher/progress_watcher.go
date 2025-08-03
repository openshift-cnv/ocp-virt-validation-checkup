package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	resultsDir = flag.String("results-dir", "", "Directory containing test suite log files")
	stdout     = flag.Bool("stdout", false, "Also output progress to stdout (default: false, always writes to log file)")
)

var (
	specRegex = regexp.MustCompile(`Will run (\d+) of \d+ specs`)
	// For pytest (tier2 tests) - matches collected test count
	pytestRegex = regexp.MustCompile(`collected (\d+) items`)
	// Global logger for progress output
	logger  *log.Logger
	logFile *os.File
	// Previous progress state for change detection
	previousProgress *ProgressState
)

// TestSuite represents a single test suite being monitored
type TestSuite struct {
	Name      string
	LogFile   string
	Total     int
	Completed int
	Finished  bool
	Reader    *bufio.Reader
	File      *os.File
}

// ProgressState represents the current progress state for change detection
type ProgressState struct {
	OverallTotal     int
	OverallCompleted int
	OverallPercent   int
	ActiveSuites     int
	SuiteProgress    map[string]SuiteState
}

// SuiteState represents the progress state of a single test suite
type SuiteState struct {
	Total     int
	Completed int
	Percent   int
	Finished  bool
}

// DuplicateFilterWriter wraps an io.Writer and filters out consecutive duplicate lines
type DuplicateFilterWriter struct {
	writer   io.Writer
	lastLine string
	mutex    sync.Mutex
}

// NewDuplicateFilterWriter creates a new DuplicateFilterWriter
func NewDuplicateFilterWriter(writer io.Writer) *DuplicateFilterWriter {
	return &DuplicateFilterWriter{
		writer: writer,
	}
}

// Write implements io.Writer interface and filters out duplicate lines
func (d *DuplicateFilterWriter) Write(p []byte) (n int, err error) {
	d.mutex.Lock()
	defer d.mutex.Unlock()

	line := string(p)

	// If this line is the same as the last line, don't write it
	if line == d.lastLine {
		// Return the length as if we wrote it to satisfy the io.Writer interface
		return len(p), nil
	}

	// Update last line and write to underlying writer
	d.lastLine = line
	return d.writer.Write(p)
}

// setupLogging configures logging to file and optionally to stdout with duplicate filtering
func setupLogging() error {
	var err error
	logFile, err = os.OpenFile("/tmp/progress_watcher.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("failed to open log file: %v", err)
	}

	// Always write to log file with duplicate filtering, conditionally include stdout
	var writers []io.Writer
	writers = append(writers, NewDuplicateFilterWriter(logFile))

	if *stdout {
		writers = append(writers, NewDuplicateFilterWriter(os.Stdout))
	}

	multiWriter := io.MultiWriter(writers...)
	logger = log.New(multiWriter, "[PROGRESS] ", log.LstdFlags)

	return nil
}

func main() {
	flag.Parse()

	if *resultsDir == "" {
		fmt.Fprintln(os.Stderr, "Missing required --results-dir argument")
		os.Exit(1)
	}

	// Set up logging to file and stdout
	if err := setupLogging(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to setup logging: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		if logFile != nil {
			logFile.Close()
		}
	}()

	logger.Println("Progress watcher starting...")

	clientset := getClientset()

	// Set up signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Discover test suites by looking for log files
	suites := discoverTestSuites(*resultsDir)
	if len(suites) == 0 {
		logger.Println("No test suite log files found. Waiting for test suites to start...")
	}

	// Cleanup function
	cleanup := func() {
		logger.Println("Cleaning up...")
		for _, suite := range suites {
			if suite.File != nil {
				suite.File.Close()
			}
		}
	}

	// Main monitoring loop
	for {
		select {
		case <-sigChan:
			logger.Println("Received shutdown signal")
			cleanup()
			os.Exit(0)
		default:
			// Rediscover suites in case new ones start
			newSuites := discoverTestSuites(*resultsDir)
			for _, newSuite := range newSuites {
				found := false
				for _, existing := range suites {
					if existing.Name == newSuite.Name {
						found = true
						break
					}
				}
				if !found {
					logger.Printf("Discovered new test suite: %s\n", newSuite.Name)
					suites = append(suites, newSuite)
				}
			}

			// Process each suite
			for _, suite := range suites {
				if suite.Reader == nil {
					// Try to open the log file
					file, err := os.Open(suite.LogFile)
					if err != nil {
						continue // File might not exist yet
					}
					suite.File = file
					suite.Reader = bufio.NewReader(file)
				}

				// Read new lines from this suite
				for {
					line, err := suite.Reader.ReadString('\n')
					if err != nil {
						break // No more lines available
					}

					line = strings.TrimSpace(line)
					processSuiteLine(suite, line)
				}
			}

			// Calculate overall progress and update Job annotations
			if err := updateJobAnnotations(clientset, suites); err != nil {
				logger.Printf("Error updating job annotations: %v\n", err)
			}

			time.Sleep(300 * time.Millisecond)
		}
	}
}

func getClientset() *kubernetes.Clientset {
	var config *rest.Config
	var err error

	kubeconfigEnv := os.Getenv("KUBECONFIG")
	if kubeconfigEnv != "" {
		// Use KUBECONFIG path from env
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfigEnv)
	} else {
		// Try default location (~/.kube/config)
		homeDir, _ := os.UserHomeDir()
		defaultKubeconfig := filepath.Join(homeDir, ".kube", "config")
		if _, err = os.Stat(defaultKubeconfig); err == nil {
			config, err = clientcmd.BuildConfigFromFlags("", defaultKubeconfig)
		} else {
			// Fall back to in-cluster config (for use inside Kubernetes pod)
			config, err = rest.InClusterConfig()
		}
	}

	if err != nil {
		panic(fmt.Errorf("failed to create Kubernetes config: %v", err))
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}
	return clientset
}

// discoverTestSuites finds all test suite log files in the results directory
func discoverTestSuites(resultsDir string) []*TestSuite {
	var suites []*TestSuite

	// Known test suite patterns
	suitePatterns := map[string]string{
		"compute": filepath.Join(resultsDir, "compute", "compute-log.txt"),
		"network": filepath.Join(resultsDir, "network", "network-log.txt"),
		"storage": filepath.Join(resultsDir, "storage", "storage-log.txt"),
		"ssp":     filepath.Join(resultsDir, "ssp", "ssp-log.txt"),
		"tier2":   filepath.Join(resultsDir, "tier2", "tier2-log.txt"),
	}

	for suiteName, logPath := range suitePatterns {
		if _, err := os.Stat(logPath); err == nil {
			suites = append(suites, &TestSuite{
				Name:    suiteName,
				LogFile: logPath,
			})
		}
	}

	return suites
}

// getTotalExpectedSuites returns the total number of test suites that could be executed
func getTotalExpectedSuites() int {
	// Read from TEST_SUITES environment variable (comma-separated list)
	testSuites := os.Getenv("TEST_SUITES")
	if testSuites == "" {
		// Default to all 5 suites if not specified
		return 5
	}

	// Split by comma and count
	suites := strings.Split(testSuites, ",")
	count := 0
	for _, suite := range suites {
		if strings.TrimSpace(suite) != "" {
			count++
		}
	}

	return count
}

// processSuiteLine processes a single line from a test suite log
func processSuiteLine(suite *TestSuite, line string) {
	// Check for total specs detection (Ginkgo)
	if suite.Total == 0 {
		if match := specRegex.FindStringSubmatch(line); match != nil {
			logger.Printf("[%s] Detected total specs: %s\n", suite.Name, match[1])
			fmt.Sscanf(match[1], "%d", &suite.Total)
			return
		}
		// Check for pytest total (tier2)
		if match := pytestRegex.FindStringSubmatch(line); match != nil {
			logger.Printf("[%s] Detected total pytest items: %s\n", suite.Name, match[1])
			fmt.Sscanf(match[1], "%d", &suite.Total)
			return
		}
	}

	// Check for suite completion indicators
	if !suite.Finished {
		// Common completion patterns that indicate the suite has finished
		finishPatterns := []string{
			"Ran ",                // Ginkgo final summary
			"===",                 // Pytest session summary
			"PASS:",               // Final pass/fail status
			"FAIL:",               // Final pass/fail status
			"tests completed",     // Generic completion
			"test session starts", // End of pytest session
		}

		for _, pattern := range finishPatterns {
			if strings.Contains(line, pattern) && (strings.Contains(line, "second") ||
				strings.Contains(line, "passed") || strings.Contains(line, "failed") ||
				strings.Contains(line, "complete")) {
				suite.Finished = true
				logger.Printf("[%s] Suite finished\n", suite.Name)
				break
			}
		}

		// Also check if we've reached total completion
		if suite.Total > 0 && suite.Completed >= suite.Total {
			suite.Finished = true
			logger.Printf("[%s] Suite finished (reached total count)\n", suite.Name)
		}
	}

	// Check for completed tests
	if !suite.Finished { // Only count new completions if not finished
		if strings.HasPrefix(line, "•") { // Ginkgo test completion
			suite.Completed++
			logger.Printf("[%s] Completed: %d/%d\n", suite.Name, suite.Completed, suite.Total)

			// Check if we've now reached completion
			if suite.Total > 0 && suite.Completed >= suite.Total {
				suite.Finished = true
				logger.Printf("[%s] Suite finished (reached total count)\n", suite.Name)
			}
		} else if strings.Contains(line, "PASSED") || strings.Contains(line, "FAILED") {
			// Pytest test completion patterns
			if strings.Contains(line, "::test_") || strings.Contains(line, " test_") {
				suite.Completed++
				logger.Printf("[%s] Completed: %d/%d\n", suite.Name, suite.Completed, suite.Total)

				// Check if we've now reached completion
				if suite.Total > 0 && suite.Completed >= suite.Total {
					suite.Finished = true
					logger.Printf("[%s] Suite finished (reached total count)\n", suite.Name)
				}
			}
		}
	}
}

// getCurrentPod gets information about the current pod
func getCurrentPod(clientset *kubernetes.Clientset) (*corev1.Pod, error) {
	// Get pod name from environment variable
	podName := os.Getenv("POD_NAME")
	if podName == "" {
		return nil, fmt.Errorf("POD_NAME environment variable not set - unable to determine pod name")
	}

	// Get namespace from environment variable
	namespace := os.Getenv("POD_NAMESPACE")
	if namespace == "" {
		return nil, fmt.Errorf("POD_NAMESPACE environment variable not set - unable to determine pod namespace")
	}

	ctx := context.TODO()
	pod, err := clientset.CoreV1().Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to get current pod %s/%s: %v", namespace, podName, err)
	}

	return pod, nil
}

// getOwningJob finds the Job that owns the given pod
func getOwningJob(clientset *kubernetes.Clientset, pod *corev1.Pod) (*batchv1.Job, error) {
	ctx := context.TODO()

	// Look through owner references to find the Job
	for _, ownerRef := range pod.OwnerReferences {
		if ownerRef.Kind == "Job" && ownerRef.APIVersion == "batch/v1" {
			job, err := clientset.BatchV1().Jobs(pod.Namespace).Get(ctx, ownerRef.Name, metav1.GetOptions{})
			if err != nil {
				return nil, fmt.Errorf("failed to get owning job %s/%s: %v", pod.Namespace, ownerRef.Name, err)
			}
			return job, nil
		}
	}

	return nil, fmt.Errorf("pod %s/%s is not owned by a Job", pod.Namespace, pod.Name)
}

// hasProgressChanged compares current progress with previous state to detect changes
func hasProgressChanged(currentState *ProgressState) bool {
	if previousProgress == nil {
		return true // First time, consider it as a change
	}

	// Compare overall progress
	if previousProgress.OverallTotal != currentState.OverallTotal ||
		previousProgress.OverallCompleted != currentState.OverallCompleted ||
		previousProgress.OverallPercent != currentState.OverallPercent ||
		previousProgress.ActiveSuites != currentState.ActiveSuites {
		return true
	}

	// Compare per-suite progress
	if len(previousProgress.SuiteProgress) != len(currentState.SuiteProgress) {
		return true
	}

	for suiteName, currentSuite := range currentState.SuiteProgress {
		previousSuite, exists := previousProgress.SuiteProgress[suiteName]
		if !exists ||
			previousSuite.Total != currentSuite.Total ||
			previousSuite.Completed != currentSuite.Completed ||
			previousSuite.Percent != currentSuite.Percent ||
			previousSuite.Finished != currentSuite.Finished {
			return true
		}
	}

	return false
}

// updateJobAnnotations calculates overall progress and updates the Job annotations
func updateJobAnnotations(clientset *kubernetes.Clientset, suites []*TestSuite) error {
	ctx := context.TODO()

	// Get current pod
	pod, err := getCurrentPod(clientset)
	if err != nil {
		return fmt.Errorf("failed to get current pod: %v", err)
	}

	// Get owning Job
	job, err := getOwningJob(clientset, pod)
	if err != nil {
		return fmt.Errorf("failed to get owning job: %v", err)
	}

	// Calculate progress using equal contribution per suite
	var overallTotal, overallCompleted int
	var suitePercentageSum int
	totalExpectedSuites := getTotalExpectedSuites()
	annotations := make(map[string]string)

	for _, suite := range suites {
		overallTotal += suite.Total
		overallCompleted += suite.Completed

		// Calculate suite percentage
		var suitePercent int
		if suite.Finished {
			// Finished suites always count as 100%
			suitePercent = 100
		} else if suite.Total > 0 {
			suitePercent = suite.Completed * 100 / suite.Total
		} else {
			suitePercent = 0
		}

		suitePercentageSum += suitePercent

		// Store per-suite data as annotations
		annotations[fmt.Sprintf("test-progress/%s-total", suite.Name)] = fmt.Sprintf("%d", suite.Total)
		annotations[fmt.Sprintf("test-progress/%s-completed", suite.Name)] = fmt.Sprintf("%d", suite.Completed)
		annotations[fmt.Sprintf("test-progress/%s-percent", suite.Name)] = fmt.Sprintf("%d", suitePercent)
		annotations[fmt.Sprintf("test-progress/%s-finished", suite.Name)] = fmt.Sprintf("%t", suite.Finished)
	}

	// Calculate overall percentage: (sum of suite percentages) / (total expected suites)
	// Each suite contributes equally to the overall progress
	var overallPercent int
	if totalExpectedSuites > 0 {
		overallPercent = suitePercentageSum / totalExpectedSuites
	}

	// Build current progress state for change detection
	currentState := &ProgressState{
		OverallTotal:     overallTotal,
		OverallCompleted: overallCompleted,
		OverallPercent:   overallPercent,
		ActiveSuites:     len(suites),
		SuiteProgress:    make(map[string]SuiteState),
	}

	// Populate per-suite progress state
	for _, suite := range suites {
		var percent int
		if suite.Finished {
			// Finished suites always count as 100%
			percent = 100
		} else if suite.Total > 0 {
			percent = suite.Completed * 100 / suite.Total
		}
		currentState.SuiteProgress[suite.Name] = SuiteState{
			Total:     suite.Total,
			Completed: suite.Completed,
			Percent:   percent,
			Finished:  suite.Finished,
		}
	}

	// Check if progress has changed
	progressChanged := hasProgressChanged(currentState)

	// Store overall data as annotations
	annotations["test-progress/total"] = fmt.Sprintf("%d", overallTotal)
	annotations["test-progress/completed"] = fmt.Sprintf("%d", overallCompleted)
	annotations["test-progress/percent"] = fmt.Sprintf("%d", overallPercent)
	annotations["test-progress/active-suites"] = fmt.Sprintf("%d", len(suites))

	// Only update last-updated if progress has actually changed
	if progressChanged {
		annotations["test-progress/last-updated"] = time.Now().UTC().Format(time.RFC3339)
		// Update the global previous progress state
		previousProgress = currentState
	}

	// Update job annotations
	if job.Annotations == nil {
		job.Annotations = make(map[string]string)
	}

	// Copy new annotations to job
	for key, value := range annotations {
		job.Annotations[key] = value
	}

	// Update the job
	_, err = clientset.BatchV1().Jobs(job.Namespace).Update(ctx, job, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("failed to update job annotations: %v", err)
	}

	logger.Printf("Updated job %s/%s annotations: %d/%d tests completed (%d%%)\n",
		job.Namespace, job.Name, overallCompleted, overallTotal, overallPercent)

	return nil
}
