#!/usr/bin/env python3
"""CUDA Driver API PTX microbenchmarks; no CUDA toolkit or Python GPU package needed."""

from __future__ import annotations

import ctypes as C
import os
import statistics
import time


def ptx_source() -> bytes:
    fma_lines = [
        ".version 6.0",
        ".target sm_52",
        ".address_size 64",
        ".visible .entry fma_bench(.param .u64 output, .param .u32 iterations)",
        "{",
        "  .reg .pred %p<1>;",
        "  .reg .b32 %r<8>;",
        "  .reg .b64 %rd<4>;",
        "  .reg .f32 %f<21>;",
        "  mov.u32 %r0, %ctaid.x;",
        "  mov.u32 %r1, %ntid.x;",
        "  mov.u32 %r2, %tid.x;",
        "  mad.lo.u32 %r3, %r0, %r1, %r2;",
        "  ld.param.u64 %rd0, [output];",
        "  ld.param.u32 %r4, [iterations];",
        "  mov.u32 %r5, 0;",
        "  mov.f32 %f0, 0.999999;",
        "  mov.f32 %f1, 0.000001;",
    ]
    for i in range(16):
        fma_lines.append(f"  mov.f32 %f{i + 4}, {0.125 + i * 0.03125};")
    fma_lines += [
        "FMA_LOOP:",
        "  setp.ge.u32 %p0, %r5, %r4;",
        "  @%p0 bra FMA_DONE;",
    ]
    for i in range(16):
        reg = i + 4
        fma_lines.append(f"  fma.rn.f32 %f{reg}, %f{reg}, %f0, %f1;")
    fma_lines += [
        "  add.u32 %r5, %r5, 1;",
        "  bra FMA_LOOP;",
        "FMA_DONE:",
        "  mul.wide.u32 %rd1, %r3, 4;",
        "  add.u64 %rd2, %rd0, %rd1;",
    ]
    for i in range(15):
        if i == 0:
            fma_lines.append(f"  add.f32 %f20, %f4, %f5;")
        else:
            fma_lines.append(f"  add.f32 %f20, %f20, %f{i + 5};")
    fma_lines += [
        "  st.global.f32 [%rd2], %f20;",
        "  ret;",
        "}",
        ".visible .entry copy_bench(.param .u64 source, .param .u64 destination, .param .u32 elements)",
        "{",
        "  .reg .pred %p<1>;",
        "  .reg .b32 %r<8>;",
        "  .reg .b64 %rd<6>;",
        "  mov.u32 %r0, %ctaid.x;",
        "  mov.u32 %r1, %ntid.x;",
        "  mov.u32 %r2, %tid.x;",
        "  mad.lo.u32 %r3, %r0, %r1, %r2;",
        "  ld.param.u32 %r4, [elements];",
        "  setp.ge.u32 %p0, %r3, %r4;",
        "  @%p0 bra COPY_DONE;",
        "  ld.param.u64 %rd0, [source];",
        "  ld.param.u64 %rd1, [destination];",
        "  mul.wide.u32 %rd2, %r3, 4;",
        "  add.u64 %rd3, %rd0, %rd2;",
        "  add.u64 %rd4, %rd1, %rd2;",
        "  ld.global.cg.u32 %r5, [%rd3];",
        "  st.global.u32 [%rd4], %r5;",
        "COPY_DONE:",
        "  ret;",
        "}",
    ]
    return ("\n".join(fma_lines) + "\n").encode()


