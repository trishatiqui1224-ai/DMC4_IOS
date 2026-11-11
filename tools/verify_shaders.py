"""Decode and verify the XFB bundles in DMC4's Xbox 360 shader.arc."""

import argparse
import ctypes
import os
from pathlib import Path
import struct


def decode_archive(path, decompress):
    archive = path.read_bytes()
    if len(archive) < 8 or archive[:6] != b"\0CRA\0\x11":
        raise ValueError("Expected an Xbox 360 MT Framework ARC v0x11")
    count, = struct.unpack_from(">H", archive, 6)
    table_end = 8 + count * 80
    if table_end > len(archive):
        raise ValueError("Truncated ARC entry table")

    for index in range(count):
        entry = 8 + index * 80
        name = archive[entry:entry + 64].split(b"\0", 1)[0].decode("ascii")
        kind, packed, size_field, offset = struct.unpack_from(">4I", archive, entry + 64)
        end = offset + packed
        if offset < table_end or end > len(archive):
            raise ValueError(f"{name}: entry is outside the archive")
        if kind != 0x4E32817C:
            continue

        expected = size_field >> 3
        decoded_size = 0
        chunks = []
        while offset < end:
            extended = archive[offset] == 0xFF
            header_size = 5 if extended else 2
            if end - offset < header_size:
                raise ValueError(f"{name}: truncated LZX frame header")
            if extended:
                plain, length = struct.unpack_from(">HH", archive, offset + 1)
            else:
                plain = 0x8000
                length, = struct.unpack_from(">H", archive, offset)
            offset += header_size
            if not (0 < plain <= 0x8000 and 0 < length <= end - offset):
                raise ValueError(f"{name}: invalid LZX frame")
            chunks.append(archive[offset:offset + length])
            offset += length
            decoded_size += plain
        if not (0 < decoded_size == expected):
            raise ValueError(f"{name}: incorrect decoded size")

        stream = b"".join(chunks)
        output = ctypes.create_string_buffer(expected)
        status = decompress(stream, len(stream), output, expected, 1 << 17, None, 0)
        if status != 0 or output.raw[:4] != b"\0XFB":
            raise ValueError(f"{name}: invalid XFB payload (LZX status {status})")
        yield name, output.raw


def shader_containers(bundle):
    """Parse Capcom XFB sections and reconstruct standalone 0x102A11 containers."""
    if len(bundle) < 12:
        raise ValueError("Truncated XFB header")
    magic, version, section_count = struct.unpack_from(">4sHH", bundle, 0)
    if magic != b"\0XFB" or version != 0x2003:
        raise ValueError(f"Unsupported XFB header: {magic!r} v0x{version:x}")
    import_count, = struct.unpack_from(">I", bundle, 8)
    section_table = 12 + import_count * 8
    cursor = section_table + section_count * 16
    if cursor > len(bundle):
        raise ValueError("Truncated XFB section table")

    for index in range(section_count):
        _, virt_size, phys_size, _ = struct.unpack_from(">4I", bundle, section_table + index * 16)
        if cursor + virt_size + phys_size > len(bundle):
            raise ValueError(f"Section {index} extends past end of XFB bundle")
        virt_blob = bundle[cursor:cursor + virt_size]
        phys_blob = bundle[cursor + virt_size:cursor + virt_size + phys_size]
        cursor += virt_size + phys_size

        offset = 0
        pb_offset = 0
        while offset + 36 <= len(virt_blob):
            if virt_blob[offset:offset + 3] == b"\x10\x2A\x11":
                flags, svirt, sphys, _, constants, definitions, shader, tail1, tail2 = (
                    struct.unpack_from(">9I", virt_blob, offset)
                )
                if (svirt >= 36 and sphys > 0 and offset + svirt <= len(virt_blob)
                        and 36 <= shader <= svirt - 24 and constants < svirt and definitions < svirt
                        and tail1 == 0 and tail2 == 0):
                    if pb_offset + sphys > len(phys_blob):
                        raise ValueError(f"Section {index}: container physical range out of bounds")
                    yield ("vertex" if flags & 1 else "pixel"), (
                        virt_blob[offset:offset + svirt] + phys_blob[pb_offset:pb_offset + sphys]
                    )
                    pb_offset += (sphys + 31) & ~31
                    offset += svirt
                    continue
            offset += 4
        if pb_offset != len(phys_blob):
            raise ValueError(f"Section {index}: consumed {pb_offset} physical bytes of {len(phys_blob)}")

    if cursor != len(bundle):
        raise ValueError(f"Unparsed trailing bytes in XFB bundle ({len(bundle) - cursor})")


