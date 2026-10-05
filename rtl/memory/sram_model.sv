module sram_model #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 256,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic                  clk,

    // Read port
    input  logic                  ren,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,

    // Write port
    input  logic                  wen,
    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [DATA_WIDTH-1:0] wdata
);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Synchronous read: 1-cycle latency
    always_ff @(posedge clk) begin
        if (ren)
            rdata <= mem[raddr];
    end

    // Synchronous write
    always_ff @(posedge clk) begin
        if (wen)
            mem[waddr] <= wdata;
    end

endmodule