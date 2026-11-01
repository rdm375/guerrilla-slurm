# Three-node QEMU qualification

## Result

The generic Debian 13 CPU cluster passed its end-to-end QEMU qualification on 2026-11-01. This qualifies automated image provisioning and cluster setup in QEMU. It does not qualify physical USB boot, a physical wired LAN, laptop firmware or power behavior, or accelerator hardware.

## Test setup

- Manifest: `config/nodes.qemu-3.example.csv`
- Guests: one controller and two workers
- Guest resources: 2 vCPUs and 2 GiB RAM each
- Test network: private QEMU LAN, `192.168.77.0/24`
- Guest OS: Debian 13 amd64 cloud image

The successful run used `output/n-node-test-dns`. To run the qualification from fresh output, use a new output directory so the image builder does not overwrite existing raw images:

```sh
QEMU_OUTPUT="$PWD/output/qemu-$(date -u +%Y%m%dT%H%M%SZ)"
NODE_IMAGE_OUTPUT_DIR="$QEMU_OUTPUT" \
  bash ./build-node-images.sh build config/nodes.qemu-3.example.csv

NODE_IMAGE_OUTPUT_DIR="$QEMU_OUTPUT" QEMU_MEMORY=2G QEMU_CPUS=2 \
  bash ./scripts/qemu-node-cluster.sh config/nodes.qemu-3.example.csv
```

## Checks that passed

- Cloud-init completed on all guests with no reported errors; node identity and inventory matched the manifest.
- The controller initialized automatically, discovered both workers, enrolled them, and distributed Slurm/MUNGE configuration.
- Chrony synchronized on every node.
- Workers mounted the controller's NFSv4.2 export at `/cluster`; writes from each worker were readable through the shared path.
- Interactive `srun` ran one task on each manifest node.
- A multi-node `sbatch` job ran one task on each node and recorded output under `/cluster/results`.
- Worker `node-02` rebooted, rejoined using its existing enrollment key, and refreshed its test address to `192.168.77.211`.
- The controller rebooted. Slurm, NFS, and chrony recovered; all nodes returned to `IDLE`; post-reboot shared-storage and cross-node scheduling checks passed.
- The runner shut down all guests cleanly.

## Scope and limits

The QEMU test network is isolated from the physical network. It does not prove that a particular laptop boots from USB, that firmware selects the USB drive correctly, or that real DHCP and wired networking work on the intended LAN. It does not exercise NVIDIA or Hailo drivers, accelerator jobs, battery/lid behavior, thermal limits, or long-duration reliability.

Controller reboot recovery means services and already-enrolled workers recover after an ordinary reboot. It does not qualify controller replacement. If the controller system drive is lost, rebuild the cluster from the manifest and enroll the workers again. This project does not back up `/cluster`; files stored only there are not recovered by rebuilding.