def shader_microcode(container):
    """Read the Xenos instruction stream without relying on reflection metadata."""
    _, virtual_size, physical_size, _, _, _, shader_offset = struct.unpack_from(">7I", container)
    if shader_offset + 24 > virtual_size:
        raise ValueError("Shader descriptor extends beyond the virtual segment")
    offset, size = struct.unpack_from(">2I", container, shader_offset)
    if not size or size % 12 or offset % 4 or offset + size > physical_size:
        raise ValueError("Invalid Xenos microcode range")
    start = virtual_size + offset
    return container[start:start + size]


def _vfetch_slots(dwords):
    """Return instruction slot indices that execute a Xenos kVertexFetch instruction."""
    cf_bound = len(dwords) // 3
    fetch_slots = set()
    i = 0
    while i < cf_bound:
        d0, d1, d2 = dwords[i * 3:i * 3 + 3]
        pairs = ((d0, d1 & 0xFFFF), (((d1 >> 16) | (d2 << 16)) & 0xFFFFFFFF, d2 >> 16))
        for w0, w1 in pairs:
            opcode = (w1 >> 12) & 0xF
            if opcode in (1, 2, 3, 4, 5, 6, 13, 14):
                addr = w0 & 0xFFF
                count = (w0 >> 12) & 0x7
                seq = (w0 >> 16) & 0xFFF
                cf_bound = min(cf_bound, addr)
                for k in range(count):
                    if (seq >> (k * 2)) & 1:
                        slot = addr + k
                        if slot * 3 < len(dwords) and (dwords[slot * 3] & 0x1F) == 0:
                            fetch_slots.add(slot)
        i += 1
    return fetch_slots


