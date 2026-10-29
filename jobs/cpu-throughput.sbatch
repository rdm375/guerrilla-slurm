#!/usr/bin/env bash
#SBATCH --job-name=cpu-throughput
#SBATCH --partition=compute
#SBATCH --time=00:02:00
#SBATCH --output=/cluster/results/cpu-throughput-%j.out
#SBATCH --chdir=/tmp
#SBATCH --export=ALL
set -euo pipefail

threads=${SLURM_CPUS_PER_TASK:?Slurm did not set SLURM_CPUS_PER_TASK}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cat > "$workdir/cpu-bench.cpp" <<'CPP'
#include <omp.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <chrono>

int main() {
    constexpr unsigned long long iterations_per_thread = 100000000ULL;
    const auto start = std::chrono::steady_clock::now();
    double checksum = 0.0;
    int actual_threads = 0;
    #pragma omp parallel reduction(+:checksum)
    {
        #pragma omp single
        { actual_threads = omp_get_num_threads(); }
        float a0=.1f,a1=.2f,a2=.3f,a3=.4f,a4=.5f,a5=.6f,a6=.7f,a7=.8f;
        for (unsigned long long i=0; i<iterations_per_thread; ++i) {
            a0 = std::fma(a0, .9999999f, .0000001f);
            a1 = std::fma(a1, .9999999f, .0000001f);
            a2 = std::fma(a2, .9999999f, .0000001f);
            a3 = std::fma(a3, .9999999f, .0000001f);
            a4 = std::fma(a4, .9999999f, .0000001f);
            a5 = std::fma(a5, .9999999f, .0000001f);
            a6 = std::fma(a6, .9999999f, .0000001f);
            a7 = std::fma(a7, .9999999f, .0000001f);
        }
        checksum += a0+a1+a2+a3+a4+a5+a6+a7;
    }
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    const double flops = (double)iterations_per_thread * actual_threads * 8.0 * 2.0;
    std::printf("Node: %s\nThreads requested/used: %d/%d\n", std::getenv("SLURMD_NODENAME"), omp_get_max_threads(), actual_threads);
    std::printf("CPU FP32 FMA estimate: %.3f GFLOP/s (%.2f seconds; 100M iterations/thread, 8 FMA chains)\n", flops/seconds/1e9, seconds);
    std::printf("Checksum: %.9g\n", checksum);
}
CPP

g++ -O3 -march=native -fopenmp -ffp-contract=off "$workdir/cpu-bench.cpp" -o "$workdir/cpu-bench"
export OMP_NUM_THREADS="$threads" OMP_DYNAMIC=FALSE
echo "Slurm CPUs allocated: $threads"
echo "CPU affinity: $(taskset -pc $$ | sed 's/.*: //')"
"$workdir/cpu-bench"
