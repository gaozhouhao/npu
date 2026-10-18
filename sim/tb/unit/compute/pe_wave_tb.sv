`timescale 1ns/1ps

// Reuse the established stimulus without changing the original PE experiment.
module pe_wave_tb;
    pe_tb test();

    initial begin
        $fsdbDumpfile("pe.fsdb");
        $fsdbDumpvars(0, pe_wave_tb);
        $dumpfile("pe.vcd");
        $dumpvars(0, pe_wave_tb);
    end
endmodule
