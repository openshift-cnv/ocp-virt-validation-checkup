import os
import random
import sys

import yaml
from junitparser import JUnitXml, Failure, Error, Skipped
from junitparser.junitparser import SystemOut
from kubernetes import client, config


def parse_junit_results(directory):
    grand_total_tests = 0
    grand_total_passed = 0
    grand_total_failures = 0

    results = {}

    # Traverse all subdirectories
    for root, _, files in os.walk(directory):
        sig = os.path.basename(os.path.normpath(root))
        if "junit.results.xml" in files:
            file_path = os.path.join(root, "junit.results.xml")

            failed_tests = []
            try:
                xml = JUnitXml.fromfile(file_path)

                total_tests = xml.tests
                total_skipped = xml.skipped
                total_failures = xml.failures
                total_passed = total_tests - total_failures
                if sig == "ssp":
                    total_passed -= total_skipped

                grand_total_tests += total_tests
                grand_total_passed += total_passed
                grand_total_failures += total_failures

                for suite in xml:
                    for case in suite:
                        if isinstance(case, (Skipped, SystemOut)):
                            continue
                        if isinstance(case, (Failure, Error)):
                            test_name = f"{suite.name}"
                            failed_tests.append(test_name)

            except Exception as e:
                print(f"Error parsing {file_path}: {e}")
                continue

            results[sig] = {
                "tests_run": total_tests,
                "tests_passed": total_passed,
                "tests_failures": total_failures,
                "tests_skipped": total_skipped,
            }

            if failed_tests:
                results[sig]["failed_tests"] = failed_tests

            # Print summary for suite
            print(f"{'='*19}\nSummary for {sig}\n{'='*19}")
            print(f"Tests Run: {total_tests}")
            print(f"Tests Passed: {total_passed}")
            print(f"Tests Failed: {total_failures}")
            print(f"Tests Skipped: {total_skipped}")

            if failed_tests:
                print("Failed Tests:")
                for test in failed_tests:
                    print(f"  - {test}")


    results["summary"] = {
        "total_tests_run": grand_total_tests,
        "total_tests_passed": grand_total_passed,
        "total_tests_failed": grand_total_failures
    }

    # Print total summary
    print(f"{'='*48}\nTotal Summary for execution from {os.getenv("TIMESTAMP")}\n{'='*48}")
    print(f"Total Tests Run: {grand_total_tests}")
    print(f"Total Tests Passed: {grand_total_passed}")
    print(f"Total Tests Failed: {grand_total_failures}")

    return results


def get_timestamps():
    results_dir = os.getenv("RESULTS_DIR")
    with open(os.path.join(results_dir, "startTimestamp"), 'r') as file:
        start_timestamp = file.read().strip()
    with open(os.path.join(results_dir, "completionTimestamp"), 'r') as file:
        completion_timestamp = file.read().strip()

    return start_timestamp, completion_timestamp

def save_results_to_cm(tests_results):
    if os.getenv("KUBECONFIG"):
        config.load_kube_config()
    else:
        config.load_incluster_config()

    name_timestamp = os.getenv("TIMESTAMP", random.randint(1, 100))
    config_map_name = f"ocp-virt-validation-results-{name_timestamp}"
    namespace = "ocp-virt-validation"
    content = yaml.dump(tests_results, default_flow_style=False, sort_keys=False, allow_unicode=True)
    config_map = client.V1ConfigMap(
        metadata=client.V1ObjectMeta(name=config_map_name),
        data={"self-validation-results": content}
    )

    start_timestamp, completion_timestamp = get_timestamps()
    config_map.data["status.startTimestamp"] = start_timestamp
    config_map.data["status.completionTimestamp"] = completion_timestamp

    if not config_map.metadata.labels:
        config_map.metadata.labels = {}
    config_map.metadata.labels["app"] = "ocp-virt-validation"

    v1 = client.CoreV1Api()
    try:
        v1.create_namespaced_config_map(namespace=namespace, body=config_map)
    except Exception as ex:
        print(f"ERROR: results config map could not be created: {ex}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script.py <directory>")
        sys.exit(1)

    results_dir = sys.argv[1]
    if not os.path.isdir(results_dir):
        print(f"Error: {results_dir} is not a valid directory")
        sys.exit(1)

    results = parse_junit_results(results_dir)
    save_results_to_cm(results)
