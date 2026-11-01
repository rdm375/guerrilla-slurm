# Self-organizing cluster from Windows laptops

## Goal

Turn a collection of x86-64 Windows laptops into a Slurm cluster by booting each from its own USB system drive. The laptop's internal Windows disk remains untouched. After the first cluster-level setup, a newly booted laptop should identify itself, discover the cluster controller, report its resources, and become available to Slurm without editing host lists or copying configuration by hand.

**Current implementation:** Debian 13 raw images, per-node identity, QEMU discovery/enrollment, shared NFS, Slurm CPU scheduling, and controller/worker reboot recovery are implemented and qualified in a three-node QEMU run. On a physical cluster, the operator initializes the controller and enrolls new workers; known workers can be rediscovered to refresh their addresses. A background membership daemon, controller failover, and project-data backup are outside the current scope. Physical USB deployment and real-LAN behavior remain untested.

“Windows laptop” describes the hardware being repurposed. The compute environment is native Linux booted from USB; this is not a Windows/WSL Slurm node. Use wired Ethernet on one trusted LAN for the first version. Wi-Fi client isolation, roaming, power saving, and variable latency make wireless membership and shared storage unreliable.

## Recommended first architecture

Use one common Debian 13 amd64 UEFI system image, then personalize each USB with a small per-machine identity/enrollment record. The root filesystem and software stay the same across laptops; the record gives every node a unique identity. Do not make a different operating-system build for every laptop model.

At first boot, each node should:

1. Generate a unique Linux machine ID and node identity if one was not provisioned on its USB.
2. Bring up wired IPv4 using DHCP and advertise/discover the cluster with mDNS on the local LAN.
3. Collect CPU topology with `slurmd -C`, usable memory, kernel and OS version, network addresses, and optional accelerator inventory.
4. Advertise the node identity and inventory. On the closed cluster LAN, the controller discovers matching workers and adds them to its generated Slurm configuration.
5. Install the shared Slurm configuration and a controller-issued MUNGE key, start `slurmd`, and report health.

The controller should be chosen once when a cluster is formed, for example by booting a controller-marked USB first and accepting workers after it advertises the cluster. It can also run compute jobs. Every other USB defaults to worker mode. Membership is automatic; controller election is deliberately not part of the first version.

### Why controller election is deferred

Slurm has one active `slurmctld` authority for a cluster. A network partition or simultaneous first boot can make independent laptops believe they are controller, producing conflicting cluster state. A safe controller failover design needs fencing or quorum, durable shared controller state, and a tested recovery procedure. Picking one controller during cluster formation is a small explicit step that avoids pretending ordinary mDNS discovery solves consensus.

## Image and identity model

Build one personalized raw image per manifest row from the same Debian base; do not make a different operating-system build for every laptop model. The node record gives each image a unique cluster ID, node ID, role, and hostname. The current builder stores the initial account password hash on the private NoCloud seed under ignored `work-nodes/`; the controller SSH key and MUNGE key are created after boot.

The builder accepts a manifest such as:

```yaml
cluster_id: field-cluster
controller: laptop-01
nodes:
  - id: laptop-01
    role: controller
  - id: laptop-02
    role: worker
  - id: laptop-03
    role: worker
```

Names above are examples, not tied to a laptop's Windows hostname. A build uses one initial login and password across its node images; batch enrollment asks for that password once.

The image writer requires an explicit target block device, displays its model and capacity, rejects mounted/root disks, and asks for an unmistakable confirmation before erasing it. Raw image files and enrollment secrets stay in ignored build directories. QEMU can validate image boot and first-boot provisioning, but it cannot validate a physical laptop's Wi-Fi, GPU, firmware, thermal behavior, Secure Boot state, USB boot menu, or the writer against a real drive.

## Network and Slurm membership

- The first version supports a single trusted IPv4 LAN and wired DHCP. Controller discovery uses a service name, not fixed addresses such as `192.168.1.185` or `192.168.1.199`.
- Give the controller a DHCP reservation or stable LAN address after discovery. Workers may use changing DHCP addresses, but the controller records the current address and hostname for each enrolled node.
- Only the controller writes the canonical `slurm.conf` and `gres.conf`. It creates node declarations from discovered hardware reports, distributes the exact same configuration to enrolled nodes, and runs `scontrol reconfigure` when membership changes.
- Register conservative `RealMemory` below physical RAM and CPU topology from the running host. Detect NVIDIA devices only when a working host driver is present; the current Slurm config uses generic GPU counts with node-specific autodetection. Advertise Hailo or other accelerators only after a matching driver/runtime and permissions pass a device check.
- The generic image flow exports the controller's `/cluster` directory over NFSv4 to the trusted cluster CIDR. Enrolled workers mount it at `/cluster` with a systemd automount. Keep the shared login's numeric UID/GID consistent across nodes so NFS ownership is consistent.
- Chrony runs on each node. The controller serves cluster time and uses an upstream pool when reachable, with a local fallback for isolated LANs; workers sync to the controller. This keeps MUNGE credentials within the same clock domain.
- When UFW is already active, setup opens SSH, NFSv4, Slurm controller/worker, Slurm job-step, mDNS, and NTP ports only from the cluster CIDR.
- This design assumes a closed trusted IPv4 LAN. Do not bridge the QEMU test network to the physical network. The controller role is explicit in the manifest; automatic controller election is out of scope.

