module npu_top_tb;

    localparam int unsigned ADDR_WIDTH       = 64;
    localparam int unsigned DESC_COUNT_WIDTH = 16;
    localparam int unsigned TILE_COUNT_WIDTH = 16;

    localparam int unsigned ROWS             = 4;
    localparam int unsigned COLS             = 4;

    localparam int unsigned DATA_WIDTH       = 8;
    localparam int unsigned ACC_WIDTH        = 32;
    localparam int unsigned MEM_WORD_WIDTH   = 32;

    localparam int unsigned ID_WIDTH         = 1;
    localparam int unsigned K_TILE_SIZE      = 256;

    localparam int unsigned A_BUFFER_COUNT   = 2;
    localparam int unsigned B_BUFFER_COUNT   = 2;


    // ============================================================
    // Workload
    // ============================================================

    localparam int unsigned M_TOTAL =
        8;

    localparam int unsigned N_TOTAL =
        8;

    localparam int unsigned K_TOTAL =
        260;


    localparam int unsigned WORD_BYTES =
        MEM_WORD_WIDTH / 8;

    localparam int unsigned AB_STRIDE_BYTES =
        K_TOTAL;

    localparam int unsigned C_INT32_STRIDE =
        N_TOTAL * 4;

    localparam int unsigned C_INT8_STRIDE =
        N_TOTAL;

    localparam int unsigned WORDS_PER_AB_ROW =
        AB_STRIDE_BYTES /
        WORD_BYTES;


    // ============================================================
    // Memory map
    // ============================================================

    localparam logic [63:0] A_BASE =
        64'h0000_0000_0000_1000;

    localparam logic [63:0] BT_BASE =
        64'h0000_0000_0000_2000;

    localparam logic [63:0] C0_BASE =
        64'h0000_0000_0000_3000;

    localparam logic [63:0] C1_BASE =
        64'h0000_0000_0000_3400;

    localparam logic [63:0] C2_BASE =
        64'h0000_0000_0000_3800;

    localparam logic [63:0] PARAM_BASE =
        64'h0000_0000_0000_5000;

    localparam logic [63:0] DESC_BASE =
        64'h0000_0000_0000_6000;


    localparam int unsigned A_WORD_BASE =
        32'h0000_1000 /
        WORD_BYTES;

    localparam int unsigned BT_WORD_BASE =
        32'h0000_2000 /
        WORD_BYTES;

    localparam int unsigned C0_WORD_BASE =
        32'h0000_3000 /
        WORD_BYTES;

    localparam int unsigned C1_WORD_BASE =
        32'h0000_3400 /
        WORD_BYTES;

    localparam int unsigned C2_WORD_BASE =
        32'h0000_3800 /
        WORD_BYTES;

    localparam int unsigned PARAM_WORD_BASE =
        32'h0000_5000 /
        WORD_BYTES;

    localparam int unsigned DESC_WORD_BASE =
        32'h0000_6000 /
        WORD_BYTES;


    localparam int unsigned MEMORY_WORDS =
        8192;

    localparam int unsigned TIMEOUT_CYCLES =
        30000;


    // ============================================================
    // Requant test parameters
    //
    // Scale:
    //
    //     S = M / 2^R
    //       = 3 / 4
    //       = 0.75
    //
    // This deliberately generates saturation and ReLU cases.
    // ============================================================

    localparam int unsigned TEST_MULTIPLIER =
        3;

    localparam int unsigned TEST_SHIFT =
        2;


    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic reset;


    initial begin

        clk =
            1'b0;

    end


    always #5 clk = ~clk;


    // ============================================================
    // Host interface
    // ============================================================

    logic start;

    logic [63:0]
        desc_base;

    logic [DESC_COUNT_WIDTH-1:0]
        desc_count;


    logic npu_busy;
    logic npu_done;
    logic npu_error;


    // ============================================================
    // Debug RAW accumulator
    // ============================================================

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // AXI Read Address
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_arid;

    logic [ADDR_WIDTH-1:0]
        axi_araddr;

    logic [7:0]
        axi_arlen;

    logic [2:0]
        axi_arsize;

    logic [1:0]
        axi_arburst;

    logic
        axi_arvalid;

    logic
        axi_arready;


    // ============================================================
    // AXI Read Data
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_rid;

    logic [MEM_WORD_WIDTH-1:0]
        axi_rdata;

    logic [1:0]
        axi_rresp;

    logic
        axi_rlast;

    logic
        axi_rvalid;

    logic
        axi_rready;


    // ============================================================
    // AXI Write Address
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_awid;

    logic [ADDR_WIDTH-1:0]
        axi_awaddr;

    logic [7:0]
        axi_awlen;

    logic [2:0]
        axi_awsize;

    logic [1:0]
        axi_awburst;

    logic
        axi_awvalid;

    logic
        axi_awready;


    // ============================================================
    // AXI Write Data
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        axi_wdata;

    logic [(MEM_WORD_WIDTH/8)-1:0]
        axi_wstrb;

    logic
        axi_wlast;

    logic
        axi_wvalid;

    logic
        axi_wready;


    // ============================================================
    // AXI Write Response
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_bid;

    logic [1:0]
        axi_bresp;

    logic
        axi_bvalid;

    logic
        axi_bready;


    // ============================================================
    // External memory model
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        read_memory [0:MEMORY_WORDS-1];

    logic [MEM_WORD_WIDTH-1:0]
        write_memory [0:MEMORY_WORDS-1];


    // ============================================================
    // Read slave state
    // ============================================================

    logic
        rd_active_q;

    logic [ADDR_WIDTH-1:0]
        rd_addr_q;

    logic [8:0]
        rd_beats_left_q;


    // ============================================================
    // Write slave state
    // ============================================================

    logic
        wr_active_q;

    logic [ADDR_WIDTH-1:0]
        wr_addr_q;

    logic [8:0]
        wr_beats_left_q;

    logic [ID_WIDTH-1:0]
        wr_id_q;


    // ============================================================
    // Performance / protocol counters
    // ============================================================

    integer cycle_count;

    integer total_ar_count;
    integer descriptor_ar_count;
    integer operand_ar_count;
    integer global_param_ar_count;
    integer bias_ar_count;

    integer aw_count;
    integer w_count;
    integer b_count;


    // ============================================================
    // DUT
    // ============================================================

    npu_top #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DESC_COUNT_WIDTH (DESC_COUNT_WIDTH),
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),

        .ROWS             (ROWS),
        .COLS             (COLS),

        .DATA_WIDTH       (DATA_WIDTH),
        .ACC_WIDTH        (ACC_WIDTH),
        .MEM_WORD_WIDTH   (MEM_WORD_WIDTH),

        .ID_WIDTH         (ID_WIDTH),

        .K_TILE_SIZE      (K_TILE_SIZE),

        .A_BUFFER_COUNT   (A_BUFFER_COUNT),
        .B_BUFFER_COUNT   (B_BUFFER_COUNT)
    ) u_dut (
        .clk           (clk),
        .reset         (reset),

        .start         (start),
        .desc_base     (desc_base),
        .desc_count    (desc_count),

        .busy          (npu_busy),
        .done          (npu_done),
        .error         (npu_error),

        .acc_out       (acc_out),

        .m_axi_arid    (axi_arid),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),

        .m_axi_rid     (axi_rid),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rresp   (axi_rresp),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),

        .m_axi_awid    (axi_awid),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),

        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),

        .m_axi_bid     (axi_bid),
        .m_axi_bresp   (axi_bresp),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready)
    );


    // ============================================================
    // Golden requant model
    //
    // round-to-nearest, ties away from zero
    // ============================================================

    function automatic integer signed requant_model (
        input integer signed   value,
        input integer unsigned multiplier,
        input integer unsigned shift_amount,
        input logic            relu
    );

        longint signed
            value_ext;

        longint signed
            multiplier_ext;

        longint signed
            product;

        longint signed
            scaled;

        longint unsigned
            magnitude;

        longint unsigned
            rounded_magnitude;

        longint unsigned
            half;

        begin

            // ----------------------------------------------------
            // Explicit 32 -> 64 extension.
            //
            // Avoid implicit width/sign behaviour in multiplication.
            // ----------------------------------------------------

            value_ext =
                $signed(
                    {
                        {32{value[31]}},
                        value[31:0]
                    }
                );


            multiplier_ext =
                $signed(
                    {
                        32'd0,
                        multiplier[31:0]
                    }
                );


            product =
                value_ext *
                multiplier_ext;


            // ----------------------------------------------------
            // Rounding right shift
            // ----------------------------------------------------

            if (
                shift_amount ==
                0
            ) begin

                scaled =
                    product;

            end else begin

                if (
                    product <
                    0
                ) begin

                    magnitude =
                        $unsigned(
                            -product
                        );

                end else begin

                    magnitude =
                        $unsigned(
                            product
                        );

                end


                half =
                    64'd1 <<
                    (
                        shift_amount -
                        1
                    );


                rounded_magnitude =
                    (
                        magnitude +
                        half
                    ) >>
                    shift_amount;


                if (
                    product <
                    0
                ) begin

                    scaled =
                        -$signed(
                            rounded_magnitude
                        );

                end else begin

                    scaled =
                        $signed(
                            rounded_magnitude
                        );

                end

            end


            // ----------------------------------------------------
            // Saturation + optional ReLU
            // ----------------------------------------------------

            if (relu) begin

                if (
                    scaled <=
                    0
                ) begin

                    requant_model =
                        0;

                end else if (
                    scaled >
                    127
                ) begin

                    requant_model =
                        127;

                end else begin

                    // scaled is guaranteed to be 0...127 here.
                    requant_model =
                        $signed(
                            scaled[31:0]
                        );

                end

            end else begin

                if (
                    scaled >
                    127
                ) begin

                    requant_model =
                        127;

                end else if (
                    scaled <
                    -128
                ) begin

                    requant_model =
                        -128;

                end else begin

                    // scaled is guaranteed to fit signed INT8 here.
                    requant_model =
                        $signed(
                            scaled[31:0]
                        );

                end

            end

        end

    endfunction


    // ============================================================
    // Cycle counter
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            cycle_count <=
                0;

        end else begin

            cycle_count <=
                cycle_count +
                1;

        end

    end


    // ============================================================
    // AXI Read Address monitor
    //
    // Also consumes/checks ARID so -Wall sees every interface
    // signal being meaningfully verified.
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            total_ar_count <=
                0;

            descriptor_ar_count <=
                0;

            operand_ar_count <=
                0;

            global_param_ar_count <=
                0;

            bias_ar_count <=
                0;

        end else if (
            axi_arvalid &&
            axi_arready
        ) begin

            // ----------------------------------------------------
            // Common AXI protocol checks
            // ----------------------------------------------------

            if (
                axi_arid !=
                '0
            ) begin

                $fatal(
                    1,
                    "Unexpected ARID: %0d",
                    axi_arid
                );

            end


            if (
                axi_arsize !=
                3'd2
            ) begin

                $fatal(
                    1,
                    "ARSIZE must be 2 for 32-bit AXI"
                );

            end


            if (
                axi_arburst !=
                2'b01
            ) begin

                $fatal(
                    1,
                    "ARBURST must be INCR"
                );

            end


            total_ar_count <=
                total_ar_count +
                1;


            // ----------------------------------------------------
            // Descriptor
            //
            // 3 descriptors × 64 bytes = 192 bytes
            // ----------------------------------------------------

            if (
                (axi_araddr >= DESC_BASE) &&
                (
                    axi_araddr <
                    (
                        DESC_BASE +
                        ADDR_WIDTH'(192)
                    )
                )
            ) begin

                descriptor_ar_count <=
                    descriptor_ar_count +
                    1;


                if (
                    axi_arlen !=
                    8'd0
                ) begin

                    $fatal(
                        1,
                        "Descriptor read must be one beat"
                    );

                end

            end

            // ----------------------------------------------------
            // Global per-tensor M/R
            //
            // param_base + 0x00:
            //     M
            //
            // param_base + 0x04:
            //     R
            //
            // One 2-beat burst.
            // ----------------------------------------------------

            else if (
                axi_araddr ==
                PARAM_BASE
            ) begin

                global_param_ar_count <=
                    global_param_ar_count +
                    1;


                if (
                    axi_arlen !=
                    8'd1
                ) begin

                    $fatal(
                        1,
                        "Global M/R request must contain 2 beats"
                    );

                end

            end

            // ----------------------------------------------------
            // Bias parameter region
            //
            // param_base + 0x10 ...
            // ----------------------------------------------------

            else if (
                (
                    axi_araddr >=
                    (
                        PARAM_BASE +
                        64'd16
                    )
                ) &&
                (
                    axi_araddr <
                    (
                        PARAM_BASE +
                        64'd16 +
                        ADDR_WIDTH'(
                            N_TOTAL *
                            4
                        )
                    )
                )
            ) begin

                bias_ar_count <=
                    bias_ar_count +
                    1;


                if (
                    axi_arlen !=
                    8'd3
                ) begin

                    $fatal(
                        1,
                        "Bias request must contain 4 beats"
                    );

                end

            end

            // ----------------------------------------------------
            // A/B operand traffic
            // ----------------------------------------------------

            else begin

                operand_ar_count <=
                    operand_ar_count +
                    1;

            end

        end

    end


    // ============================================================
    // AXI Read Slave
    // ============================================================

    assign axi_arready =
        !rd_active_q &&
        !axi_rvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            rd_active_q <=
                1'b0;

            rd_addr_q <=
                '0;

            rd_beats_left_q <=
                '0;

            axi_rid <=
                '0;

            axi_rdata <=
                '0;

            axi_rresp <=
                2'b00;

            axi_rlast <=
                1'b0;

            axi_rvalid <=
                1'b0;

        end else begin

            // ----------------------------------------------------
            // Accept new AR burst
            // ----------------------------------------------------

            if (
                axi_arvalid &&
                axi_arready
            ) begin

                rd_active_q <=
                    1'b1;

                rd_addr_q <=
                    axi_araddr;

                rd_beats_left_q <=
                    {1'b0, axi_arlen} +
                    9'd1;

            end


            // ----------------------------------------------------
            // Current R beat consumed
            // ----------------------------------------------------

            if (
                axi_rvalid &&
                axi_rready
            ) begin

                axi_rvalid <=
                    1'b0;


                if (
                    rd_beats_left_q ==
                    9'd1
                ) begin

                    rd_active_q <=
                        1'b0;

                    rd_beats_left_q <=
                        '0;

                end else begin

                    rd_beats_left_q <=
                        rd_beats_left_q -
                        9'd1;

                    rd_addr_q <=
                        rd_addr_q +
                        ADDR_WIDTH'(
                            WORD_BYTES
                        );

                end

            end


            // ----------------------------------------------------
            // Produce next R beat
            // ----------------------------------------------------

            if (
                rd_active_q &&
                !axi_rvalid
            ) begin

                axi_rid <=
                    '0;

                axi_rdata <=
                    read_memory[
                        rd_addr_q[14:2]
                    ];

                axi_rresp <=
                    2'b00;

                axi_rlast <=
                    (
                        rd_beats_left_q ==
                        9'd1
                    );

                axi_rvalid <=
                    1'b1;

            end

        end

    end


    // ============================================================
    // AXI Write Slave
    // ============================================================

    assign axi_awready =
        !wr_active_q &&
        !axi_bvalid;


    assign axi_wready =
        wr_active_q &&
        !axi_bvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            wr_active_q <=
                1'b0;

            wr_addr_q <=
                '0;

            wr_beats_left_q <=
                '0;

            wr_id_q <=
                '0;

            axi_bid <=
                '0;

            axi_bresp <=
                2'b00;

            axi_bvalid <=
                1'b0;

            aw_count <=
                0;

            w_count <=
                0;

            b_count <=
                0;

        end else begin

            // ----------------------------------------------------
            // AW handshake
            // ----------------------------------------------------

            if (
                axi_awvalid &&
                axi_awready
            ) begin

                // ------------------------------------------------
                // Common AXI protocol checks
                // ------------------------------------------------

                if (
                    axi_awid !=
                    '0
                ) begin

                    $fatal(
                        1,
                        "Unexpected AWID: %0d",
                        axi_awid
                    );

                end


                if (
                    axi_awsize !=
                    3'd2
                ) begin

                    $fatal(
                        1,
                        "AWSIZE must be 2 for 32-bit AXI"
                    );

                end


                if (
                    axi_awburst !=
                    2'b01
                ) begin

                    $fatal(
                        1,
                        "AWBURST must be INCR"
                    );

                end


                // ------------------------------------------------
                // INT8 output:
                //
                // C2 is packed as four INT8 values per 32-bit beat.
                //
                // One PE row:
                //
                //     4 × INT8 = 32 bit
                //
                // therefore AWLEN = 0.
                // ------------------------------------------------

                if (
                    (axi_awaddr >= C2_BASE) &&
                    (
                        axi_awaddr <
                        (
                            C2_BASE +
                            ADDR_WIDTH'(
                                M_TOTAL *
                                N_TOTAL
                            )
                        )
                    )
                ) begin

                    if (
                        axi_awlen !=
                        8'd0
                    ) begin

                        $fatal(
                            1,
                            "INT8 output row must be 1 beat"
                        );

                    end

                end else begin

                    // --------------------------------------------
                    // INT32 output:
                    //
                    // 4 × INT32 = 128 bit
                    //           = 4 × 32-bit AXI beats
                    //
                    // therefore AWLEN = 3.
                    // --------------------------------------------

                    if (
                        axi_awlen !=
                        8'd3
                    ) begin

                        $fatal(
                            1,
                            "INT32 output row must be 4 beats"
                        );

                    end

                end


                aw_count <=
                    aw_count +
                    1;


                wr_active_q <=
                    1'b1;

                wr_addr_q <=
                    axi_awaddr;

                wr_beats_left_q <=
                    {1'b0, axi_awlen} +
                    9'd1;

                wr_id_q <=
                    axi_awid;

            end


            // ----------------------------------------------------
            // W handshake
            // ----------------------------------------------------

            if (
                axi_wvalid &&
                axi_wready
            ) begin

                if (
                    axi_wstrb !=
                    {WORD_BYTES{1'b1}}
                ) begin

                    $fatal(
                        1,
                        "Unexpected WSTRB: %b",
                        axi_wstrb
                    );

                end


                if (
                    axi_wlast !=
                    (
                        wr_beats_left_q ==
                        9'd1
                    )
                ) begin

                    $fatal(
                        1,
                        "WLAST mismatch"
                    );

                end


                write_memory[
                    wr_addr_q[14:2]
                ] <=
                    axi_wdata;


                w_count <=
                    w_count +
                    1;


                if (
                    wr_beats_left_q ==
                    9'd1
                ) begin

                    wr_active_q <=
                        1'b0;

                    wr_beats_left_q <=
                        '0;


                    axi_bid <=
                        wr_id_q;

                    axi_bresp <=
                        2'b00;

                    axi_bvalid <=
                        1'b1;

                end else begin

                    wr_beats_left_q <=
                        wr_beats_left_q -
                        9'd1;

                    wr_addr_q <=
                        wr_addr_q +
                        ADDR_WIDTH'(
                            WORD_BYTES
                        );

                end

            end


            // ----------------------------------------------------
            // B handshake
            // ----------------------------------------------------

            if (
                axi_bvalid &&
                axi_bready
            ) begin

                axi_bvalid <=
                    1'b0;

                b_count <=
                    b_count +
                    1;

            end

        end

    end


    // ============================================================
    // Initialize one INT8 A/B row
    //
    // Four equal INT8 values are packed in every 32-bit memory word.
    // ============================================================

    task automatic fill_ab_row (
        input int unsigned base_word,
        input logic [7:0]  value
    );

        integer word_idx;

        begin

            for (
                word_idx = 0;
                word_idx < WORDS_PER_AB_ROW;
                word_idx = word_idx + 1
            ) begin

                read_memory[
                    base_word +
                    word_idx
                ] = {
                    value,
                    value,
                    value,
                    value
                };

            end

        end

    endtask


    // ============================================================
    // Descriptor writer
    //
    // flags[0] = BIAS_EN
    // flags[1] = REQUANT_EN
    // flags[2] = RELU_EN
    //
    // param1:param0 = param_base
    // ============================================================

    task automatic write_descriptor (
        input int unsigned desc_word_base_value,

        input logic bias_en,
        input logic requant_en,
        input logic relu_en,

        input logic [63:0] c_base_value,

        input int unsigned c_stride_value
    );

        logic [23:0]
            flags;

        begin

            flags =
                '0;

            flags[0] =
                bias_en;

            flags[1] =
                requant_en;

            flags[2] =
                relu_en;


            // ----------------------------------------------------
            // word 0:
            //
            // [7:0]  = opcode = GEMM
            // [31:8] = flags
            // ----------------------------------------------------

            read_memory[
                desc_word_base_value + 0
            ] = {
                flags,
                8'h01
            };


            // M
            read_memory[
                desc_word_base_value + 1
            ] =
                32'(M_TOTAL);


            // N
            read_memory[
                desc_word_base_value + 2
            ] =
                32'(N_TOTAL);


            // K
            read_memory[
                desc_word_base_value + 3
            ] =
                32'(K_TOTAL);


            // A base
            read_memory[
                desc_word_base_value + 4
            ] =
                A_BASE[31:0];

            read_memory[
                desc_word_base_value + 5
            ] =
                A_BASE[63:32];


            // B^T base
            read_memory[
                desc_word_base_value + 6
            ] =
                BT_BASE[31:0];

            read_memory[
                desc_word_base_value + 7
            ] =
                BT_BASE[63:32];


            // C base
            read_memory[
                desc_word_base_value + 8
            ] =
                c_base_value[31:0];

            read_memory[
                desc_word_base_value + 9
            ] =
                c_base_value[63:32];


            // A stride
            read_memory[
                desc_word_base_value + 10
            ] =
                32'(
                    AB_STRIDE_BYTES
                );


            // B stride
            read_memory[
                desc_word_base_value + 11
            ] =
                32'(
                    AB_STRIDE_BYTES
                );


            // C stride
            read_memory[
                desc_word_base_value + 12
            ] =
                32'(
                    c_stride_value
                );


            // ----------------------------------------------------
            // param_base
            // ----------------------------------------------------

            if (
                bias_en ||
                requant_en
            ) begin

                read_memory[
                    desc_word_base_value + 13
                ] =
                    PARAM_BASE[31:0];

                read_memory[
                    desc_word_base_value + 14
                ] =
                    PARAM_BASE[63:32];

            end else begin

                read_memory[
                    desc_word_base_value + 13
                ] =
                    32'd0;

                read_memory[
                    desc_word_base_value + 14
                ] =
                    32'd0;

            end


            // reserved
            read_memory[
                desc_word_base_value + 15
            ] =
                32'd0;

        end

    endtask


    // ============================================================
    // INT32 output checker
    // ============================================================

    task automatic check_int32_matrix (
        input int unsigned c_word_base_value,
        input logic        bias_en
    );

        integer row_idx;
        integer col_idx;

        integer signed
            expected;

        logic signed [31:0]
            actual;

        begin

            for (
                row_idx = 0;
                row_idx < M_TOTAL;
                row_idx = row_idx + 1
            ) begin

                for (
                    col_idx = 0;
                    col_idx < N_TOTAL;
                    col_idx = col_idx + 1
                ) begin

                    actual =
                        $signed(
                            write_memory[
                                c_word_base_value +
                                (
                                    row_idx *
                                    N_TOTAL
                                ) +
                                col_idx
                            ]
                        );


                    // --------------------------------------------
                    // A[i][k] = i+1
                    // B^T[j][k] = j+1
                    //
                    // therefore:
                    //
                    // C[i][j] =
                    // K * (i+1) * (j+1)
                    // --------------------------------------------

                    expected =
                        K_TOTAL *
                        (row_idx + 1) *
                        (col_idx + 1);


                    if (bias_en) begin

                        expected =
                            expected -
                            (
                                1000 *
                                (col_idx + 1)
                            );

                    end


                    if (
                        actual !==
                        expected
                    ) begin

                        $fatal(
                            1,
                            "INT32 C[%0d][%0d] got %0d expected %0d",
                            row_idx,
                            col_idx,
                            actual,
                            expected
                        );

                    end

                end

            end

        end

    endtask


    // ============================================================
    // Packed INT8 output checker
    //
    // DDR layout:
    //
    // one 32-bit word =
    //
    // bits  7:0  -> q0
    // bits 15:8  -> q1
    // bits 23:16 -> q2
    // bits 31:24 -> q3
    // ============================================================

    task automatic check_int8_matrix;

        integer row_idx;
        integer col_idx;

        integer signed
            raw_value;

        integer signed
            adjusted_value;

        integer signed
            expected;


        logic [31:0]
            packed_word;

        logic signed [7:0]
            actual;

        logic signed [31:0]
            actual_ext;

        begin

            for (
                row_idx = 0;
                row_idx < M_TOTAL;
                row_idx = row_idx + 1
            ) begin

                for (
                    col_idx = 0;
                    col_idx < N_TOTAL;
                    col_idx = col_idx + 1
                ) begin

                    // --------------------------------------------
                    // Each 32-bit word contains 4 INT8 values.
                    //
                    // N=8 therefore gives 2 words per matrix row.
                    // --------------------------------------------

                    packed_word =
                        write_memory[
                            C2_WORD_BASE +
                            (
                                row_idx *
                                (
                                    N_TOTAL /
                                    4
                                )
                            ) +
                            (
                                col_idx /
                                4
                            )
                        ];


                    actual =
                        $signed(
                            packed_word[
                                (
                                    (col_idx % 4) *
                                    8
                                )
                                +: 8
                            ]
                        );


                    // Explicit sign extension avoids WIDTHEXPAND
                    // when comparing against 32-bit integer.
                    actual_ext = {
                        {24{actual[7]}},
                        actual
                    };


                    raw_value =
                        K_TOTAL *
                        (row_idx + 1) *
                        (col_idx + 1);


                    adjusted_value =
                        raw_value -
                        (
                            1000 *
                            (col_idx + 1)
                        );


                    expected =
                        requant_model(
                            adjusted_value,
                            TEST_MULTIPLIER,
                            TEST_SHIFT,
                            1'b1
                        );


                    if (
                        actual_ext !==
                        expected
                    ) begin

                        $fatal(
                            1,
                            "INT8 C[%0d][%0d] got %0d expected %0d",
                            row_idx,
                            col_idx,
                            actual,
                            expected
                        );

                    end

                end

            end

        end

    endtask


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        repeat (
            TIMEOUT_CYCLES
        ) begin

            @(posedge clk);

        end


        $display("");
        $display("========================================");
        $display("NPU REQUANT TEST TIMEOUT");
        $display("========================================");

        $display(
            "cycles        = %0d",
            cycle_count
        );

        $display(
            "busy          = %b",
            npu_busy
        );

        $display(
            "done          = %b",
            npu_done
        );

        $display(
            "error         = %b",
            npu_error
        );

        $display(
            "descriptor AR = %0d",
            descriptor_ar_count
        );

        $display(
            "operand AR    = %0d",
            operand_ar_count
        );

        $display(
            "M/R AR        = %0d",
            global_param_ar_count
        );

        $display(
            "Bias AR       = %0d",
            bias_ar_count
        );

        $display("========================================");


        $fatal(
            1,
            "NPU requant integration test timeout"
        );

    end


    // ============================================================
    // Main test
    // ============================================================

    integer init_idx;

    initial begin

        reset =
            1'b1;

        start =
            1'b0;

        desc_base =
            DESC_BASE;

        desc_count =
            DESC_COUNT_WIDTH'(3);


        // ========================================================
        // Initialize memory
        // ========================================================

        for (
            init_idx = 0;
            init_idx < MEMORY_WORDS;
            init_idx = init_idx + 1
        ) begin

            read_memory[init_idx] =
                32'd0;

            write_memory[init_idx] =
                32'hDEAD_BEEF;

        end


        // ========================================================
        // A[i][k] = i + 1
        // ========================================================

        for (
            init_idx = 0;
            init_idx < M_TOTAL;
            init_idx = init_idx + 1
        ) begin

            fill_ab_row(
                A_WORD_BASE +
                (
                    init_idx *
                    WORDS_PER_AB_ROW
                ),
                8'(
                    init_idx +
                    1
                )
            );

        end


        // ========================================================
        // B^T[j][k] = j + 1
        // ========================================================

        for (
            init_idx = 0;
            init_idx < N_TOTAL;
            init_idx = init_idx + 1
        ) begin

            fill_ab_row(
                BT_WORD_BASE +
                (
                    init_idx *
                    WORDS_PER_AB_ROW
                ),
                8'(
                    init_idx +
                    1
                )
            );

        end


        // ========================================================
        // Parameter block
        //
        // +0x00 multiplier
        // +0x04 shift
        // +0x08 reserved
        // +0x0C reserved
        // +0x10 bias[0]
        // ...
        // ========================================================

        read_memory[
            PARAM_WORD_BASE + 0
        ] =
            32'(
                TEST_MULTIPLIER
            );


        read_memory[
            PARAM_WORD_BASE + 1
        ] =
            32'(
                TEST_SHIFT
            );


        read_memory[
            PARAM_WORD_BASE + 2
        ] =
            32'd0;


        read_memory[
            PARAM_WORD_BASE + 3
        ] =
            32'd0;


        // --------------------------------------------------------
        // Bias[j] = -1000 × (j+1)
        // --------------------------------------------------------

        for (
            init_idx = 0;
            init_idx < N_TOTAL;
            init_idx = init_idx + 1
        ) begin

            read_memory[
                PARAM_WORD_BASE +
                4 +
                init_idx
            ] =
                32'(
                    -1000 *
                    (
                        init_idx +
                        1
                    )
                );

        end


        // ========================================================
        // Descriptor 0
        //
        // A × B
        // -> INT32
        // ========================================================

        write_descriptor(
            DESC_WORD_BASE,
            1'b0,
            1'b0,
            1'b0,
            C0_BASE,
            C_INT32_STRIDE
        );


        // ========================================================
        // Descriptor 1
        //
        // A × B + Bias
        // -> INT32
        // ========================================================

        write_descriptor(
            DESC_WORD_BASE + 16,
            1'b1,
            1'b0,
            1'b0,
            C1_BASE,
            C_INT32_STRIDE
        );


        // ========================================================
        // Descriptor 2
        //
        // A × B + Bias
        // -> requant
        // -> ReLU
        // -> INT8
        // ========================================================

        write_descriptor(
            DESC_WORD_BASE + 32,
            1'b1,
            1'b1,
            1'b1,
            C2_BASE,
            C_INT8_STRIDE
        );


        // ========================================================
        // Reset release
        // ========================================================

        repeat (4) begin

            @(posedge clk);

        end


        @(negedge clk);

        reset =
            1'b0;


        // ========================================================
        // Launch all 3 descriptors
        // ========================================================

        @(negedge clk);

        start =
            1'b1;


        $display(
            "[%0t] NPU start: desc_base=0x%0h desc_count=%0d",
            $time,
            desc_base,
            desc_count
        );


        @(negedge clk);

        start =
            1'b0;


        wait (
            npu_busy ===
            1'b1
        );


        wait (
            npu_done ===
            1'b1
        );


        #1;


        // ========================================================
        // NPU status
        // ========================================================

        if (npu_error) begin

            $fatal(
                1,
                "NPU reported error"
            );

        end


        // ========================================================
        // Functional result checks
        // ========================================================

        check_int32_matrix(
            C0_WORD_BASE,
            1'b0
        );


        check_int32_matrix(
            C1_WORD_BASE,
            1'b1
        );


        check_int8_matrix();


        // ========================================================
        // RAW accumulator check
        //
        // Last calculated C tile is:
        //
        // rows 4..7
        // cols 4..7
        //
        // Therefore local acc_out[0][0] corresponds to:
        //
        // C[4][4]
        //
        // = 260 × 5 × 5
        // = 6500
        //
        // This proves Bias/Requant/ReLU are outside the PE/C
        // accumulator datapath.
        // ========================================================

        if (
            acc_out[0][0] !==
            32'sd6500
        ) begin

            $fatal(
                1,
                "RAW accumulator changed by postprocess: got %0d expected 6500",
                acc_out[0][0]
            );

        end


        // ========================================================
        // AXI Read traffic
        // ========================================================

        // 3 descriptors × 16 words
        if (
            descriptor_ar_count !=
            48
        ) begin

            $fatal(
                1,
                "Expected 48 descriptor AR, got %0d",
                descriptor_ar_count
            );

        end


        // 64 operand requests per GEMM × 3.
        if (
            operand_ar_count !=
            192
        ) begin

            $fatal(
                1,
                "Expected 192 operand AR, got %0d",
                operand_ar_count
            );

        end


        // Only descriptor 2 enables requant.
        //
        // Per-tensor M/R must be loaded exactly once.
        if (
            global_param_ar_count !=
            1
        ) begin

            $fatal(
                1,
                "Expected one M/R load, got %0d",
                global_param_ar_count
            );

        end


        // Descriptor 1:
        //     4 output C tiles -> 4 Bias loads
        //
        // Descriptor 2:
        //     4 output C tiles -> 4 Bias loads
        //
        // total = 8.
        if (
            bias_ar_count !=
            8
        ) begin

            $fatal(
                1,
                "Expected 8 Bias loads, got %0d",
                bias_ar_count
            );

        end


        if (
            total_ar_count !=
            249
        ) begin

            $fatal(
                1,
                "Expected 249 total AR, got %0d",
                total_ar_count
            );

        end


        // ========================================================
        // AXI Write traffic
        // ========================================================

        // 16 C rows per descriptor × 3.
        if (
            aw_count !=
            48
        ) begin

            $fatal(
                1,
                "Expected 48 AW requests, got %0d",
                aw_count
            );

        end


        // --------------------------------------------------------
        // Descriptor 0:
        //
        // 16 rows × 4 INT32 beats
        // = 64
        //
        // Descriptor 1:
        //
        // 16 rows × 4 INT32 beats
        // = 64
        //
        // Descriptor 2:
        //
        // 16 rows × 1 packed INT8 beat
        // = 16
        //
        // total:
        //
        // 64 + 64 + 16 = 144
        // --------------------------------------------------------

        if (
            w_count !=
            144
        ) begin

            $fatal(
                1,
                "Expected 144 W beats, got %0d",
                w_count
            );

        end


        if (
            b_count !=
            48
        ) begin

            $fatal(
                1,
                "Expected 48 B responses, got %0d",
                b_count
            );

        end


        // ========================================================
        // Final report
        // ========================================================

        $display("");
        $display("========================================");
        $display("REQUANT NPU TEST PASSED");
        $display("========================================");

        $display(
            "descriptor AR       = %0d",
            descriptor_ar_count
        );

        $display(
            "operand AR          = %0d",
            operand_ar_count
        );

        $display(
            "M/R loads           = %0d",
            global_param_ar_count
        );

        $display(
            "Bias loads          = %0d",
            bias_ar_count
        );

        $display(
            "total AR            = %0d",
            total_ar_count
        );

        $display(
            "AW requests         = %0d",
            aw_count
        );

        $display(
            "write beats         = %0d",
            w_count
        );

        $display(
            "total cycles        = %0d",
            cycle_count
        );

        $display(
            "RAW final C[4][4]   = %0d",
            acc_out[0][0]
        );

        $display("");
        $display("pure GEMM INT32            = PASS");
        $display("GEMM + Bias INT32          = PASS");
        $display("Bias + Requant + ReLU INT8 = PASS");

        $display("========================================");
        $display("");

        $finish;

    end

endmodule
