module operand_buffer #(
    parameter int unsigned ELEM_WIDTH      = 8,
    parameter int unsigned LANE_COUNT      = 4,
    parameter int unsigned MEM_WORD_WIDTH  = 32,
    parameter int unsigned K_DEPTH         = 256,
    parameter int unsigned BUFFER_COUNT    = 2,

    parameter int unsigned K_ADDR_WIDTH =
        (K_DEPTH <= 1) ? 1 : $clog2(K_DEPTH),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / ELEM_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),

    parameter int unsigned LANE_SEL_WIDTH =
        (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT),

    parameter int unsigned BANK_SEL_WIDTH =
        (BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT),

    parameter int unsigned ELEM_SEL_WIDTH =
        (ELEMS_PER_WORD <= 1) ?
        1 :
        $clog2(ELEMS_PER_WORD)
) (
    input logic clk,

    // ============================================================
    // Load / DMA write side
    //
    // One AXI-width word is written into one lane SRAM.
    //
    // Example:
    //
    // row0 AXI beat:
    // {a03,a02,a01,a00}
    //
    // ->
    //
    // lane0 SRAM word 0
    // ============================================================

    input logic wen,

    input logic [BANK_SEL_WIDTH-1:0] wbank,
    input logic [LANE_SEL_WIDTH-1:0] wlane,

    input logic [WORD_ADDR_WIDTH-1:0] waddr,

    input logic [MEM_WORD_WIDTH-1:0] wdata,

    // ============================================================
    // Compute read side
    //
    // r_k_index is the logical K index:
    //
    // 0,1,2,3 -> SRAM word 0
    // 4,5,6,7 -> SRAM word 1
    //
    // One element is selected from every lane SRAM and packed
    // into rdata.
    //
    // For 4 lanes x INT8:
    //
    // rdata =
    // {lane3[k], lane2[k], lane1[k], lane0[k]}
    // ============================================================

    input logic ren,

    input logic [BANK_SEL_WIDTH-1:0] rbank,

    input logic [K_ADDR_WIDTH-1:0] r_k_index,

    output logic [
        LANE_COUNT * ELEM_WIDTH - 1 : 0
    ] rdata
);

    // ============================================================
    // Derived constants
    // ============================================================

    localparam int unsigned WORD_SHIFT =
        $clog2(ELEMS_PER_WORD);


    // ============================================================
    // Current compute address
    // ============================================================

    logic [WORD_ADDR_WIDTH-1:0] rword_addr;

    logic [ELEM_SEL_WIDTH-1:0] elem_sel;
    logic [ELEM_SEL_WIDTH-1:0] elem_sel_q;

    logic read_word;


    // ============================================================
    // Selected output word from every lane
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        selected_lane_word [0:LANE_COUNT-1];


    // ============================================================
    // Convert logical K index into:
    //
    // SRAM word address
    // +
    // byte/element selection
    //
    // Example for INT8 / 32-bit SRAM:
    //
    // k=6
    //
    // word_addr = 6 >> 2 = 1
    // elem_sel  = 6 & 3  = 2
    // ============================================================

    assign rword_addr =
        WORD_ADDR_WIDTH'(
            r_k_index >> WORD_SHIFT
        );


    generate

        if (ELEMS_PER_WORD == 1) begin : gen_one_elem

            assign elem_sel = '0;

        end else begin : gen_multi_elem

            assign elem_sel =
                ELEM_SEL_WIDTH'(
                    r_k_index[
                        ELEM_SEL_WIDTH-1:0
                    ]
                );

        end

    endgenerate


    // ============================================================
    // SRAM is only physically read once per SRAM word.
    //
    // With 32-bit SRAM and INT8:
    //
    // k=0 -> read SRAM word0
    // k=1 -> reuse word0
    // k=2 -> reuse word0
    // k=3 -> reuse word0
    // k=4 -> read SRAM word1
    //
    // This avoids performing the same SRAM read four times.
    // ============================================================

    assign read_word =
        ren &&
        (elem_sel == '0);


    // ============================================================
    // Delay element selector to align with synchronous SRAM read.
    //
    // SRAM read latency = 1 cycle.
    // ============================================================

    always_ff @(posedge clk) begin

        if (ren) begin
            elem_sel_q <= elem_sel;
        end

    end


    // ============================================================
    // BUFFER_COUNT = 1
    // ============================================================

    generate

        if (BUFFER_COUNT == 1) begin : gen_single_buffer

            for (
                genvar lane = 0;
                lane < LANE_COUNT;
                lane = lane + 1
            ) begin : gen_lane

                logic [
                    MEM_WORD_WIDTH-1:0
                ] lane_rdata;

                logic lane_wen;
                logic lane_ren;


                assign lane_wen =
                    wen &&
                    (wbank == '0) &&
                    (
                        wlane ==
                        LANE_SEL_WIDTH'(lane)
                    );


                assign lane_ren =
                    read_word &&
                    (rbank == '0);


                sram_model #(
                    .DATA_WIDTH (
                        MEM_WORD_WIDTH
                    ),
                    .DEPTH (
                        WORD_DEPTH
                    ),
                    .ADDR_WIDTH (
                        WORD_ADDR_WIDTH
                    )
                ) u_lane_sram (
                    .clk   (clk),

                    .ren   (lane_ren),
                    .raddr (rword_addr),
                    .rdata (lane_rdata),

                    .wen   (lane_wen),
                    .waddr (waddr),
                    .wdata (wdata)
                );


                assign selected_lane_word[lane] =
                    lane_rdata;

            end

        end else begin : gen_double_buffer

            // ====================================================
            // BUFFER_COUNT = 2
            //
            // Every ping-pong buffer contains LANE_COUNT SRAMs.
            //
            // Example:
            //
            // buffer0:
            //   lane0
            //   lane1
            //   lane2
            //   lane3
            //
            // buffer1:
            //   lane0
            //   lane1
            //   lane2
            //   lane3
            // ====================================================

            for (
                genvar lane = 0;
                lane < LANE_COUNT;
                lane = lane + 1
            ) begin : gen_lane

                logic [
                    MEM_WORD_WIDTH-1:0
                ] bank0_rdata;

                logic [
                    MEM_WORD_WIDTH-1:0
                ] bank1_rdata;

                logic bank0_wen;
                logic bank1_wen;

                logic bank0_ren;
                logic bank1_ren;


                assign bank0_wen =
                    wen &&
                    (wbank == BANK_SEL_WIDTH'(0)) &&
                    (
                        wlane ==
                        LANE_SEL_WIDTH'(lane)
                    );


                assign bank1_wen =
                    wen &&
                    (wbank == BANK_SEL_WIDTH'(1)) &&
                    (
                        wlane ==
                        LANE_SEL_WIDTH'(lane)
                    );


                assign bank0_ren =
                    read_word &&
                    (
                        rbank ==
                        BANK_SEL_WIDTH'(0)
                    );


                assign bank1_ren =
                    read_word &&
                    (
                        rbank ==
                        BANK_SEL_WIDTH'(1)
                    );


                sram_model #(
                    .DATA_WIDTH (
                        MEM_WORD_WIDTH
                    ),
                    .DEPTH (
                        WORD_DEPTH
                    ),
                    .ADDR_WIDTH (
                        WORD_ADDR_WIDTH
                    )
                ) u_bank0_lane_sram (
                    .clk   (clk),

                    .ren   (bank0_ren),
                    .raddr (rword_addr),
                    .rdata (bank0_rdata),

                    .wen   (bank0_wen),
                    .waddr (waddr),
                    .wdata (wdata)
                );


                sram_model #(
                    .DATA_WIDTH (
                        MEM_WORD_WIDTH
                    ),
                    .DEPTH (
                        WORD_DEPTH
                    ),
                    .ADDR_WIDTH (
                        WORD_ADDR_WIDTH
                    )
                ) u_bank1_lane_sram (
                    .clk   (clk),

                    .ren   (bank1_ren),
                    .raddr (rword_addr),
                    .rdata (bank1_rdata),

                    .wen   (bank1_wen),
                    .waddr (waddr),
                    .wdata (wdata)
                );


                assign selected_lane_word[lane] =
                    (
                        rbank ==
                        BANK_SEL_WIDTH'(0)
                    ) ?
                    bank0_rdata :
                    bank1_rdata;

            end

        end

    endgenerate


    // ============================================================
    // Select one INT8/element from every lane SRAM word.
    // ============================================================

    function automatic logic [ELEM_WIDTH-1:0] select_element (
        input logic [MEM_WORD_WIDTH-1:0] word,
        input logic [ELEM_SEL_WIDTH-1:0] sel
    );

        begin

            select_element =
                word[
                    (sel * ELEM_WIDTH)
                    +:
                    ELEM_WIDTH
                ];

        end

    endfunction


    integer lane_idx;

    always_comb begin

        rdata = '0;

        for (
            lane_idx = 0;
            lane_idx < LANE_COUNT;
            lane_idx = lane_idx + 1
        ) begin

            rdata[
                lane_idx * ELEM_WIDTH
                +:
                ELEM_WIDTH
            ] =
                select_element(
                    selected_lane_word[
                        lane_idx
                    ],
                    elem_sel_q
                );

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ELEM_WIDTH < 1) begin

            $fatal(
                1,
                "ELEM_WIDTH must be >= 1"
            );

        end


        if (LANE_COUNT < 1) begin

            $fatal(
                1,
                "LANE_COUNT must be >= 1"
            );

        end


        if (K_DEPTH < 1) begin

            $fatal(
                1,
                "K_DEPTH must be >= 1"
            );

        end


        if (
            (BUFFER_COUNT != 1) &&
            (BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "BUFFER_COUNT must be 1 or 2"
            );

        end


        if (
            (MEM_WORD_WIDTH % ELEM_WIDTH) != 0
        ) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by ELEM_WIDTH"
            );

        end


        if (
            (
                ELEMS_PER_WORD &
                (ELEMS_PER_WORD - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "ELEMS_PER_WORD must be a power of two"
            );

        end

    end

endmodule
