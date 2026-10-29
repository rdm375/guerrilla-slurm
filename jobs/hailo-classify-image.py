#!/usr/bin/env python3
"""Run one ImageNet classification inference on the Hailo-10H."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image
from hailo_platform import FormatType, VDevice


def main() -> None:
    if len(sys.argv) != 4:
        raise RuntimeError("Usage: hailo-classify-image.py IMAGE HEF IMAGENET_LABELS")

    image_path, hef_path, labels_path = map(Path, sys.argv[1:])
    image = Image.open(image_path).convert("RGB").resize(
        (224, 224), Image.Resampling.BILINEAR
    )
    # HailoRT requires a writable input buffer; Pillow-backed NumPy views are read-only.
    input_tensor = np.array(image, dtype=np.uint8, copy=True)
    labels = labels_path.read_text(encoding="utf-8").splitlines()

    print("Hailo-10H EfficientNet-Lite0 image inference")
    print(f"Node: {Path('/etc/hostname').read_text().strip()}")
    print(f"Image: {image_path}")
    print(f"Input: RGB UINT8 {input_tensor.shape}")
    print(f"HEF: {hef_path}")

    params = VDevice.create_params()
    params.group_id = "SHARED"
    device = VDevice(params)
    infer_model = device.create_infer_model(str(hef_path))
    infer_model.set_batch_size(1)
    infer_model.input().set_format_type(FormatType.UINT8)
    infer_model.output().set_format_type(FormatType.FLOAT32)
    output_name = infer_model.output_names[0]
    output_buffer = np.empty(infer_model.output(output_name).shape, dtype=np.float32)

    with infer_model.configure() as configured_model:
        bindings = configured_model.create_bindings(
            output_buffers={output_name: output_buffer}
        )
        bindings.input().set_buffer(input_tensor)
        completion = []

        def on_complete(completion_info):
            completion.append(completion_info)

        configured_model.wait_for_async_ready(timeout_ms=10000)
        job = configured_model.run_async([bindings], on_complete)
        job.wait(30000)
        if completion and completion[0].exception:
            raise RuntimeError(f"Hailo inference failed: {completion[0].exception}")
        scores = np.asarray(bindings.output(output_name).get_buffer()).reshape(-1)

    print("Top 5 ImageNet predictions:")
    for index in np.argsort(scores)[-5:][::-1]:
        label = labels[index] if index < len(labels) else f"class_{index}"
        print(f"  {label}: {float(scores[index]):.6f}")


if __name__ == "__main__":
    main()
