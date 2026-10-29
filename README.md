# Guerrilla Cluster: boot idle laptops into Slurm compute nodes

Guerrilla Cluster is a practical kit for putting idle laptops to work: prepare a bootable USB system drive, plug it into a laptop, boot Linux, connect it to the cluster network, and schedule jobs. It is meant for assembling useful compute from available machines without first building a conventional server rack.

The USB drive contains a provisioned Debian system, not just an installer. In this workflow the laptop boots and runs from that external drive; the image-writing step targets the USB device, not the laptop's internal disk. A 100 GiB image is used in the tested setup, so the USB drive must be large enough. Performance and reliability depend on the USB device.

This repository is the tested configuration for one small cluster, not yet a universal one-click node builder. It documents the image build, Slurm controller, shared storage, and node-join steps, then explains what must change to adapt them to other laptops.

The tested compute node exposes its CPU, NVIDIA GPU, and ASUS Hailo-10H AI accelerator to Slurm jobs. The Hailo-10H is sometimes called a TPU here, but it is a Hailo AI accelerator with a software stack distinct from NVIDIA CUDA. For this hardware, Windows did not provide a usable driver/runtime path and WSL could not see the PCIe device, so the node boots native Debian Linux from USB, where the kernel driver, firmware, and HailoRT can access it.

## The tested cluster

| Host | Address | Role | Slurm resources |
|---|---|---|---|
| `dell7710` | `192.168.1.185` | Controller and compute | 8 Slurm CPUs; NVIDIA Quadro M3000M |
| `dell7680` | `192.168.1.199` | Compute | 16 Slurm CPUs; NVIDIA RTX 4090 Laptop; Hailo-10H |

The cluster ID is `lagrange`; Slurm displays it as Lagrange. The 7680 uses wired DHCP and the kit expects the address above. The NFS export, Slurm configuration, smoke tests, and benchmark scripts are tailored to these two hosts. This is a reproducible record of this lab, not a drop-in installer for arbitrary hardware. Change the host-specific settings before adapting it to another cluster.

## Build a Debian USB image on Ubuntu

Build on the native Ubuntu 7710. The cloud-image path is the tested, short route: it starts from Debian's official generic cloud disk, adds this kit's first-boot configuration, and runs the image in QEMU. QEMU validates the operating-system provisioning; it does not pass through the laptop's physical GPU or Hailo card.

Install the host tools:

```sh
sudo apt update
sudo apt install curl openssl cloud-image-utils qemu-utils qemu-system-x86 ovmf
```

The supplied USB SSD is about 119.5 GB. Use a 100 GiB image so it fits. Set the size on the first build; the script does not shrink an existing image:

```sh
USB_IMAGE_SIZE=100G ./build-cloud-image.sh qemu
```

Enter the Linux login name and password when prompted. QEMU boots Debian and cloud-init installs the base packages. Wait for first boot provisioning to finish before shutting down QEMU. The raw disk is `output/dell7680-slurm.raw`; QEMU forwards guest SSH to `localhost:2222`.

The cloud image initially allows SSH password login and gives the install account passwordless sudo. Before copying it to USB, install your SSH public key and verify key login from another terminal while QEMU is running:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 LOGIN@127.0.0.1
ssh -i ~/.ssh/id_ed25519 -p 2222 LOGIN@127.0.0.1
```

Replace `LOGIN` with the account name you entered. After verifying key access, disable SSH password authentication in the guest:

```sh
ssh -p 2222 LOGIN@127.0.0.1 \
  'printf "%s\n" "PasswordAuthentication no" "KbdInteractiveAuthentication no" | sudo tee /etc/ssh/sshd_config.d/00-disable-password-auth.conf >/dev/null && sudo systemctl reload ssh'
```

Shut down QEMU cleanly. Then identify the USB device carefully and write the raw image to the whole device, not a partition:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN
sudo dd if=output/dell7680-slurm.raw of=/dev/disk/by-id/USB_DEVICE_ID \
  bs=16M status=progress conv=fsync
```

Replace `USB_DEVICE_ID` with the verified link under `/dev/disk/by-id/`. This erases the selected device. Do not boot the QEMU raw image onto a machine with data you need to keep.

