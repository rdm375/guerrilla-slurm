# Self-organizing cluster from Windows laptops

## Goal

Turn a collection of x86-64 Windows laptops into a Slurm cluster by booting each from its own USB system drive. The laptop's internal Windows disk remains untouched. After the first cluster-level setup, a newly booted laptop should identify itself, discover the cluster controller, report its resources, and become available to Slurm without editing host lists or copying configuration by hand.

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

The image writer must require an explicit target block device, display its model and capacity, and ask for an unmistakable confirmation before erasing it. Raw image files and enrollment secrets stay in ignored build directories. QEMU can validate image boot and first-boot provisioning, but it cannot validate a physical laptop's Wi-Fi, GPU, firmware, thermal behavior, Secure Boot state, or USB boot menu.

## Network and Slurm membership

- The first version supports a single trusted IPv4 LAN and wired DHCP. Controller discovery uses a service name, not fixed addresses such as `192.168.1.185` or `192.168.1.199`.
- Give the controller a DHCP reservation or stable LAN address after discovery. Workers may use changing DHCP addresses, but the controller records the current address and hostname for each enrolled node.
- Only the controller writes the canonical `slurm.conf` and `gres.conf`. It creates node declarations from discovered hardware reports, distributes the exact same configuration to enrolled nodes, and runs `scontrol reconfigure` when membership changes.
- Register conservative `RealMemory` below physical RAM and CPU topology from the running host. Detect NVIDIA devices only when a working host driver is present; the current Slurm config uses generic GPU counts with node-specific autodetection. Advertise Hailo or other accelerators only after a matching driver/runtime and permissions pass a device check.
- The current NFS arrangement is optional for the first discovery milestone. If shared storage is enabled, require a common numeric UID/GID and mount it only after the node has enrolled.
- This design assumes a closed trusted IPv4 LAN. Do not bridge the QEMU test network to the physical network. The controller role is explicit in the manifest; automatic controller election is out of scope.

## Windows laptop behavior

The USB image runs Debian from external storage, so Windows stays installed on the internal disk. The project should guide the operator to use the one-time UEFI boot menu and verify the selected target before writing each USB. Secure Boot may need to be disabled for third-party accelerator modules such as Hailo; this is hardware- and driver-dependent. Do not change firmware settings automatically.

For reliable compute, keep laptops on AC power, configure lid-close behavior so a closed lid does not suspend a running node, and monitor temperature and throttling. A worker that sleeps or disappears should drain or become unavailable in Slurm; jobs need suitable requeue/checkpoint behavior. Battery-powered or overheating nodes should not be treated as dependable capacity.

## Implementation milestones

1. **Inventory and image contract:** define supported x86-64/UEFI assumptions, node manifest, per-node identity format, and safe USB write flow.
2. **Bootable generic node:** replace the Dell-specific cloud-init values with a reusable Debian image; create a unique machine ID on first boot; configure DHCPv4 and SSH access without embedding cluster secrets.
3. **Controller discovery and enrollment:** discover workers by mDNS on the closed LAN, collect their inventory over SSH, and enroll the discovered set in one batch. Controller election remains manual.
4. **Dynamic Slurm configuration:** generate consistent node/GRES declarations from discovered inventory; reconfigure the controller and enrolled workers. Automatic stale-node draining remains future work.
5. **Hardware profiles:** validate CPU-only laptops first, then optional NVIDIA and Hailo profiles with driver/kernel compatibility checks.
6. **Qualification:** boot controller and multiple workers in QEMU for network/enrollment behavior, then test physical USB boot on representative laptops. A three-node QEMU qualification passed on 2026-10-30. Still verify duplicate identity rejection, worker restart, DHCP address change, controller restart, lost-node handling, physical USB boot, and accelerator behavior before calling the cluster self-organizing.

## Current repository gap

The generic raw-image path consists of `build-node-images.sh`, `config/nodes.example.csv`, node inventory/advertisement tools, `scripts/qemu-node-cluster.sh`, and first-boot instructions in the README. The N-node runner connects all manifest guests to a private multicast LAN, assigns test addresses, waits for first boot, and runs the qualification flow.

`guerrilla-cluster-admin init-controller IPV4` creates the controller's MUNGE key, records its inventory, generates Slurm configuration, and starts `slurmctld` and `slurmd`. `enroll-discovered-workers LOGIN IPv4_CIDR` finds advertised workers on the selected LAN, checks their inventory and cluster ID over SSH, installs a controller SSH key, transfers the MUNGE key, generates Slurm configuration once for the full set, distributes it, and starts `slurmd` on the workers.

The N-node QEMU runner automates first boot, test addressing, discovery, batch enrollment, configuration distribution, and a Slurm smoke job. On 2026-10-30, the three-node manifest completed this flow on the Dell 7710 Ubuntu host: one controller and two workers booted, both workers were discovered and enrolled, Slurm registered all three nodes, and one task ran on each node. The workflow does not elect or fail over the controller, drain/remove stale nodes, handle address changes automatically, configure shared NFS storage, or validate physical accelerators. The QEMU result does not qualify physical USB boot or accelerator workloads.

For this run, each guest was configured with 2 vCPUs and 2 GiB memory. Cloud-init reported `done` with no errors on all guests. The Slurm smoke job returned `gc-controller`, `gc-node-02`, and `gc-node-03`, then all QEMU guests shut down cleanly. The test used the private `192.168.77.0/24` QEMU network and the `config/nodes.qemu-3.example.csv` manifest.

The older `build-cloud-image.sh`, `setup-controller.sh`, `configure-node.sh`, `join-compute-node.sh`, and bootstrap package still target the Dell 7710/7680 pair. They remain the tested physical hardware profile. The next generic milestones are DHCP/address-change handling, stale-node draining, controller recovery, and testing with physical laptops on a trusted wired LAN.
