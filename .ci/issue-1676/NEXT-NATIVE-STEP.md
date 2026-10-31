# Issue 1676: build artifacts, not native update proof

This job only compiles the unchanged test hook and builds two local test
versions from product commit a4dd026cc5f85a444a0fcd05eef5b86282dbda8c.
It never runs Setup, Companion, the hook or the updater. No product fix is present.
The artificial A/B versions are 2026.9.8-1 and 2026.9.8-2. Both use identical
baseline product source. These unsigned files are not official releases.

Build policy: RequireSignedCleanupHost=false is scoped to the build step, using
the intentional unsigned local Release-testing option documented in the pinned
docs/RELEASING.md (lines 955-977) and upstream non-published release-smoke jobs.
The first build stopped at the default signed-cleanup prerequisite; its failure
receipt is retained. This option does not change DevBuild/release identity,
product source, OS trust, execution policy or any release-signing workflow.

Use FILES-SHA256.json to verify the downloaded artifacts. Keep source-a and
base-b manifests with their respective files. The source manifest and hook
receipt bind the produced binaries to their inputs. Existing builds need not
be repeated merely to move them to a qualified test machine.

The original EXECUTION-GUIDE.md in issue-1676-local-agent-kit-v2.zip remains the
native execution guide. Its original kit SHA-256 is
73228b3b1728a41b4dbe40eeac18d01f9fe008e0f12da7da33158a2187b60022.

Before native execution, qualify a disposable Windows 11 x64 desktop with no
personal data, shared host profiles or existing Companion/Gateway installations.
Transfer these build outputs and the reviewed original kit, verify all hashes,
and prepare the named task root and clean/A-installed snapshots. Do not fabricate
VM receipts on an ordinary host or treat this hosted build as a Windows 11 run.
Record build provenance when reusing the hook rather than claiming it was built
on the native execution machine.

Native proof still needs real Inno A registration, smoke startup, vendor-owned
A-to-B ZIP replacement, fresh B startup, exact version/preservation assertions,
and separate complete managed-assembly inspection proving the hook is absent
at the observed B boundary. Diagnostics availability must be checked without
changing security/runtime policy. Preserve raw dumps only privately, not in
public Actions artifacts. Settings/app UI and winget evidence remain pending.

The hosted runner inventory is observation only: UserInteractive or an Explorer
process does not establish an unlocked usable desktop, snapshot support or
native proof readiness. Standard x64 Windows runners use Server images.

#1642 remains separate: this kit does not test discovery, alpha ordering,
release selection or network download. Existing Companion, daily and Nemo are
never execution targets. No PR or release publication is part of this work.
