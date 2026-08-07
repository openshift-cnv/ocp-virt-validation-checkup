# Bug: Windows golden image setup fails hard in truly disconnected environments

## Summary

In a truly disconnected cluster, `setup-golden-image.sh` exits with code 1 when
the Tekton hub resolver cannot reach ArtifactHub/GitHub to download the
`windows-efi-installer` pipeline. This causes the entire validation run to abort
instead of gracefully skipping Windows tests.

## Root cause

`setup-golden-image.sh` creates the PipelineRun with `resolver: hub`:

```yaml
pipelineRef:
  resolver: hub
  params:
    - name: catalog
      value: redhat-pipelines
    - name: kind
      value: pipeline
    - name: name
      value: windows-efi-installer
```

The hub resolver always fetches remotely from ArtifactHub (`artifacthub.io`) and
may pull pipeline task definitions from `github.com` or `raw.githubusercontent.com`.
In a disconnected environment none of these are reachable, so Tekton reports
`CouldntGetPipeline`.

The error handler currently exits with code 1 (hard failure):

```bash
"CouldntGetPipeline")
  echo "ERROR: Failed to fetch pipeline from artifacthub."
  echo "For disconnected environments, manually install the pipeline first:"
  echo "  https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer"
  exit 1   # aborts all test suites, not just Windows
  ;;
```

## Impact

- All test suites (compute, network, storage, ssp, tier2) are aborted, not just Windows.
- The error message points to an ArtifactHub URL that is also unreachable in disconnected mode.

## Expected behaviour

- `CouldntGetPipeline` should exit with `EXIT_WINDOWS_SKIP` (2) so only Windows tests
  are skipped and all other suites continue normally.
- The error message should instruct the user to pre-install the pipeline from a local
  mirror before going disconnected.

## Proposed fix

1. Change `exit 1` to `exit ${EXIT_WINDOWS_SKIP}` for the `CouldntGetPipeline` case.
2. Update the error message with actionable disconnected instructions (download pipeline
   YAML before disconnecting, apply with `oc apply -f pipeline.yaml -n <namespace>`).
3. Add support for a pre-installed `Pipeline` resource: when a `Pipeline` named
   `windows-efi-installer` already exists in the namespace, use `pipelineRef.name`
   instead of `pipelineRef.resolver: hub`.

## Related

- CNV-94759: Simulate true disconnected scenario for Windows golden image testing
- `scripts/windows/setup-golden-image.sh`: `CouldntGetPipeline` handler and PipelineRun spec

## Notes

_Tested 2026-08-07: blocking `github.com` and `objects.githubusercontent.com` does NOT
trigger `CouldntGetPipeline`. The hub resolver only needs `artifacthub.io` — pipeline
resolved successfully with those domains blocked. The failure described above only
applies when `artifacthub.io` itself is unreachable (fully air-gapped cluster)._
