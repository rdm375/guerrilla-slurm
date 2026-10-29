#!/usr/bin/env bash
#SBATCH --job-name=cpu-multithread-smoke
#SBATCH --partition=compute
#SBATCH --nodelist=dell7680
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:02:00
#SBATCH --chdir=/tmp
#SBATCH --output=/cluster/results/cpu-smoke-%j.out

set -euo pipefail

SOURCE="/tmp/cpu-smoke-${SLURM_JOB_ID}.cpp"
BINARY="/tmp/cpu-smoke-${SLURM_JOB_ID}"
trap 'rm -f "$SOURCE" "$BINARY"' EXIT

cat > "$SOURCE" <<'CPP'
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <omp.h>
#include <sched.h>

int main() {
    const char *cpus_env = std::getenv("SLURM_CPUS_PER_TASK");
    const int requested = cpus_env ? std::atoi(cpus_env) : 0;
    if (requested < 2) {
        std::cerr << "Slurm did not allocate at least two CPUs to this job.\n";
        return 1;
    }

    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    if (sched_getaffinity(0, sizeof(affinity), &affinity) != 0) {
        std::perror("sched_getaffinity");
        return 1;
    }
    const int allowed_cpus = CPU_COUNT(&affinity);
    if (allowed_cpus < requested) {
        std::cerr << "Slurm requested " << requested << " CPUs but affinity allows only "
                  << allowed_cpus << ".\n";
        return 1;
    }

    omp_set_dynamic(0);
    omp_set_num_threads(requested);
    int actual_threads = 0;
    std::uint64_t checksum = 0;
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::seconds(3);

#pragma omp parallel reduction(+ : checksum)
    {
#pragma omp single
        actual_threads = omp_get_num_threads();
        std::uint64_t value = 0x9e3779b97f4a7c15ULL ^
                              static_cast<std::uint64_t>(omp_get_thread_num() + 1);
        do {
            value = value * 6364136223846793005ULL + 1442695040888963407ULL;
            checksum += value >> 17;
        } while (std::chrono::steady_clock::now() < deadline);
    }

    const double elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    std::cout << "Slurm CPUs per task: " << requested << '\n'
              << "CPU affinity allows: " << allowed_cpus << '\n'
              << "OpenMP worker threads launched: " << actual_threads << '\n'
              << "Parallel compute elapsed: " << elapsed << " s\n"
              << "Checksum: " << checksum << '\n';

    if (actual_threads != requested || checksum == 0) {
        std::cerr << "OpenMP thread count or compute check failed.\n";
        return 1;
    }
    std::cout << "Multithreaded CPU allocation and compute: PASS\n";
    return 0;
}
CPP

g++ -O2 -fopenmp "$SOURCE" -o "$BINARY"
"$BINARY"
