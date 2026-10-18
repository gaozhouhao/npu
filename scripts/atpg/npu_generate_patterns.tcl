# Shared by a new run and a resumed run. Run from the same result directory.
# Save every 300 CPU seconds. This is not a wall-clock timer.
set_atpg -checkpoint {300 checkpoint.faults checkpoint.patterns}
# Limit each basic/fast ATPG search to 3600 CPU seconds, then save and exit.
# A time-limited run may still have undetected faults; inspect the summary.
set_atpg -time {0 3600}
run_atpg -auto_compression

# Also save at a normal stop, even if the next checkpoint is not due yet.
write_faults checkpoint.faults -all -replace
write_patterns checkpoint.patterns -format binary -replace
write_patterns npu_stuck_at.stil -format stil -replace
report_summaries
report_faults -class AU -max 30
report_faults -class ND -max 30
exit -force
