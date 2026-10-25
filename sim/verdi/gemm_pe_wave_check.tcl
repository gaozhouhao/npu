# Run from the directory containing gemm_pe.fsdb after importing gemm_pe_wave_tb.
srcSetScope gemm_pe_wave_tb.test.dut
set wave [wvCreateWindow]
wvOpenFile -win $wave gemm_pe.fsdb
wvAddSignal -win $wave /gemm_pe_wave_tb/test/clk /gemm_pe_wave_tb/test/reset \
    /gemm_pe_wave_tb/test/a_valid_in /gemm_pe_wave_tb/test/b_valid_in \
    {/gemm_pe_wave_tb/test/a_in[7:0]} {/gemm_pe_wave_tb/test/b_in[7:0]} \
    {/gemm_pe_wave_tb/test/acc_out[31:0]}
puts "PE_WAVE_TIME_RANGE=[wvGetFileTimeRange -win $wave]"
puts "PE_VERDI_WAVE_LOADED"
debExit
