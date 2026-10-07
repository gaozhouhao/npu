`timescale 1ns/1ps

module external_memory_tb;

  localparam longint unsigned MEMORY_SIZE = 64 * 1024;
  localparam longint unsigned LOAD_BASE   = 64'h0000_1000;

  logic        clk;
  logic        rst_n;
  logic        read_req;
  logic [63:0] read_addr;
  logic        read_ready;
  logic        read_valid;
  logic [31:0] read_data;
  logic        write_req;
  logic [63:0] write_addr;
  logic [31:0] write_data;
  logic [ 3:0] write_mask;
  logic        write_ready;

  import "DPI-C" function int memory_init(input longint unsigned size);
  import "DPI-C" function int memory_load_bin(
      input string           filename,
      input longint unsigned base_addr
  );

  external_memory dut (.*);

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic read_and_check(
      input longint unsigned addr,
      input logic [31:0]     expected
  );
    @(negedge clk);
    if (!read_ready) begin
      $fatal(1, "Memory was not ready for read at 0x%0h", addr);
    end
    read_addr = addr;
    read_req  = 1'b1;
    @(negedge clk);
    read_req = 1'b0;

    if (!read_valid) begin
      $fatal(1, "No read response for address 0x%0h", addr);
    end
    if (read_data !== expected) begin
      $fatal(1, "Read mismatch at 0x%0h: expected 0x%08h, got 0x%08h",
             addr, expected, read_data);
    end
  endtask

  task automatic write_word(
      input longint unsigned addr,
      input logic [31:0]     data,
      input logic [3:0]      mask
  );
    @(negedge clk);
    if (!write_ready) begin
      $fatal(1, "Memory was not ready for write at 0x%0h", addr);
    end
    write_addr = addr;
    write_data = data;
    write_mask = mask;
    write_req  = 1'b1;
    @(negedge clk);
    write_req = 1'b0;
  endtask

  initial begin
    rst_n      = 1'b0;
    read_req   = 1'b0;
    read_addr  = '0;
    write_req  = 1'b0;
    write_addr = '0;
    write_data = '0;
    write_mask = '0;

    if (memory_init(MEMORY_SIZE) == 0) begin
      $fatal(1, "C++ memory initialization failed");
    end
    if (memory_load_bin("build/external_memory/test.bin", LOAD_BASE) == 0) begin
      $fatal(1, "C++ binary load failed");
    end

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    read_and_check(LOAD_BASE,     32'h0403_0201);
    read_and_check(LOAD_BASE + 4, 32'h4433_2211);

    write_word(LOAD_BASE + 16, 32'hdead_beef, 4'b1111);
    read_and_check(LOAD_BASE + 16, 32'hdead_beef);

    write_word(LOAD_BASE + 16, 32'h1122_3344, 4'b1111);
    write_word(LOAD_BASE + 16, 32'haa_bb_cc_dd, 4'b0101);
    read_and_check(LOAD_BASE + 16, 32'h11bb_33dd);

    $display("External memory DPI test passed.");
    $finish;
  end

endmodule
