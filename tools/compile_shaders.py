"""Translate extracted Xbox 360 shaders to SPIR-V for renderer testing."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess


def compile_shader(source, output, translator, header, dxc):
    name = source.stem
    stage = "ps_6_0" if name.startswith("pixel-") else "vs_6_0"
    hlsl = output / f"{name}.hlsl"
    spirv = output / f"{name}.spv"
    hlsl.unlink(missing_ok=True)
    spirv.unlink(missing_ok=True)
    commands = [
        [translator, source, hlsl, header],
        [dxc, "-E", "main", "-T", stage, "-HV", "2021", "-all-resources-bound",
         "-spirv", "-fvk-use-dx-layout", "-Fo", spirv, hlsl],
    ]
    for command in commands:
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    errors="replace", timeout=45, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            return name, str(error)
        if result.returncode:
            return name, result.stderr.strip() or result.stdout.strip() or str(result.returncode)
    if not spirv.is_file() or spirv.read_bytes()[:4] != b"\x03\x02\x23\x07":
        return name, "Compiler did not produce SPIR-V"
    return name, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--translator", required=True, type=Path)
    parser.add_argument("--header", required=True, type=Path)
    parser.add_argument("--dxc", required=True, type=Path)
    args = parser.parse_args()
    shaders = sorted(args.source.glob("pixel-*.xsh")) + sorted(args.source.glob("vertex-*.xsh"))
    if not shaders:
        parser.error("No extracted shaders found. Run verify_shaders.py with --extract first.")
    for dependency in (args.translator, args.header, args.dxc):
        if not dependency.is_file():
            parser.error(f"Missing dependency: {dependency}")

    args.output.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(
            lambda shader: compile_shader(shader, args.output, args.translator, args.header, args.dxc),
            shaders,
        ))
    failures = [(name, error) for name, error in results if error is not None]
    (args.output / "failures.log").write_text(
        "\n\n".join(f"{name}\n{error}" for name, error in failures), encoding="utf-8"
    )
    print(f"Compiled {len(shaders) - len(failures)}/{len(shaders)} shaders to SPIR-V.")
    if failures:
        print(f"See {args.output / 'failures.log'} for compiler errors.")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
