# Run from the directory containing pe.fsdb after importing pe_wave_tb.
srcSetScope pe_wave_tb.test.dut
set wave [wvCreateWindow]
wvOpenFile -win $wave pe.fsdb
wvAddSignal -win $wave /pe_wave_tb/test/clk /pe_wave_tb/test/reset \
    /pe_wave_tb/test/a_valid_in /pe_wave_tb/test/b_valid_in \
    {/pe_wave_tb/test/a_in[7:0]} {/pe_wave_tb/test/b_in[7:0]} \
    {/pe_wave_tb/test/acc_out[31:0]}
puts "PE_WAVE_TIME_RANGE=[wvGetFileTimeRange -win $wave]"
puts "PE_VERDI_WAVE_LOADED"
debExit