def _compare_dumps(dump_dir, archive_ucodes, xex_path):
    """Match runtime .ucode.bin.{vert,frag} dumps against shader.arc and optional default.xex."""
    dumps = sorted(dump_dir.glob("*.ucode.bin.vert")) + sorted(dump_dir.glob("*.ucode.bin.frag"))
    if not dumps:
        raise ValueError(f"No .ucode.bin.{{vert,frag}} files found in {dump_dir}")
    xex_data = xex_path.read_bytes() if xex_path else None
    by_len = {}
    for stage, ucode, origins in archive_ucodes:
        by_len.setdefault((stage, len(ucode)), []).append((ucode, origins))

    exact_count = patched_count = xex_count = missing_count = 0
    for path in dumps:
        raw = path.read_bytes()
        if len(raw) % 4 or not raw:
            raise ValueError(f"{path.name}: unexpected byte size {len(raw)}")
        stage = "vertex" if path.suffix == ".vert" else "pixel"
        n = len(raw) // 4
        # Host shader dumps store swapped 32-bit words; convert back to big-endian Xbox order.
        be_dwords = struct.unpack(f"<{n}I", raw)
        be_bytes = struct.pack(f">{n}I", *be_dwords)

        origins = next((o for u, o in by_len.get((stage, len(be_bytes)), ()) if u == be_bytes), None)
        if origins is not None:
            exact_count += 1
            print(f"MATCH exact  {path.name} ({len(be_bytes)} B) -> {origins[0]}")
            continue

        if stage == "vertex":
            vfetch_slots = _vfetch_slots(be_dwords)
            template_match = None
            for cand_bytes, cand_origins in by_len.get((stage, len(be_bytes)), ()):
                cand_dwords = struct.unpack(f">{n}I", cand_bytes)
                diffs = [idx for idx in range(n) if be_dwords[idx] != cand_dwords[idx]]
                if diffs and all((idx // 3) in vfetch_slots for idx in diffs):
                    template_match = (len(diffs), cand_origins)
                    break
            if template_match is not None:
                patched_count += 1
                diff_cnt, cand_origins = template_match
                print(
                    f"MATCH vfetch {path.name} ({len(be_bytes)} B, {diff_cnt} dwords patched) "
                    f"-> {cand_origins[0]} (+{len(cand_origins) - 1} more)"
                )
                continue

        if xex_data is not None:
            pos = xex_data.find(be_bytes)
            if pos >= 0:
                xex_count += 1
                print(f"MATCH xex    {path.name} ({len(be_bytes)} B) -> {xex_path.name}+0x{pos:X}")
                continue

        missing_count += 1
        print(f"UNMATCHED    {path.name} ({len(be_bytes)} B)")

    print(
        f"Dump summary: {exact_count} exact archive, {patched_count} vfetch-patched archive, "
        f"{xex_count} default.xex, {missing_count} not in checked inputs (of {len(dumps)})."
    )
    if missing_count and xex_path is not None:
        raise ValueError(f"{missing_count} runtime shader dump(s) did not match")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--sdk-bin", type=Path,
                        default=Path("build/rexglue/win-amd64/bin"))
    parser.add_argument("--extract", type=Path,
                        help="Write unique local Xenos shader containers for compiler testing")
    parser.add_argument("--extract-ucode", type=Path,
                        help="Write raw big-endian microcode for a Xenos microcode translator")
    parser.add_argument("--compare-dumps", type=Path,
                        help="Compare ReXGlue .ucode.bin.{vert,frag} dumps against shader.arc")
    parser.add_argument("--xex", type=Path,
                        help="Optional unpacked default.xex to match XDK internal shaders")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This verifier requires the Windows x64 ReXGlue 0.10.1 SDK.")

    try:
        with os.add_dll_directory(str(args.sdk_bin.resolve())):
            runtime = ctypes.CDLL(str((args.sdk_bin / "rexruntime.dll").resolve()))
            # Exported C++ function from the pinned Windows SDK.
            decompress = getattr(runtime, "?lzx_decompress@@YAHPEBX_KPEAX1I21@Z")
            decompress.argtypes = [
                ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t,
            ]
            decompress.restype = ctypes.c_int
            bundles = list(decode_archive(args.archive, decompress))
        if not bundles:
            raise ValueError("No XFB shader bundles found")
    except (OSError, ValueError, AttributeError) as error:
        parser.exit(1, f"{error}\n")

    unique = {"vertex": set(), "pixel": set()}
    ucode_origins = {}
    for name, bundle in bundles:
        shaders = list(shader_containers(bundle))
        for stage, container in shaders:
            unique[stage].add(container)
            mc = shader_microcode(container)
            ucode_origins.setdefault((stage, mc), []).append(name)
        print(f"{name}: {len(bundle):,} decoded bytes, {len(shaders)} Xenos containers")
    print(f"Verified {len(bundles)} XFB shader bundles.")
    for stage, containers in unique.items():
        print(f"{len(containers):,} unique {stage} containers")
        if args.extract:
            args.extract.mkdir(parents=True, exist_ok=True)
            for stale in args.extract.glob(f"{stage}-*.xsh"):
                stale.unlink()
            for index, container in enumerate(sorted(containers)):
                (args.extract / f"{stage}-{index:04}.xsh").write_bytes(container)
        microcodes = {shader_microcode(container) for container in containers}
        print(f"{len(microcodes):,} unique {stage} microcode streams")
        if args.extract_ucode:
            args.extract_ucode.mkdir(parents=True, exist_ok=True)
            extension = "ps" if stage == "pixel" else "vs"
            other_ext = "vs" if stage == "pixel" else "ps"
            for stale in list(args.extract_ucode.glob(f"{stage}-*.{extension}")) + list(
                    args.extract_ucode.glob(f"{stage}-*.{other_ext}")):
                stale.unlink()
            for index, microcode in enumerate(sorted(microcodes)):
                (args.extract_ucode / f"{stage}-{index:04}.{extension}").write_bytes(microcode)

    if args.compare_dumps:
        try:
            archive_list = [(stage, mc, origins) for (stage, mc), origins in ucode_origins.items()]
            _compare_dumps(args.compare_dumps, archive_list, args.xex)
        except (OSError, ValueError) as error:
            parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