Boot the 7680 from the USB SSD. The wired network file assumes interface `enp0s31f6` and DHCP; edit `network/05-enp0s31f6.network` before building if the interface name differs. Confirm SSH returns at the expected address before joining it to Slurm.

### Optional custom installer ISO

`build.sh iso` remasters Debian netinst with a preseed and local bootstrap package; `build.sh qemu` launches it against a virtual disk. This path downloads Debian packages during installation and is slower than the cloud image. The unattended preseed path previously stopped for manual installer input, so treat it as experimental and verify it fully in QEMU before relying on it. The working 7680 was provisioned through the Debian cloud-image route above. The ISO does not configure the live controller, transfer the MUNGE secret, or provide physical GPU/Hailo testing. It assumes a QEMU virtio disk at `/dev/vda`; do not boot it directly on a physical machine unless you have verified the target-disk selection and understand that installation erases that disk.

## Configure the controller and join the 7680

Run these commands on a fresh Ubuntu installation on `dell7710`. Review `cluster.env` first. `setup-controller.sh` installs Slurm, MUNGE, and the NFS server; writes the two-node Slurm configuration; creates `/srv/slurm-share/{projects,data,results,software}`; mounts it locally at `/cluster`; and, if UFW is already active, opens the required ports from the configured compute address. It changes system configuration and restarts Slurm services.

```sh
sudo ./setup-controller.sh
```

The script generates a MUNGE key and stages it with the Slurm configuration under `/root/slurm-node-share`. The key is a cluster secret. Never commit it, put it in the ISO, or copy it into a public image.

After the Debian 7680 has booted, join it from the controller using the Linux account created during image setup:

```sh
./join-compute-node.sh LOGIN 192.168.1.199
```

The account needs SSH access to the compute node and permission to use `sudo` there. The join script transfers the MUNGE key and Slurm configuration over SSH, then starts the node bootstrap service. That service configures NFS, installs the Hailo stack, and starts `slurmd`. The Hailo installation downloads the pinned HailoRT 5.4.0 driver/runtime sources and matching Hailo-10H firmware from upstream; the node needs Internet access. The kernel module is built for the running kernel. After a kernel upgrade, rerun the Hailo installer and verify that the module loads. Secure Boot must be disabled unless you sign and enroll the Hailo module.

The shared filesystem is a dedicated NFSv4 export at `/srv/slurm-share` on the controller, mounted at `/cluster` on both machines. It is separate from Syncthing. Use `/cluster/projects` for code, `/cluster/data` for inputs, `/cluster/results` for outputs, and `/cluster/software` for shared models and environments. Keep temporary build files on local disks. NFS permissions use numeric IDs, so the same user should have matching UID/GID on both machines.

### Hailo device permissions

The current bootstrap installs the driver and firmware but does not create the shared `hailo` group or its udev rule. The tested cluster uses GID 4500 on both hosts so the submitter and worker have consistent device access. Confirm that GID is free on both machines before using it; choose another unused GID and use it consistently if necessary.

On the controller and compute node, create the same group and add the submitting login:

```sh
getent group hailo || sudo groupadd --system --gid 4500 hailo
sudo usermod -aG hailo "$(id -un)"
```

On the 7680, install the device rule and apply it to the current device:

```sh
printf '%s\n' 'KERNEL=="h1x-*", GROUP="hailo", MODE="0660"' |
  sudo tee /etc/udev/rules.d/99-hailo.rules
sudo udevadm control --reload-rules
sudo chgrp hailo /dev/h1x-0
sudo chmod 0660 /dev/h1x-0
sudo systemctl restart slurmd
```

Start a new login session after changing group membership. Check `getent group hailo` on both hosts and `ls -l /dev/h1x-0` on the 7680. To submit a Hailo job from the controller with the new group active, use `sg hailo -c 'sbatch ...'` or log out and back in.

## Check the cluster

After the compute node has joined, enable accounting once on a fresh controller. The smoke tests and benchmark wrappers use `sacct` to wait for jobs and record their allocations:

```sh
sudo ./enable-accounting.sh
```

Run the built-in health checks from the controller:

```sh
bash ./validate-cluster.sh
./accounting-smoke-test.sh
./gpu-smoke-test.sh
./cpu-smoke-test.sh
./hailo-smoke-test.sh
```

