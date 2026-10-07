module external_memory (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        read_req,
    input  logic [63:0] read_addr,
    output logic        read_ready,
    output logic        read_valid,
    output logic [31:0] read_data,

    input  logic        write_req,
    input  logic [63:0] write_addr,
    input  logic [31:0] write_data,
    input  logic [ 3:0] write_mask,
    output logic        write_ready
);

  import "DPI-C" function int unsigned memory_read32(
      input longint unsigned addr
  );
  import "DPI-C" function void memory_write32(
      input longint unsigned addr,
      input int unsigned     data,
      input byte unsigned    write_mask
  );

  assign read_ready  = rst_n;
  assign write_ready = rst_n;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      read_valid <= 1'b0;
      read_data  <= '0;
    end else begin
      read_valid <= 1'b0;

      if (read_req && read_ready) begin
        read_data  <= memory_read32(read_addr);
        read_valid <= 1'b1;
      end

      if (write_req && write_ready) begin
        memory_write32(write_addr, write_data, {4'b0, write_mask});
      end
    end
  end

endmodule
