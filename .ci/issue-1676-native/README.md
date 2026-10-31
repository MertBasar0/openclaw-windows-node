# #1676: controlled native update on GitHub-hosted Windows

User-authorized follow-up to build run 41215893003. Reuses its unchanged hook,
A Inno 2026.9.8-1 and B ZIP 2026.9.8-2, product source
a4dd026cc5f85a444a0fcd05eef5b86282dbda8c. No source build or product fix.

This lane uses a fresh GitHub-hosted Windows Server 2025 x64 VM. It does not
claim Windows 11, an operator desktop, snapshots, or any existing Companion,
OCM daily or Nemo environment. A target receipt records the actual Actions
run/machine/user; it does not invent a snapshot identifier. A future patch lane
would start in another fresh VM and reinstall the same hashed A fixture.

The original kit's behavior and preservation assertions are retained. Actions
copies change only hosted-target receipt admission and PowerShell7.6 timestamp
reads (`ConvertFrom-Json -DateKind String`). No process identity check is weakened.
The single-instance installation path remains the real per-user Inno path.

Execution:
1. Verify previously built files, independently pinned transfer manifest and A/B hashes.
2. Open the input desktop and render a synthetic foreground window. A captured
   client pixel must match its known paint color. This proves access/rendering,
   not Windows 11 equivalence or all future UI interactions.
3. Install a pinned Microsoft dotnet-dump tool under the task directory only.
   Never change diagnostics, certificates, OS security or execution policy.
4. Run actual Inno A silently, with no startup tasks, launch or reboot. Retain
   installer exit and actual startup/registration smoke.
5. Capture A's visible window and terminate the exact owned smoke process. This
   fixture cleanup is not counted as evidence of the vendor update's exit/restart.
6. The unchanged driver starts actual A with the test-only child-scoped hook;
   after real startup the actual Updatum1.3.4 install operation owns extraction,
   replacement, exit and relaunch. No manual file overlay or registry edits.
7. Verify B's fresh PID/start, complete payload, uninstaller/non-version registry
   preservation and independently expected B display metadata.
8. Even when the final metadata assertion detects the named stale-registration
   defect, independently inspect that exact restarted B's complete managed
   assembly inventory for hook absence. An incomplete inventory blocks acceptance.
9. Stop only owned Companion processes. The provider disposes the ephemeral VM.

A green experiment can classify the expected baseline defect as reproduced;
it is never a claim that the defect is fixed. Unknown errors and missing proof
fail the job. The controlled experiment begins at the downloaded-asset boundary;
GitHub discovery, release ordering, network download, and #1642 are not covered.

Raw dumps and raw inspector output stay in a private directory and are removed.
Only explicit synthetic receipts, names-only inventory and task-window images
are retained. No app configuration, tokens, arbitrary logs or private Team links
are uploaded. Public artifacts must be inspected before reuse as PR evidence.

References:
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://jrsoftware.org/ishelp/topic_setupcmdline.htm
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openinputdesktop
- inspector/INSPECTOR-NOTES.md