The validator checks the worker's IPv4 address and daemons, Slurm node state, shared-storage read/write, CPU scheduling, RTX 4090 visibility, and Hailo device scan. The GPU smoke test checks Slurm allocation and CUDA driver visibility; it does not run a sustained CUDA benchmark. The CPU smoke test confirms a multithreaded OpenMP allocation. The Hailo smoke test runs a real Hailo-10H EfficientNet-Lite0 HEF benchmark. A device scan alone proves access, not application accuracy.

For a physical reboot check, reboot the 7680 with no running jobs, wait for SSH to return, and run `bash ./validate-cluster.sh` again. Useful diagnostics on the worker are:

```sh
sudo journalctl -b -u slurm-node-bootstrap --no-pager -n 80
sudo journalctl -b -u slurmd --no-pager -n 40
sudo journalctl -b -k --no-pager | grep -i hailo
```

## Benchmark throughput

Run the cluster benchmark when no other jobs are competing for CPU, GPU, power, cooling, or memory bandwidth:

```sh
./benchmark-cluster.sh
```

The runner submits separate sequential workloads for the 7710 CPU, 7680 CPU, each NVIDIA GPU, and the Hailo-10H. It writes a complete log and a readable Markdown scorecard under `/cluster/results/`. The CPU and GPU scores are FP32 FMA throughput estimates. NVIDIA memory bandwidth is measured by a device-to-device copy workload. Hailo is reported as EfficientNet-Lite0 images per second. The scorecard sums the individual CPU/GPU peak readings for convenience, but those sums are not simultaneous cluster throughput. The suite does not measure CPU RAM bandwidth or Hailo TOPS. These synthetic numbers are comparison points, not application performance guarantees.

The CPU benchmark uses a fixed 100-million-iteration workload per Slurm CPU; the earlier 500-million-iteration workload exceeded its two-minute batch time limit. Ensure `g++` and OpenMP are installed on every CPU node you benchmark. The Hailo test downloads the Hailo Model Zoo v5.4.0 EfficientNet-Lite0 HEF. A previous run on this cluster measured about 1,630 images/s for that model; results vary with temperature, power, software, and device configuration. No CPU/GPU FLOP or memory-bandwidth result is claimed here until the corresponding benchmark stage completes on the target machine.

Reports are experimental records. Keep the raw log and scorecard together, note the kit revision and driver/runtime versions, and avoid comparing measurements made with different workloads or thermal conditions.

## Run numerical experiments

Put source code and shared input data under `/cluster/projects` and `/cluster/data`. Submit CPU work with `sbatch`; request CPUs explicitly and direct logs to `/cluster/results`. Slurm job arrays are useful for independent parameter sweeps because each array task can process one experiment case:

```bash
#!/usr/bin/env bash
#SBATCH --job-name=parameter-sweep
#SBATCH --partition=compute
#SBATCH --array=0-99%8
#SBATCH --cpus-per-task=8
#SBATCH --chdir=/cluster/projects/my-study
#SBATCH --output=/cluster/results/sweep-%A_%a.out

./build/experiment --case "$SLURM_ARRAY_TASK_ID" --threads "$SLURM_CPUS_PER_TASK"
```

Save this as `/cluster/projects/my-study/run-sweep.sbatch`, then submit it with:

```sh
sbatch /cluster/projects/my-study/run-sweep.sbatch
```

The `%8` array limit runs at most eight parameter cases concurrently. Choose a concurrency limit that leaves enough memory and cooling headroom. Account for results with `sacct -M lagrange --format=JobID,JobName,State,Elapsed,AllocTRES`.

For GPU numerical work, request the model-specific GRES and make the program use the CUDA libraries installed on that node:

```sh
srun --immediate=10 -N1 -n1 -w dell7680 \
  --gres=gpu:rtx_4090:1 --chdir=/cluster/projects/my-study ./build/gpu-experiment
```

For Hailo, submit an HailoRT application with a model compiled for Hailo-10H and reserve its GRES:

```sh
sg hailo -c 'sbatch --gres=hailo10h:1 /cluster/projects/my-study/run-hailo.sbatch'
```

