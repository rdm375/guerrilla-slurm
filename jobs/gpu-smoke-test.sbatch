#!/usr/bin/env bash
#SBATCH --job-name=gpu-smoke
#SBATCH --partition=compute
#SBATCH --nodelist=dell7680
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:02:00
#SBATCH --gres=gpu:rtx_4090:1
#SBATCH --chdir=/tmp
#SBATCH --output=/cluster/results/gpu-smoke-%j.out

set -euo pipefail

echo "RTX 4090 Slurm GPU smoke test"
echo "Node: $(hostname -s)"
echo "Job: ${SLURM_JOB_ID}"
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-unset}"
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv,noheader

python3 - <<'PY'
import ctypes

cuda = ctypes.CDLL("libcuda.so.1")

def check(result, operation):
    if result != 0:
        raise RuntimeError(f"CUDA driver call {operation} failed with code {result}")

cuda.cuInit.argtypes = [ctypes.c_uint]
cuda.cuInit.restype = ctypes.c_int
check(cuda.cuInit(0), "cuInit")

count = ctypes.c_int()
cuda.cuDeviceGetCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
cuda.cuDeviceGetCount.restype = ctypes.c_int
check(cuda.cuDeviceGetCount(ctypes.byref(count)), "cuDeviceGetCount")
if count.value < 1:
    raise RuntimeError("CUDA driver initialized but exposed no GPU to this Slurm job")

device = ctypes.c_int()
cuda.cuDeviceGet.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_int]
cuda.cuDeviceGet.restype = ctypes.c_int
check(cuda.cuDeviceGet(ctypes.byref(device), 0), "cuDeviceGet")

name = ctypes.create_string_buffer(256)
cuda.cuDeviceGetName.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
cuda.cuDeviceGetName.restype = ctypes.c_int
check(cuda.cuDeviceGetName(name, len(name), device.value), "cuDeviceGetName")

major = ctypes.c_int()
minor = ctypes.c_int()
cuda.cuDeviceComputeCapability.argtypes = [
    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.c_int
]
cuda.cuDeviceComputeCapability.restype = ctypes.c_int
check(
    cuda.cuDeviceComputeCapability(ctypes.byref(major), ctypes.byref(minor), device.value),
    "cuDeviceComputeCapability",
)
print(f"CUDA driver API sees {count.value} GPU(s).")
print(f"Device 0: {name.value.decode()} (compute capability {major.value}.{minor.value})")
PY

echo "GPU Slurm allocation and CUDA driver visibility: PASS"
