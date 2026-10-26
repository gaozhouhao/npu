#!/usr/bin/env python3
"""Apply a fail-closed read-path ablation to an isolated current-RTL snapshot.

Both variants retain native AXI64 operands, current arithmetic, logical tails,
pooling, and matched-N B-tag invalidation. The baseline disables four specific
optimizations; it is a controlled ablation, not a historical RTL revision.
"""

import difflib
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FILES = ("rtl/npu_top.sv", "rtl/dma/conv_patch_reader.sv",
         "rtl/control/gemm_tile_scheduler.sv")
FEATURES = ("conv_cache", "conv_segment_lookahead", "b_stationary_prefetch",
            "cp_idle_fast_acquire")

# Each anchor includes its immediate control context. Validate every replacement
# before writing any file, including for the optimized no-op variant.
REPLACEMENTS = {
    FILES[0]: (("    parameter bit CONV_CACHE_ENABLE = 1'b1,\n",
                "    parameter bit CONV_CACHE_ENABLE = 1'b0,\n"),),
    FILES[1]: ((
        "                        // Prepare next segment during completion\n"
        "                        // of the current read request.\n"
        "                        if (!rd_error &&\n"
        "                            (index_q < load_size_q) &&\n"
        "                            !is_padding) begin\n",
        "                        // Ablation: use the existing ST_PREP fallback.\n"
        "                        if (1'b0) begin\n"),),
    FILES[2]: (
        ("    assign b_load_req =\n"
         "        (load_state == LD_REQ) &&\n"
         "        !b_load_issued_q &&\n"
         "        !b_reuse_q;\n",
         "    assign b_load_req =\n"
         "        (load_state == LD_REQ) &&\n"
         "        !b_load_issued_q &&\n"
         "        !b_reuse_q &&\n"
         "        (!b_stationary_q || !resident_b_valid_q);\n"),
        ("    assign a_compute_req =\n"
         "        (\n"
         "            ((compute_state == CP_IDLE) && ready_valid_q) ||\n"
         "            (compute_state == CP_ACQUIRE)\n"
         "        ) && !a_acquired_q;\n",
         "    assign a_compute_req =\n"
         "        (compute_state == CP_ACQUIRE) && !a_acquired_q;\n"),
        ("    assign b_compute_req =\n"
         "        (\n"
         "            ((compute_state == CP_IDLE) && ready_valid_q) ||\n"
         "            (compute_state == CP_ACQUIRE)\n"
         "        ) && !b_acquired_q;\n",
         "    assign b_compute_req =\n"
         "        (compute_state == CP_ACQUIRE) && !b_acquired_q;\n"),
        ("                    CP_IDLE: begin\n"
         "                        if (ready_valid_q) begin\n"
         "                            // The bank managers see compute_req in\n"
         "                            // this cycle. If both banks grant, latch\n"
         "                            // the tile and skip CP_ACQUIRE entirely.\n"
         "                            if (a_compute_grant && b_compute_grant) begin\n"
         "                                compute_m_q <= ready_m_q;\n"
         "                                compute_n_q <= ready_n_q;\n"
         "                                compute_k_q <= ready_k_q;\n"
         "                                ready_valid_q <= 1'b0;\n"
         "                                a_acquired_q <= 1'b0;\n"
         "                                b_acquired_q <= 1'b0;\n"
         "                                compute_state <= CP_LAUNCH;\n"
         "                            end else begin\n"
         "                                // Record either partial grant: a bank\n"
         "                                // manager consumes it on this edge.\n"
         "                                a_acquired_q <= a_compute_grant;\n"
         "                                b_acquired_q <= b_compute_grant;\n"
         "                                compute_state <= CP_ACQUIRE;\n"
         "                            end\n"
         "                        end\n"
         "                    end\n",
         "                    CP_IDLE: begin\n"
         "                        if (ready_valid_q) begin\n"
         "                            a_acquired_q <= 1'b0;\n"
         "                            b_acquired_q <= 1'b0;\n"
         "                            compute_state <= CP_ACQUIRE;\n"
         "                        end\n"
         "                    end\n"),
    ),
}


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def apply_variant(source_dir, variant):
    """Return auditable metadata after applying baseline or optimized to a copy.

    Paths in hash maps/patches are relative to source_dir. Optimized validates
    the expected source and performs no writes. A missing, repeated, or changed
    anchor rejects the entire operation before its first write. Reapplying the
    baseline intentionally fails rather than mislabeling an already patched copy.
    """
    if variant not in ("baseline", "optimized"):
        raise ValueError("variant must be baseline or optimized")
    source = Path(source_dir).resolve()
    if source == ROOT:
        raise ValueError("source_dir must be an isolated snapshot, not the repository root")

    originals, proposed = {}, {}
    for name in FILES:
        path = source / name
        if source not in path.resolve().parents:
            raise ValueError("Source file escapes snapshot: " + name)
        data = path.read_bytes()
        text = data.decode("utf-8")
        originals[name] = data
        for index, (old, new) in enumerate(REPLACEMENTS[name]):
            count = text.count(old)
            if count != 1:
                raise ValueError("%s anchor %d: expected 1 occurrence, got %d" % (name, index, count))
            text = text.replace(old, new, 1)
        proposed[name] = text.encode("utf-8") if variant == "baseline" else data

    top = originals[FILES[0]].decode("utf-8")
    for invariant in ("        .OPERAND_WORD_WIDTH(64),\n",
                      "    parameter int unsigned CONV_CACHE_LINES = 256,\n"):
        if top.count(invariant) != 1:
            raise ValueError("Expected native64/2KiB cache geometry invariant")

    patches = []
    for name in FILES:
        if originals[name] != proposed[name]:
            diff = "".join(difflib.unified_diff(
                originals[name].decode().splitlines(keepends=True),
                proposed[name].decode().splitlines(keepends=True),
                fromfile="original/" + name, tofile=variant + "/" + name))
            patches.append(dict(path=name, unified_diff=diff,
                                original_sha256=_hash(originals[name]),
                                compiled_sha256=_hash(proposed[name])))

    # Both compute-request expressions and the CP_IDLE state are committed as
    # one validated recipe. Changing only one half would lose real bank grants.
    written = []
    try:
        for patch in patches:
            name = patch["path"]
            written.append(name)
            (source / name).write_bytes(proposed[name])
    except OSError:
        for name in written:
            (source / name).write_bytes(originals[name])
        raise

    return dict(schema_version=1, variant=variant,
                helper_sha256=_hash(Path(__file__).read_bytes()), native_operand_read_bits=64,
                features=dict((name, variant == "optimized") for name in FEATURES),
                original_sha256=dict((name, _hash(data)) for name, data in originals.items()),
                compiled_sha256=dict((name, _hash(data)) for name, data in proposed.items()),
                changed_files=[patch["path"] for patch in patches], patches=patches)
