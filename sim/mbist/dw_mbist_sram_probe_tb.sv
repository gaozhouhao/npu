// Isolated gate-level test of the vendor MBIST path and one real SRAM.
`timescale 1ns/1ps
module dw_mbist_sram_probe_tb;
    logic clk = 0;
    always #50 clk = ~clk;
    logic rst_n = 0;
    logic mbrun = 0;
    logic shift_dr = 0;
    logic mode_reg_si = 0;
    logic inject_fault = 0;
    wire mode_reg_so;
    wire [15:0] mode_reg_out;
    wire [4:0] memory_address;
    wire memory_ce_n, memory_we_n;
    wire [63:0] memory_write_data;
    integer reads = 0;
    integer writes = 0;
    logic [31:0] read_addresses = 0;
    logic [31:0] write_addresses = 0;

    dw_mbist_sram_probe dut (
        .clk(clk), .rst_n(rst_n), .mbrun(mbrun), .shift_dr(shift_dr),
        .mode_reg_si(mode_reg_si), .inject_fault(inject_fault),
        .mode_reg_so(mode_reg_so), .mode_reg_out(mode_reg_out),
        .memory_address(memory_address), .memory_ce_n(memory_ce_n),
        .memory_we_n(memory_we_n), .memory_write_data(memory_write_data)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            reads <= 0;
            writes <= 0;
            read_addresses <= 0;
            write_addresses <= 0;
        end else if (mbrun && memory_ce_n === 1'b0) begin
            if ($isunknown({memory_address, memory_we_n}))
                $fatal(1, "Unknown SRAM command during MBIST");
            if (memory_we_n == 0) begin
                writes <= writes + 1;
                write_addresses[memory_address] <= 1;
            end else begin
                reads <= reads + 1;
                read_addresses[memory_address] <= 1;
            end
        end
    end

    task automatic run_case(input bit fault, input string label);
        logic [15:0] instruction;
        logic [15:0] status;
        integer i;
        begin
            // CTL mode bits: memory enable=15, no-pause=8, March C=3, select=1.
            instruction = 16'h810a;
            @(negedge clk);
            rst_n = 0;
            mbrun = 0;
            shift_dr = 0;
            mode_reg_si = 0;
            inject_fault = fault;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (4) @(negedge clk);

            // Load the 16-bit instruction, most-significant bit first.
            shift_dr = 1;
            for (i = 15; i >= 0; i = i - 1) begin
                mode_reg_si = instruction[i];
                @(negedge clk);
            end
            shift_dr = 0;
            mbrun = 1;
            repeat (20000) @(negedge clk);
            mbrun = 0;
            repeat (8) @(negedge clk);

            // Read the status using the same scan interface as the vendor CTL.
            shift_dr = 1;
            for (i = 15; i >= 0; i = i - 1) begin
                status[i] = mode_reg_so;
                mode_reg_si = 0;
                @(negedge clk);
            end
            shift_dr = 0;
            $display("MBIST %s: status=%h reads=%0d writes=%0d read_mask=%h write_mask=%h",
                     label, status, reads, writes, read_addresses, write_addresses);
            if (reads == 0 || writes == 0 || read_addresses !== 32'hffffffff ||
                write_addresses !== 32'hffffffff)
                $fatal(1, "SRAM address/read/write activity check failed");
            if (status[0] !== 1'b1)
                $fatal(1, "MBIST did not complete within 20000 clocks");
            if (status[7] !== fault || status[15] !== !fault)
                $fatal(1, "Unexpected MBIST failure status");
            $display("PASS: %s", label);
        end
    endtask

    initial begin
        run_case(0, "normal SRAM");
        run_case(1, "read-data bit 0 stuck at 0");
        $display("PASS: DC DesignWare MBIST normal and injected-fault tests");
        $finish;
    end
endmodule
