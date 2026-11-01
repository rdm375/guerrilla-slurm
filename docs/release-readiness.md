# Release readiness and polish plan

## Current evidence

- Three-node Debian 13 QEMU qualification passed on 2026-11-01; see [the qualification record](qemu-qualification.md).
- The QEMU run exercised provisioning, enrollment, clock synchronization, shared NFS storage, interactive and batch scheduling, worker reboot/rejoin, and controller reboot recovery.
- Physical USB boot, real-LAN behavior, and accelerator workloads have not been qualified.
- Project-data backup, controller failover, automatic controller election, and background membership reconciliation are outside the current project scope.
- The Dell 7710/7680 scripts are a separate, host-specific profile and must not be presented as the generic N-node workflow.

## Polish rounds before GitHub publication

### Round 1: behavior and documentation consistency

- Keep the README, design note, command help, and examples aligned with the manifest-driven workflow.
- Check documented commands, paths, packages, image outputs, and recovery claims against the implementation.
- State physical and accelerator qualification gaps plainly; do not imply that QEMU proves them.
- Keep generated images, seed ISOs, passwords, keys, logs, and QEMU state out of the repository.

### Round 2: implementation and deployment review

- Review image creation, disk writing, manifest validation, controller initialization, worker enrollment, and cleanup for failure handling and repeat runs.
- Review SSH trust/bootstrap behavior, password handling, secret permissions, and the trusted-LAN assumptions.
- Check package/version assumptions and network/firewall requirements on a clean Debian 13 host.
- Review which legacy Dell-specific scripts remain useful and label their limits.

### Round 3: public project polish

- Add the selected open-source license; do not publish until the project owner chooses it.
- Make the README opening, quick-start, prerequisites, tested status, and limitations understandable without conversation history.
- Add concise contribution and issue-reporting guidance if the project will accept outside contributions.
- Review hostnames, private-network examples, and lab-specific details for public suitability.
- Prepare release notes and a project graphic after the repository state is stable.

## Publication order

1. Complete and review the polish rounds locally.
2. Re-run the documented QEMU qualification from a fresh output directory and record the repository revision.
3. Inspect the final diff and repository contents for generated artifacts, credentials, stale instructions, and unsupported claims.
4. Publish the reviewed repository state to GitHub.
5. Prepare the LinkedIn post from the published README and qualification record, describing the QEMU result and remaining physical-hardware qualification honestly.

No GitHub push or LinkedIn publication is part of this preparation pass.
