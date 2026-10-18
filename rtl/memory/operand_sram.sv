// A/B 操作数存储：普通仿真使用行为模型，TSMC28 分支使用真实 32x64 宏。
module operand_sram #(
    parameter int DATA_WIDTH = 64,
    parameter int DEPTH = 32,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic clk,
    input  logic ren,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,
    input  logic wen,
    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [DATA_WIDTH-1:0] wdata
);

`ifdef NPU_TSMC28
    logic [ADDR_WIDTH-1:0] addr;

    // 同一 bank 的加载和计算互斥，写入时选择写地址。
    assign addr = wen ? waddr : raddr;

    // 宏自身已经是同步读，Q 后面不再添加寄存器。
    TS5N28HPCPSVTA32X64M2F u_memory (
        .CLK (clk),
        .CEB (~(ren | wen)),
        .WEB (~wen),
        .A   (addr),
        .D   (wdata),
        .Q   (rdata)
    );

`ifndef SYNTHESIS
    // 只检查真实宏的两项接口约定，避免静默截断或读写冲突。
    initial begin
        if (DATA_WIDTH != 64 || DEPTH != 32 || ADDR_WIDTH != 5)
            $fatal(1, "NPU_TSMC28 operand SRAM requires 32x64 and 5-bit addresses");
    end
    always @(posedge clk) begin
        if (ren && wen)
            $fatal(1, "Single-port operand SRAM cannot read and write together");
    end
`endif
`else
    sram_model #(
        .DATA_WIDTH(DATA_WIDTH), .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_memory (
        .clk(clk), .ren(ren), .raddr(raddr), .rdata(rdata),
        .wen(wen), .waddr(waddr), .wdata(wdata)
    );
`endif
endmodule
