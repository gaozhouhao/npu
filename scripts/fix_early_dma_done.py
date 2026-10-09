
#!/usr/bin/env python3

from pathlib import Path

path = Path("rtl/core/tile_scheduler.sv")
source = path.read_text()

before = """                    LD_REQ: begin

                        if (a_load_accept_effective) begin"""

after = """                    LD_REQ: begin

                        // A and B loads are accepted independently.
                        //
                        // One operand may finish while the other
                        // is still waiting for a buffer bank.
                        //
                        // Record completion pulses immediately,
                        // even before entering LD_WAIT.

                        if (a_load_done_effective) begin
                            a_load_finished_q <= 1'b1;
                        end

                        if (b_load_done) begin
                            b_load_finished_q <= 1'b1;
                        end

                        if (a_load_accept_effective) begin"""

if source.count(before) != 1:
    raise RuntimeError(
        "Unexpected tile_scheduler.sv structure. "
        "No files were modified."
    )

backup = Path("build/backup/tile_scheduler.before_done_fix.sv")
backup.parent.mkdir(parents=True, exist_ok=True)
backup.write_text(source)

path.write_text(source.replace(before, after, 1))

print("Fixed early DMA completion handling.")
print(f"Backup: {backup}")
print(f"Updated: {path}")
