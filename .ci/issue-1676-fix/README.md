# Issue 1676: patched Windows update proof

This test-only branch builds and validates the narrow metadata repair against product base `a4dd026cc5f85a444a0fcd05eef5b86282dbda8c`. The exact `PRODUCT.patch` SHA is carried into source, payload and native receipts.

A installer and startup-hook bytes are reused from run 41215893003, with the original pinned transfer-manifest and installer hashes. Only B (`2026.9.8-2`, non-Dev release identity) is rebuilt. The supported unsigned Release-test cleanup-host setting is used for B; no signing/trust/release changes are made.

The hosted build runs `build.ps1` and the full Shared and Tray test projects. Real TRX counters and original failures are retained. A failed suite keeps the workflow red even if the independent native update passes.

A separate fresh GitHub-hosted Windows Server 2025 VM installs real A, observes real startup, invokes the unchanged hook inside A through Updatum, verifies fresh B PID/start and every payload file, checks exact current DisplayVersion/DisplayName, and confirms all other registry fields and uninstaller files unchanged. The exact B process is independently inspected for hook absence. Stale metadata is a failure in this lane, not an accepted baseline outcome.

Baseline red evidence remains in run 41219361346. Native scripts and inspector are reused, with only branch admission, patched B provenance and green-result expectation changed. No arbitrary logs or memory dumps are uploaded. Cleanup stops only task-owned processes; the provider disposes of the VM.

Limits: controlled downloaded asset only, no release discovery/network download; hosted Server is not Windows 11 proof. Existing local Companion, daily, Nemo, main and original pairing requests are untouched. This workflow opens no PR and publishes no release.