## Windows laptop behavior

The USB image runs Debian from external storage, so Windows stays installed on the internal disk. The project should guide the operator to use the one-time UEFI boot menu and verify the selected target before writing each USB. Secure Boot may need to be disabled for third-party accelerator modules such as Hailo; this is hardware- and driver-dependent. Do not change firmware settings automatically.

For reliable compute, keep laptops on AC power, configure lid-close behavior so a closed lid does not suspend a running node, and monitor temperature and throttling. A worker that sleeps or disappears becomes unavailable through Slurm's node health checks; jobs need suitable requeue/checkpoint behavior. The controller currently does not automatically drain and remove stale nodes. Battery-powered or overheating nodes should not be treated as dependable capacity.

## Implementation milestones

1. **Inventory and image contract — implemented:** manifest validation, per-node identity, raw image creation, and a guarded USB writer.
2. **Bootable generic node — implemented for Debian 13 amd64:** DHCPv4, SSH, inventory, mDNS advertisement, Slurm/MUNGE, NFS client/server, and chrony.
3. **Controller discovery and enrollment — implemented:** mDNS discovery, identity check, initial SSH key setup, batch enrollment, and config distribution. Controller election remains manual.
4. **Membership operations — partly implemented:** re-running discovered-worker enrollment refreshes known workers and their addresses without the bootstrap password; `remove-worker` requires an empty queue, drains and removes the selected worker. There is no background reconciler or automatic stale-node cleanup.
5. **Hardware profiles — not qualified in generic images:** CPU resources are exercised; NVIDIA and Hailo driver/runtime setup remains hardware-specific.
6. **QEMU qualification — passed 2026-11-01:** three Debian 13 guests completed provisioning, discovery/enrollment, Chrony synchronization, NFSv4.2 shared-storage checks, interactive `srun`, multi-node `sbatch`, worker reboot/address refresh, and controller reboot recovery. All nodes returned to `IDLE`; post-reboot shared-storage and scheduling checks passed. Physical USB boot, real LAN/DHCP behavior, duplicate physical identity rejection, lid/power behavior, and accelerator workloads still need testing.

## Current repository gap

The generic raw-image path consists of `build-node-images.sh`, `config/nodes.example.csv`, node inventory/advertisement tools, `scripts/qemu-node-cluster.sh`, `write-node-image.sh`, and first-boot instructions in the README. The N-node runner connects all manifest guests to a private multicast LAN, assigns test addresses, waits for first boot, and runs the qualification flow.

`guerrilla-cluster-admin init-controller IPV4 [CLUSTER_CIDR]` creates the controller's MUNGE key, exports `/cluster` over NFSv4 to the cluster subnet, records its inventory, generates Slurm configuration, and starts `slurmctld` and `slurmd`. If the CIDR is omitted, the command derives it from the interface carrying the controller address. `enroll-discovered-workers LOGIN IPv4_CIDR` finds advertised workers on the selected LAN, checks their inventory and cluster ID over SSH, installs a controller SSH key, transfers the MUNGE key and Slurm configuration, configures the NFSv4 mount at `/cluster`, and starts `slurmd` on the workers.

The N-node QEMU runner automates first boot, test addressing, discovery, batch enrollment, chrony, NFSv4 shared-storage setup, configuration distribution, `srun` and `sbatch` smoke jobs, worker reboot/address refresh, and controller reboot recovery. The 2026-11-01 three-node run passed the full flow, including all nodes returning to `IDLE` and post-reboot shared-storage and cross-node scheduling checks. The QEMU cluster does not elect or fail over the controller. `remove-worker` supports deliberate cleanup, and repeating discovery refreshes reachable enrolled workers, but there is no background reconciler or stale-node policy. The controller is a single point of failure. Project-data backup and disaster recovery are outside the current scope; replacing a failed controller means rebuilding the cluster, and files stored only under `/cluster` are not recovered.

Each guest was configured with 2 vCPUs and 2 GiB memory. Cloud-init reported `done` with no errors on all guests. Chrony synchronized on every node; NFSv4.2 worker writes were visible on the controller; `srun` and `sbatch` each ran a task on all three nodes. The worker reboot test refreshed node-02 to `192.168.77.211`. The controller reboot test restored Slurm, NFS, and chrony, returned all nodes to `IDLE`, and passed another shared-storage probe and cross-node `srun`. All QEMU guests shut down cleanly. The test used the private `192.168.77.0/24` QEMU network and the `config/nodes.qemu-3.example.csv` manifest. This does not qualify physical USB boot or hardware accelerators.

The older `build-cloud-image.sh`, `setup-controller.sh`, `configure-node.sh`, `join-compute-node.sh`, and bootstrap package still target the Dell 7710/7680 pair. They remain a separate hardware-specific profile. The next generic milestone is a physical wired-LAN pilot when spare USB drives are available, followed by recording observed boot, network, shared-storage, and recovery behavior.
