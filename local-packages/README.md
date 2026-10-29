# Optional local Debian packages

Place additional `.deb` packages here before running `./build.sh iso`.
The builder copies them into the ISO's local APT repository and installs them
during unattended installation. Use packages built for Debian 13 amd64 or
architecture `all`.

Hailo support no longer depends on supplying vendor `.deb` files: the bootstrap
builds the pinned Hailo 5.4.0 driver/runtime and installs its matching Hailo-10H
firmware after it receives the controller configuration.

Do not put the cluster MUNGE key or Slurm configuration in this directory.
