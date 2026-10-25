// Operand SRAM technology boundary. Both implementations read in one clock.
module operand_sram #(
    parameter int DATA_WIDTH = 64,
    parameter int DEPTH = 32,
    parameter int ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input logic clk,
    input logic ren,
    input logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,
    input logic wen,
    input logic [ADDR_WIDTH-1:0] waddr,
    input logic [DATA_WIDTH-1:0] wdata
);
`ifdef NPU_TSMC28
    // The 32x64 macro has one shared port; loading and compute use separate banks.
    TS5N28HPCPSVTA32X64M2F u_memory (
        .CLK(clk), .CEB(~(ren | wen)), .WEB(~wen),
        .A(wen ? waddr : raddr), .D(wdata), .Q(rdata)
    );
`else
    logic [DATA_WIDTH-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
        if (ren) rdata <= mem[raddr];
        if (wen) mem[waddr] <= wdata;
    end
`endif
endmodule
