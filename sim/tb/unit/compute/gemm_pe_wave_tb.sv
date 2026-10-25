`timescale 1ns/1ps

// Reuse the established stimulus without changing the original PE experiment.
module gemm_pe_wave_tb;
    gemm_pe_tb test();

    initial begin
        $fsdbDumpfile("gemm_pe.fsdb");
        $fsdbDumpvars(0, gemm_pe_wave_tb);
        $dumpfile("gemm_pe.vcd");
        $dumpvars(0, gemm_pe_wave_tb);
    end
endmodule
