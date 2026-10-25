module pe_uvm_tb;
    timeunit 1ns;
    timeprecision 1ps;

    import uvm_pkg::*;
    import pe_pkg::*;

    logic clk = 0;
    always #5ns clk = ~clk;

    pe_if pe_bus(clk);
    gemm_pe #(.DATA_WIDTH(8), .ACC_WIDTH(32)) dut (
        .clk(clk),
        .reset(pe_bus.reset),
        .clear(pe_bus.clear),
        .a_in(pe_bus.a_in),
        .b_in(pe_bus.b_in),
        .a_valid_in(pe_bus.a_valid_in),
        .b_valid_in(pe_bus.b_valid_in),
        .a_out(pe_bus.a_out),
        .b_out(pe_bus.b_out),
        .a_valid_out(pe_bus.a_valid_out),
        .b_valid_out(pe_bus.b_valid_out),
        .acc_out(pe_bus.acc_out)
    );

    initial begin
        // Classes get a virtual handle to this real interface instance.
        uvm_config_db#(virtual pe_if)::set(null, "uvm_test_top.env.agent.*", "vif", pe_bus);
        run_test(); // +UVM_TESTNAME selects the registered test class.
    end

    initial begin
        if ($test$plusargs("UVM_WAVE")) begin
            $dumpfile("pe_uvm.vcd");
            $dumpvars(0, pe_uvm_tb);
        end
    end

    initial begin
        #10us;
        $fatal(1, "PE UVM test timed out");
    end
endmodule
