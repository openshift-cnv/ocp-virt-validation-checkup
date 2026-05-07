"""
Simple Windows VM test to verify the golden image works end-to-end.

This test:
1. Creates a VM from the Windows 11 golden image
2. Waits for the VM to boot and guest agent to connect
3. Verifies Windows is running
4. Cleans up the VM
"""

import pytest
import subprocess
import time
import json

GOLDEN_IMAGE_NAMESPACE = "openshift-virtualization-os-images"
GOLDEN_IMAGE_NAME = "windows11-golden-image"
TEST_NAMESPACE = "ocp-virt-validation"
TEST_VM_NAME = "windows-test-vm"


def run_oc(args: list, check: bool = True) -> subprocess.CompletedProcess:
    """Run an oc command and return the result."""
    cmd = ["oc"] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def get_json(args: list) -> dict:
    """Run oc command with -o json and return parsed JSON."""
    result = run_oc(args + ["-o", "json"])
    return json.loads(result.stdout)


@pytest.fixture
def windows_vm():
    """Create a Windows VM from the golden image and clean up after test."""
    vm_manifest = f"""
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: {TEST_VM_NAME}
  namespace: {TEST_NAMESPACE}
  labels:
    app: ocp-virt-validation-test
spec:
  running: true
  template:
    metadata:
      labels:
        app: ocp-virt-validation-test
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {{}}
        resources:
          requests:
            memory: 4Gi
      networks:
        - name: default
          pod: {{}}
      volumes:
        - name: rootdisk
          dataVolume:
            name: {TEST_VM_NAME}-rootdisk
  dataVolumeTemplates:
    - metadata:
        name: {TEST_VM_NAME}-rootdisk
      spec:
        sourceRef:
          kind: DataSource
          name: {GOLDEN_IMAGE_NAME}
          namespace: {GOLDEN_IMAGE_NAMESPACE}
        storage:
          resources:
            requests:
              storage: 25Gi
"""
    
    # Create the VM
    result = subprocess.run(
        ["oc", "apply", "-f", "-"],
        input=vm_manifest,
        capture_output=True,
        text=True,
        check=True
    )
    print(f"Created VM: {result.stdout}")
    
    yield TEST_VM_NAME
    
    # Cleanup
    run_oc(["delete", "vm", TEST_VM_NAME, "-n", TEST_NAMESPACE, "--ignore-not-found=true"])
    print(f"Cleaned up VM: {TEST_VM_NAME}")


@pytest.mark.windows
def test_windows_vm_boots_from_golden_image(windows_vm):
    """
    Test that a Windows VM can be created from the golden image and boots successfully.
    
    This verifies:
    1. The golden image DataSource is usable
    2. A VM can be cloned from it
    3. Windows boots and guest agent connects
    """
    vm_name = windows_vm
    
    # Wait for VM to be created and DataVolume to be ready (up to 10 minutes for cloning)
    print("Waiting for DataVolume to be ready...")
    for i in range(60):
        try:
            dv = get_json(["get", "dv", f"{vm_name}-rootdisk", "-n", TEST_NAMESPACE])
            phase = dv.get("status", {}).get("phase", "Unknown")
            progress = dv.get("status", {}).get("progress", "0%")
            print(f"  DataVolume phase: {phase}, progress: {progress}")
            if phase == "Succeeded":
                break
        except subprocess.CalledProcessError:
            pass
        time.sleep(10)
    else:
        pytest.fail("DataVolume did not become ready within 10 minutes")
    
    # Wait for VMI to be running (up to 5 minutes)
    print("Waiting for VMI to be running...")
    for i in range(30):
        try:
            vmi = get_json(["get", "vmi", vm_name, "-n", TEST_NAMESPACE])
            phase = vmi.get("status", {}).get("phase", "Unknown")
            print(f"  VMI phase: {phase}")
            if phase == "Running":
                break
        except subprocess.CalledProcessError:
            pass
        time.sleep(10)
    else:
        pytest.fail("VMI did not become Running within 5 minutes")
    
    # Wait for guest agent to connect (up to 10 minutes for Windows to fully boot)
    print("Waiting for guest agent to connect...")
    for i in range(60):
        try:
            vmi = get_json(["get", "vmi", vm_name, "-n", TEST_NAMESPACE])
            conditions = vmi.get("status", {}).get("conditions", [])
            agent_connected = any(
                c.get("type") == "AgentConnected" and c.get("status") == "True"
                for c in conditions
            )
            guest_os = vmi.get("status", {}).get("guestOSInfo", {})
            
            if agent_connected and guest_os:
                os_name = guest_os.get("name", "Unknown")
                os_version = guest_os.get("versionId", "Unknown")
                print(f"  Guest agent connected! OS: {os_name}, Version: {os_version}")
                
                # Verify it's Windows 11
                assert "Windows" in os_name, f"Expected Windows OS, got: {os_name}"
                assert os_version == "11", f"Expected Windows 11, got version: {os_version}"
                
                print("SUCCESS: Windows 11 VM booted successfully from golden image!")
                return
                
        except subprocess.CalledProcessError:
            pass
        time.sleep(10)
    
    pytest.fail("Guest agent did not connect within 10 minutes")


@pytest.mark.windows
def test_golden_image_datasource_exists():
    """Verify the Windows golden image DataSource exists and is ready."""
    try:
        ds = get_json(["get", "datasource", GOLDEN_IMAGE_NAME, "-n", GOLDEN_IMAGE_NAMESPACE])
        conditions = ds.get("status", {}).get("conditions", [])
        ready = any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in conditions
        )
        assert ready, "Golden image DataSource is not ready"
        print(f"Golden image DataSource '{GOLDEN_IMAGE_NAME}' is ready!")
    except subprocess.CalledProcessError as e:
        pytest.fail(f"Golden image DataSource not found: {e.stderr}")
