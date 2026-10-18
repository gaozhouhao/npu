# Run from the result directory containing npu_model.image and checkpoint.*.
set_commands exit
set_messages -log tmax_resume.log -replace
read_image npu_model.image
set_faults -model stuck -report uncollapsed -summary verbose -fault_coverage

# Restore fault classes exactly, then load the saved patterns internally.
# This sequence follows the TetraMAX "Using ATPG Checkpoint Files" guide.
read_faults checkpoint.faults -force_retain_code
set_patterns -external checkpoint.patterns
run_simulation -store
set_patterns -internal
report_summaries
source ../../../scripts/atpg/npu_generate_patterns.tcl