def main() -> None:
    cuda = C.CDLL("libcuda.so.1")

    def bind(name: str, argtypes: list[object]) -> object:
        fn = getattr(cuda, name)
        fn.argtypes = argtypes
        fn.restype = C.c_int
        return fn

    def check(result: int, operation: str) -> None:
        if result != 0:
            raise RuntimeError(f"CUDA driver call {operation} failed with code {result}")

    cu_init = bind("cuInit", [C.c_uint])
    cu_device_get_count = bind("cuDeviceGetCount", [C.POINTER(C.c_int)])
    cu_device_get = bind("cuDeviceGet", [C.POINTER(C.c_int), C.c_int])
    cu_device_name = bind("cuDeviceGetName", [C.c_char_p, C.c_int, C.c_int])
    cu_compute_cap = bind(
        "cuDeviceComputeCapability",
        [C.POINTER(C.c_int), C.POINTER(C.c_int), C.c_int],
    )
    cu_ctx_create = bind("cuCtxCreate_v2", [C.POINTER(C.c_void_p), C.c_uint, C.c_int])
    cu_ctx_destroy = bind("cuCtxDestroy_v2", [C.c_void_p])
    cu_ctx_sync = bind("cuCtxSynchronize", [])
    cu_module_load = bind("cuModuleLoadData", [C.POINTER(C.c_void_p), C.c_void_p])
    cu_module_unload = bind("cuModuleUnload", [C.c_void_p])
    cu_module_get_function = bind(
        "cuModuleGetFunction", [C.POINTER(C.c_void_p), C.c_void_p, C.c_char_p]
    )
    cu_mem_alloc = bind("cuMemAlloc_v2", [C.POINTER(C.c_uint64), C.c_size_t])
    cu_mem_free = bind("cuMemFree_v2", [C.c_uint64])
    cu_memset = bind("cuMemsetD8_v2", [C.c_uint64, C.c_ubyte, C.c_size_t])
    cu_memcpy_dtoh = bind("cuMemcpyDtoH_v2", [C.c_void_p, C.c_uint64, C.c_size_t])
    cu_launch = bind(
        "cuLaunchKernel",
        [
            C.c_void_p,
            C.c_uint, C.c_uint, C.c_uint,
            C.c_uint, C.c_uint, C.c_uint,
            C.c_uint, C.c_void_p,
            C.POINTER(C.c_void_p), C.POINTER(C.c_void_p),
        ],
    )

    check(cu_init(0), "cuInit")
    device_count = C.c_int()
    check(cu_device_get_count(C.byref(device_count)), "cuDeviceGetCount")
    if device_count.value < 1:
        raise RuntimeError("CUDA driver exposed no GPU to this Slurm job")
    device = C.c_int()
    check(cu_device_get(C.byref(device), 0), "cuDeviceGet")
    name = C.create_string_buffer(256)
    check(cu_device_name(name, len(name), device.value), "cuDeviceGetName")
    major, minor = C.c_int(), C.c_int()
    check(cu_compute_cap(C.byref(major), C.byref(minor), device.value), "cuDeviceComputeCapability")

    print("CUDA Driver API throughput estimate")
    print(f"Node: {os.uname().nodename}")
    print(f"CUDA_VISIBLE_DEVICES: {os.environ.get('CUDA_VISIBLE_DEVICES', 'unset')}")
    print(f"Device: {name.value.decode()} (compute capability {major.value}.{minor.value})")

    context = C.c_void_p()
    check(cu_ctx_create(C.byref(context), 0, device.value), "cuCtxCreate")
    module = C.c_void_p()
    output_ptr = C.c_uint64()
    source_ptr, destination_ptr = C.c_uint64(), C.c_uint64()
    ptx = C.create_string_buffer(ptx_source())
    try:
        check(cu_module_load(C.byref(module), C.cast(ptx, C.c_void_p)), "cuModuleLoadData")
        fma = C.c_void_p()
        copy = C.c_void_p()
        check(cu_module_get_function(C.byref(fma), module, b"fma_bench"), "cuModuleGetFunction(fma)")
        check(cu_module_get_function(C.byref(copy), module, b"copy_bench"), "cuModuleGetFunction(copy)")

        block_size = 256
        fma_threads = 1 << 20
        fma_blocks = fma_threads // block_size
        fma_iterations = 8192
        output_bytes = fma_threads * C.sizeof(C.c_float)
        check(cu_mem_alloc(C.byref(output_ptr), output_bytes), "cuMemAlloc(fma output)")
        iterations_arg = C.c_uint32(fma_iterations)
        fma_args = (C.c_void_p * 2)(
            C.cast(C.byref(output_ptr), C.c_void_p),
            C.cast(C.byref(iterations_arg), C.c_void_p),
        )

        def launch(function: C.c_void_p, grid: int, args: object) -> None:
            check(
                cu_launch(
                    function, grid, 1, 1, block_size, 1, 1, 0, None,
                    C.cast(args, C.POINTER(C.c_void_p)), None,
                ),
                "cuLaunchKernel",
            )

        launch(fma, fma_blocks, fma_args)
        check(cu_ctx_sync(), "cuCtxSynchronize(warmup)")
        fma_times = []
        for _ in range(5):
            start = time.perf_counter()
            launch(fma, fma_blocks, fma_args)
            check(cu_ctx_sync(), "cuCtxSynchronize(fma)")
            fma_times.append(time.perf_counter() - start)
        output = C.create_string_buffer(output_bytes)
        check(cu_memcpy_dtoh(C.cast(output, C.c_void_p), output_ptr.value, output_bytes), "cuMemcpyDtoH(fma)")
        fma_checksum = sum(C.cast(output, C.POINTER(C.c_float))[i] for i in range(0, fma_threads, 4096))
        if not fma_checksum:
            raise RuntimeError("CUDA FMA kernel produced an empty output")
        fma_seconds = statistics.median(fma_times)
        fma_count = fma_threads * fma_iterations * 16 * 2
        print(f"FP32 FMA estimate: {fma_count / fma_seconds / 1e12:.3f} TFLOP/s (median of 5 runs)")

        copy_bytes = 128 * 1024 * 1024
        elements = copy_bytes // C.sizeof(C.c_uint32)
        check(cu_mem_alloc(C.byref(source_ptr), copy_bytes), "cuMemAlloc(copy source)")
        check(cu_mem_alloc(C.byref(destination_ptr), copy_bytes), "cuMemAlloc(copy destination)")
        check(cu_memset(source_ptr.value, 0x5A, copy_bytes), "cuMemset(copy source)")
        elements_arg = C.c_uint32(elements)
        copy_args = (C.c_void_p * 3)(
            C.cast(C.byref(source_ptr), C.c_void_p),
            C.cast(C.byref(destination_ptr), C.c_void_p),
            C.cast(C.byref(elements_arg), C.c_void_p),
        )
        copy_blocks = (elements + block_size - 1) // block_size
        launch(copy, copy_blocks, copy_args)
        check(cu_ctx_sync(), "cuCtxSynchronize(copy warmup)")
        copy_repetitions = 5
        copy_times = []
        for _ in range(3):
            start = time.perf_counter()
            for _ in range(copy_repetitions):
                launch(copy, copy_blocks, copy_args)
            check(cu_ctx_sync(), "cuCtxSynchronize(copy)")
            copy_times.append(time.perf_counter() - start)
        copy_seconds = statistics.median(copy_times)
        effective_gbps = (2 * copy_bytes * copy_repetitions) / copy_seconds / 1e9
        print(f"Device-memory copy estimate: {effective_gbps:.1f} GB/s (median of 3 runs)")
        print("GPU compute and device-memory throughput workload: PASS")
    finally:
        cu_ctx_sync()
        if module.value:
            cu_module_unload(module)
        if output_ptr.value:
            cu_mem_free(output_ptr.value)
        if source_ptr.value:
            cu_mem_free(source_ptr.value)
        if destination_ptr.value:
            cu_mem_free(destination_ptr.value)
        cu_ctx_destroy(context)


if __name__ == "__main__":
    main()
