cd ~/npu

python3 - <<'PY'
from pathlib import Path

p = Path("rtl/core/gemm_executor.sv")
src = p.read_text()

changes = [
    (
        "for (genvar pr = 0; pr < ROWS; pr++) begin",
        "for (genvar pr = 0; pr < ROWS; pr++) begin : gen_psum_rows",
    ),
    (
        "for (genvar pc = 0; pc < COLS; pc++) begin",
        "for (genvar pc = 0; pc < COLS; pc++) begin : gen_psum_cols",
    ),
    (
        "for (genvar pl = 0; pl < COLS; pl++) begin",
        "for (genvar pl = 0; pl < COLS; pl++) begin : gen_psum_postprocess",
    ),
]

for before, after in changes:
    if after in src:
        continue
    if src.count(before) != 1:
        raise RuntimeError(f"Expected exactly one occurrence: {before}")
    src = src.replace(before, after, 1)

backup = Path("build/backup/gemm_executor.before_gen_labels.sv")
backup.parent.mkdir(parents=True, exist_ok=True)
backup.write_text(p.read_text())
p.write_text(src)

print("Fixed three generate block names.")
print(f"Backup: {backup}")
PY