Hailo is an inference accelerator, not a general CUDA device. Applications need a compatible HEF plus model-specific preprocessing and output interpretation. The included `hailo-classify-image.sh IMAGE [HEF]` example classifies one image with EfficientNet-Lite0; its resize path is a functional demonstration, not an accuracy-qualified model pipeline. The included smoke tests and benchmark jobs are examples to adapt, not a numerical experiment framework.

## Add another compute node

The current scripts do **not** add arbitrary nodes with one command. `setup-controller.sh`, `configure-node.sh`, the default `join-compute-node.sh` workflow, and the benchmark/smoke-test scripts encode the Dell 7710/7680 names, addresses, resources, or accelerator layout. `configure-node.sh` specifically requires both a working NVIDIA GPU and a Hailo device. Do not use it unchanged for a CPU-only or differently equipped machine.

To extend this cluster safely:

1. Choose a unique hostname and stable IPv4 address. Install Debian or Ubuntu on the new machine, install and validate its local accelerator drivers first, and make sure its Slurm version is compatible with the controller.
2. Create the same Slurm login with matching numeric UID/GID. Install MUNGE and Slurm; transfer the controller's MUNGE key securely. Never put the key in Git, an ISO, or a public cloud image.
3. On the new host, capture its topology with `sudo slurmd -C`. Add a `NodeName` entry to `/etc/slurm/slurm.conf` using that CPU topology and memory below the machine's physical total. Add its name to the `compute` partition's `Nodes=` list.
4. Register each accelerator in `Gres=` and `/etc/slurm/gres.conf`. NVIDIA devices use NVML autodetection and a type matching the GPU model; Hailo devices need a `hailo10h` GRES line for the correct `/dev/h1x-*` path, working firmware/runtime, matching group permissions, and a tested Hailo-compatible workload.
5. Add the hostname/IP mapping on the controller and all nodes. Add the new client IP to the NFS export in `/etc/exports.d/slurm.exports`, run `sudo exportfs -ra`, and allow the necessary Slurm and NFS traffic in any active host firewall. This cluster uses controller port 6817, node port 6818, `SrunPortRange=60001-63000`, and NFSv4 TCP port 2049.
6. Install the same `slurm.conf`, `gres.conf`, and `cgroup.conf` on every Slurm host. Run `sudo scontrol reconfigure` on the controller and restart `slurmd` on the new node. Resolve any `INVAL`, `DRAIN`, topology, or GRES mismatch before resuming the node.
7. Verify `sinfo -N -o '%N %t %G'`, then run a CPU task and one Slurm allocation for each registered accelerator. Add the new hardware to the benchmark scripts if you want it included in the cluster scorecard.

The controller setup script rewrites its two-node configuration, and the current NFS export is limited to the 7680 address. Make corresponding changes to those scripts before rerunning setup or using this repository as an automated multi-node installer.

## Backups and accounting

`enable-accounting.sh` installs MariaDB and SlurmDBD on the controller. The accounting smoke test submits a small job and confirms its final record with `sacct`. Use `backup-controller.sh` with a separately mounted backup disk to save controller configuration/state, `/cluster` data, and the accounting database when present:

```sh
sudo ./backup-controller.sh /path/to/mounted/backup-disk
```

The backup contains the MUNGE key and cluster data. Keep it encrypted or physically secured; it is not suitable for a public or shared destination. Accounting history lives on the controller's MariaDB database and should be backed up before upgrades.

## Repository cleanup and publication notes

The ISO builder creates the `slurm-node-bootstrap` Debian package from `packaging/` at build time. Do not commit the generated `.deb`, raw images, ISO files, QEMU work trees, logs, model inputs, passwords, or MUNGE keys. The `.gitignore` excludes common generated and private files.

The ISO builder follows the SynthOS remaster pattern: start from an official Debian image, add the installer configuration and local bootstrap package, then rebuild the bootable media. It does not use Simple-CDD. The two installer routes remain separate: the Debian cloud image is the tested USB route, while the custom ISO is experimental.

The cloud-init image grants the provisioning login passwordless sudo and allows SSH password authentication until you apply the hardening steps above. Treat the cluster as trusted-LAN infrastructure, keep it off public networks, and review sudo policy before production use.

This archive does not include a `LICENSE` file. Choose and add a license before publishing it as an open-source GitHub project.
