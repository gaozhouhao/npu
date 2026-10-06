module operand_buffer #(
    parameter int DATA_WIDTH   = 32,
    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int BUFFER_COUNT = 1
) (
    input logic clk,

    // Loader / DMA write side
    input logic                  wen,
    input logic                  wbank,
    input logic [ADDR_WIDTH-1:0] waddr,
    input logic [DATA_WIDTH-1:0] wdata,

    // Compute read side
    input  logic                  ren,
    input  logic                  rbank,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata
);

    logic bank0_wen;
    logic bank0_ren;
    logic [DATA_WIDTH-1:0] bank0_rdata;

    assign bank0_wen =
        wen && ((BUFFER_COUNT == 1) || (wbank == 1'b0));

    assign bank0_ren =
        ren && ((BUFFER_COUNT == 1) || (rbank == 1'b0));


    sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_bank0 (
        .clk   (clk),

        .ren   (bank0_ren),
        .raddr (raddr),
        .rdata (bank0_rdata),

        .wen   (bank0_wen),
        .waddr (waddr),
        .wdata (wdata)
    );


    generate

        if (BUFFER_COUNT == 2) begin : GEN_BANK1

            logic bank1_wen;
            logic bank1_ren;
            logic [DATA_WIDTH-1:0] bank1_rdata;

            assign bank1_wen =
                wen && (wbank == 1'b1);

            assign bank1_ren =
                ren && (rbank == 1'b1);


            sram_model #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (ADDR_WIDTH),
                .DEPTH      (DEPTH)
            ) u_bank1 (
                .clk   (clk),

                .ren   (bank1_ren),
                .raddr (raddr),
                .rdata (bank1_rdata),

                .wen   (bank1_wen),
                .waddr (waddr),
                .wdata (wdata)
            );


            assign rdata =
                rbank ? bank1_rdata : bank0_rdata;

        end else begin : GEN_SINGLE_BUFFER

            assign rdata = bank0_rdata;

        end

    endgenerate


    initial begin

        if ((BUFFER_COUNT != 1) &&
            (BUFFER_COUNT != 2)) begin

            $fatal(
                1,
                "operand_buffer BUFFER_COUNT must be 1 or 2"
            );

        end

    end

endmodule
