
module npu_top #(
    parameter int unsigned ADDR_WIDTH       = 64,
    parameter int unsigned DESC_COUNT_WIDTH = 16,
    parameter int unsigned TILE_COUNT_WIDTH = 16,

    parameter int unsigned ROWS             = 4,
    parameter int unsigned COLS             = 4,

    parameter int unsigned DATA_WIDTH       = 8,
    parameter int unsigned ACC_WIDTH        = 32,
    parameter int unsigned MEM_WORD_WIDTH   = 32,

    parameter int unsigned ID_WIDTH         = 1,
    parameter int unsigned K_TILE_SIZE      = 256,

    parameter int unsigned A_BUFFER_COUNT   = 2,
    parameter int unsigned B_BUFFER_COUNT   = 2
) (
    input logic clk,
    input logic reset,

    input logic start,
    input logic [63:0] desc_base,
    input logic [DESC_COUNT_WIDTH-1:0] desc_count,

    output logic busy,
    output logic done,
    output logic error,

    output logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS],

    // AXI read
    output logic [ID_WIDTH-1:0]       m_axi_arid,
    output logic [ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    input  logic [ID_WIDTH-1:0]       m_axi_rid,
    input  logic [MEM_WORD_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready,

    // AXI write
    output logic [ID_WIDTH-1:0]       m_axi_awid,
    output logic [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    output logic [MEM_WORD_WIDTH-1:0] m_axi_wdata,
    output logic [(MEM_WORD_WIDTH/8)-1:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input  logic m_axi_wready,

    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [1:0]          m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready
);

    localparam logic [7:0] OPCODE_GEMM = 8'h01;
    localparam logic [7:0] OPCODE_CONV = 8'h02;

    // ============================================================
    // Descriptor frontend
    // ============================================================

    logic frontend_mem_read_req;
    logic [63:0] frontend_mem_read_addr;
    logic frontend_mem_read_ready;
    logic frontend_mem_read_valid;
    logic [31:0] frontend_mem_read_data;

    logic frontend_cmd_valid;
    logic frontend_cmd_ready;
    logic [7:0] frontend_cmd_opcode;
    logic [23:0] frontend_cmd_flags;

    logic [31:0] frontend_cfg_m;
    logic [31:0] frontend_cfg_n;
    logic [31:0] frontend_cfg_k;

    logic [63:0] frontend_cfg_a_base;
    logic [63:0] frontend_cfg_b_base;
    logic [63:0] frontend_cfg_c_base;

    logic [31:0] frontend_cfg_a_stride;
    logic [31:0] frontend_cfg_b_stride;
    logic [31:0] frontend_cfg_c_stride;

    logic [31:0] frontend_cfg_param0;
    logic [31:0] frontend_cfg_param1;

    logic frontend_exec_done;
    logic frontend_busy;
    logic frontend_done;

    logic frontend_bias_en;
    logic frontend_requant_en;
    logic frontend_relu_en;

    assign frontend_bias_en    = frontend_cmd_flags[0];
    assign frontend_requant_en = frontend_cmd_flags[1];
    assign frontend_relu_en    = frontend_cmd_flags[2];

    // ============================================================
    // Conv2D descriptor
    //
    // word10: {Win[15:0], Hin[15:0]}
    // word11: {Kw[7:0], Kh[7:0], Cin[15:0]}
    // word12: {PadLeft, PadTop, StrideW, StrideH}
    // ============================================================

    logic conv_mode;
    logic [31:0] conv_input_h;
    logic [31:0] conv_input_w;
    logic [31:0] conv_input_c;
    logic [31:0] conv_kernel_h;
    logic [31:0] conv_kernel_w;
    logic [31:0] conv_stride_h;
    logic [31:0] conv_stride_w;
    logic [31:0] conv_pad_top;
    logic [31:0] conv_pad_left;
    logic [31:0] conv_output_w;
    logic [31:0] conv_output_positions;

    logic [63:0] conv_padded_h;
    logic [63:0] conv_padded_w;
    logic [63:0] conv_hout_calc;
    logic [63:0] conv_wout_calc;
    logic [63:0] conv_m_calc;
    logic [63:0] conv_k_calc;
    logic [63:0] conv_b_stride_calc;
    logic [63:0] conv_c_stride_calc;

    logic conv_geometry_valid;
    logic common_flags_valid;
    logic descriptor_supported;

    logic [31:0] exec_a_stride;
    logic [31:0] exec_b_stride;
    logic [31:0] exec_c_stride;

    assign conv_mode =
        (frontend_cmd_opcode == OPCODE_CONV);

    assign conv_input_h = {
        16'd0, frontend_cfg_a_stride[15:0]
    };

    assign conv_input_w = {
        16'd0, frontend_cfg_a_stride[31:16]
    };

    assign conv_input_c = {
        16'd0, frontend_cfg_b_stride[15:0]
    };

    assign conv_kernel_h = {
        24'd0, frontend_cfg_b_stride[23:16]
    };

    assign conv_kernel_w = {
        24'd0, frontend_cfg_b_stride[31:24]
    };

    assign conv_stride_h = {
        24'd0, frontend_cfg_c_stride[7:0]
    };

    assign conv_stride_w = {
        24'd0, frontend_cfg_c_stride[15:8]
    };

    assign conv_pad_top = {
        24'd0, frontend_cfg_c_stride[23:16]
    };

    assign conv_pad_left = {
        24'd0, frontend_cfg_c_stride[31:24]
    };

    // ============================================================
    // Conv2D geometry
    // ============================================================

    always_comb begin

        conv_padded_h =
            64'(conv_input_h) +
            (64'(conv_pad_top) << 1);

        conv_padded_w =
            64'(conv_input_w) +
            (64'(conv_pad_left) << 1);

        conv_hout_calc = 64'd0;
        conv_wout_calc = 64'd0;

        if (
            (conv_kernel_h != 32'd0) &&
            (conv_padded_h >= 64'(conv_kernel_h))
        ) begin

            if (conv_stride_h == 32'd1) begin

                conv_hout_calc =
                    conv_padded_h -
                    64'(conv_kernel_h) +
                    64'd1;

            end else if (conv_stride_h == 32'd2) begin

                conv_hout_calc =
                    (
                        (conv_padded_h - 64'(conv_kernel_h)) >> 1
                    ) + 64'd1;

            end

        end

        if (
            (conv_kernel_w != 32'd0) &&
            (conv_padded_w >= 64'(conv_kernel_w))
        ) begin

            if (conv_stride_w == 32'd1) begin

                conv_wout_calc =
                    conv_padded_w -
                    64'(conv_kernel_w) +
                    64'd1;

            end else if (conv_stride_w == 32'd2) begin

                conv_wout_calc =
                    (
                        (conv_padded_w - 64'(conv_kernel_w)) >> 1
                    ) + 64'd1;

            end

        end

        conv_m_calc =
            conv_hout_calc * conv_wout_calc;

        conv_k_calc =
            64'(conv_kernel_h) *
            64'(conv_kernel_w) *
            64'(conv_input_c);

        conv_b_stride_calc =
            (64'(frontend_cfg_k) + 64'd3) &
            64'hffff_ffff_ffff_fffc;

        conv_c_stride_calc =
            64'(frontend_cfg_n) *
            (frontend_requant_en ? 64'd1 : 64'd4);

    end

    assign conv_output_w =
        32'(conv_wout_calc);

    assign conv_output_positions =
        32'(conv_m_calc);

    // ============================================================
    // Command validation
    // ============================================================

    assign common_flags_valid =
        (frontend_cmd_flags[23:3] == 21'd0) &&
        !(frontend_relu_en && !frontend_requant_en) &&
        (
            frontend_bias_en ||
            frontend_requant_en ||
            (
                (frontend_cfg_param0 == 32'd0) &&
                (frontend_cfg_param1 == 32'd0)
            )
        );

    assign conv_geometry_valid =
        (conv_input_h != 32'd0) &&
        (conv_input_w != 32'd0) &&
        (conv_input_c != 32'd0) &&
        (conv_kernel_h != 32'd0) &&
        (conv_kernel_w != 32'd0) &&

        (
            (conv_stride_h == 32'd1) ||
            (conv_stride_h == 32'd2)
        ) &&

        (
            (conv_stride_w == 32'd1) ||
            (conv_stride_w == 32'd2)
        ) &&

        (conv_m_calc != 64'd0) &&
        (conv_wout_calc <= 64'hffff_ffff) &&

        (conv_m_calc == 64'(frontend_cfg_m)) &&
        (conv_k_calc == 64'(frontend_cfg_k)) &&

        (frontend_cfg_n != 32'd0) &&

        (
            frontend_cfg_m % 32'(ROWS) ==
            32'd0
        ) &&

        (
            frontend_cfg_n % 32'(COLS) ==
            32'd0
        ) &&

        (conv_b_stride_calc <= 64'hffff_ffff) &&
        (conv_c_stride_calc <= 64'hffff_ffff) &&

        (frontend_cfg_b_base[1:0] == 2'b00) &&
        (frontend_cfg_c_base[1:0] == 2'b00);

    assign descriptor_supported =
        common_flags_valid &&
        (
            (frontend_cmd_opcode == OPCODE_GEMM) ||
            (conv_mode && conv_geometry_valid)
        );

    // ============================================================
    // Execution strides
    // ============================================================

    assign exec_a_stride =
        conv_mode ?
            32'd0 :
            frontend_cfg_a_stride;

    assign exec_b_stride =
        conv_mode ?
            32'(conv_b_stride_calc) :
            frontend_cfg_b_stride;

    assign exec_c_stride =
        conv_mode ?
            32'(conv_c_stride_calc) :
            frontend_cfg_c_stride;

    // ============================================================
    // Command handshake
    // ============================================================

    logic executor_cmd_valid;
    logic executor_cmd_ready;

    logic executor_busy;
    logic executor_done;
    logic executor_error;

    logic unsupported_accept;
    logic unsupported_pending_q;

    assign executor_cmd_valid =
        frontend_cmd_valid &&
        descriptor_supported;

    assign frontend_cmd_ready =
        descriptor_supported ?
            executor_cmd_ready :
            1'b1;

    assign unsupported_accept =
        frontend_cmd_valid &&
        frontend_cmd_ready &&
        !descriptor_supported;

    always_ff @(posedge clk) begin

        if (reset) begin

            unsupported_pending_q <= 1'b0;

        end else begin

            if (unsupported_pending_q)
                unsupported_pending_q <= 1'b0;

            if (unsupported_accept)
                unsupported_pending_q <= 1'b1;

        end

    end

    assign frontend_exec_done =
        executor_done ||
        unsupported_pending_q;

    // ============================================================
    // Command frontend
    // ============================================================

    command_frontend #(
        .DESC_COUNT_WIDTH (DESC_COUNT_WIDTH)
    ) u_command_frontend (
        .clk           (clk),
        .reset         (reset),

        .start         (start),
        .desc_base     (desc_base),
        .desc_count    (desc_count),

        .mem_read_req  (frontend_mem_read_req),
        .mem_read_addr (frontend_mem_read_addr),
        .mem_read_ready(frontend_mem_read_ready),
        .mem_read_valid(frontend_mem_read_valid),
        .mem_read_data (frontend_mem_read_data),

        .cmd_valid     (frontend_cmd_valid),
        .cmd_ready     (frontend_cmd_ready),
        .cmd_opcode    (frontend_cmd_opcode),
        .cmd_flags     (frontend_cmd_flags),

        .cfg_m         (frontend_cfg_m),
        .cfg_n         (frontend_cfg_n),
        .cfg_k         (frontend_cfg_k),

        .cfg_a_base    (frontend_cfg_a_base),
        .cfg_b_base    (frontend_cfg_b_base),
        .cfg_c_base    (frontend_cfg_c_base),

        .cfg_a_stride  (frontend_cfg_a_stride),
        .cfg_b_stride  (frontend_cfg_b_stride),
        .cfg_c_stride  (frontend_cfg_c_stride),

        .cfg_param0    (frontend_cfg_param0),
        .cfg_param1    (frontend_cfg_param1),

        .exec_done     (frontend_exec_done),
        .busy          (frontend_busy),
        .done          (frontend_done)
    );

    // ============================================================
    // Descriptor AXI master
    // ============================================================

    logic desc_req_ready;
    logic desc_data_valid;
    logic desc_data_ready;
    logic [MEM_WORD_WIDTH-1:0] desc_data;
    logic desc_data_last;

    logic desc_axi_busy;
    logic desc_axi_done;
    logic desc_axi_error;

    logic [ID_WIDTH-1:0] desc_axi_arid;
    logic [ADDR_WIDTH-1:0] desc_axi_araddr;
    logic [7:0] desc_axi_arlen;
    logic [2:0] desc_axi_arsize;
    logic [1:0] desc_axi_arburst;
    logic desc_axi_arvalid;
    logic desc_axi_arready;

    logic [ID_WIDTH-1:0] desc_axi_rid;
    logic [MEM_WORD_WIDTH-1:0] desc_axi_rdata;
    logic [1:0] desc_axi_rresp;
    logic desc_axi_rlast;
    logic desc_axi_rvalid;
    logic desc_axi_rready;

    assign frontend_mem_read_ready = desc_req_ready;
    assign desc_data_ready = 1'b1;

    assign frontend_mem_read_valid =
        desc_data_valid && desc_data_last;

    assign frontend_mem_read_data = desc_data;

    axi_read_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_descriptor_read_master (
        .clk          (clk),
        .reset        (reset),

        .req_valid    (frontend_mem_read_req),
        .req_ready    (desc_req_ready),
        .req_addr     (ADDR_WIDTH'(frontend_mem_read_addr)),
        .req_beats    (32'd1),

        .data_valid   (desc_data_valid),
        .data_ready   (desc_data_ready),
        .data         (desc_data),
        .data_last    (desc_data_last),

        .busy         (desc_axi_busy),
        .done         (desc_axi_done),
        .error        (desc_axi_error),

        .m_axi_arid   (desc_axi_arid),
        .m_axi_araddr (desc_axi_araddr),
        .m_axi_arlen  (desc_axi_arlen),
        .m_axi_arsize (desc_axi_arsize),
        .m_axi_arburst(desc_axi_arburst),
        .m_axi_arvalid(desc_axi_arvalid),
        .m_axi_arready(desc_axi_arready),

        .m_axi_rid    (desc_axi_rid),
        .m_axi_rdata  (desc_axi_rdata),
        .m_axi_rresp  (desc_axi_rresp),
        .m_axi_rlast  (desc_axi_rlast),
        .m_axi_rvalid (desc_axi_rvalid),
        .m_axi_rready (desc_axi_rready)
    );

    // ============================================================
    // Executor
    // ============================================================

    logic [ID_WIDTH-1:0] gemm_axi_arid;
    logic [ADDR_WIDTH-1:0] gemm_axi_araddr;
    logic [7:0] gemm_axi_arlen;
    logic [2:0] gemm_axi_arsize;
    logic [1:0] gemm_axi_arburst;
    logic gemm_axi_arvalid;
    logic gemm_axi_arready;

    logic [ID_WIDTH-1:0] gemm_axi_rid;
    logic [MEM_WORD_WIDTH-1:0] gemm_axi_rdata;
    logic [1:0] gemm_axi_rresp;
    logic gemm_axi_rlast;
    logic gemm_axi_rvalid;
    logic gemm_axi_rready;

    gemm_executor #(
        .ADDR_WIDTH       (ADDR_WIDTH),
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
    ) u_gemm_executor (
        .clk                     (clk),
        .reset                   (reset),

        .cmd_valid               (executor_cmd_valid),
        .cmd_ready               (executor_cmd_ready),

        .cmd_m                   (frontend_cfg_m),
        .cmd_n                   (frontend_cfg_n),
        .cmd_k                   (frontend_cfg_k),

        .cmd_a_base              (ADDR_WIDTH'(frontend_cfg_a_base)),
        .cmd_b_base              (ADDR_WIDTH'(frontend_cfg_b_base)),
        .cmd_c_base              (ADDR_WIDTH'(frontend_cfg_c_base)),

        .cmd_a_stride_bytes      (exec_a_stride),
        .cmd_b_stride_bytes      (exec_b_stride),
        .cmd_c_stride_bytes      (exec_c_stride),

        .cmd_conv_mode           (conv_mode),
        .cmd_conv_input_h        (conv_input_h),
        .cmd_conv_input_w        (conv_input_w),
        .cmd_conv_input_c        (conv_input_c),
        .cmd_conv_kernel_h       (conv_kernel_h),
        .cmd_conv_kernel_w       (conv_kernel_w),
        .cmd_conv_stride_h       (conv_stride_h),
        .cmd_conv_stride_w       (conv_stride_w),
        .cmd_conv_pad_top        (conv_pad_top),
        .cmd_conv_pad_left       (conv_pad_left),
        .cmd_conv_output_w       (conv_output_w),
        .cmd_conv_output_positions(conv_output_positions),

        .cmd_bias_en             (frontend_bias_en),
        .cmd_requant_en          (frontend_requant_en),
        .cmd_relu_en             (frontend_relu_en),

        .cmd_param_base          (
            ADDR_WIDTH'({
                frontend_cfg_param1,
                frontend_cfg_param0
            })
        ),

        .busy                    (executor_busy),
        .done                    (executor_done),
        .error                   (executor_error),
        .acc_out                 (acc_out),

        .m_axi_arid              (gemm_axi_arid),
        .m_axi_araddr            (gemm_axi_araddr),
        .m_axi_arlen             (gemm_axi_arlen),
        .m_axi_arsize            (gemm_axi_arsize),
        .m_axi_arburst           (gemm_axi_arburst),
        .m_axi_arvalid           (gemm_axi_arvalid),
        .m_axi_arready           (gemm_axi_arready),

        .m_axi_rid               (gemm_axi_rid),
        .m_axi_rdata             (gemm_axi_rdata),
        .m_axi_rresp             (gemm_axi_rresp),
        .m_axi_rlast             (gemm_axi_rlast),
        .m_axi_rvalid            (gemm_axi_rvalid),
        .m_axi_rready            (gemm_axi_rready),

        .m_axi_awid              (m_axi_awid),
        .m_axi_awaddr            (m_axi_awaddr),
        .m_axi_awlen             (m_axi_awlen),
        .m_axi_awsize            (m_axi_awsize),
        .m_axi_awburst           (m_axi_awburst),
        .m_axi_awvalid           (m_axi_awvalid),
        .m_axi_awready           (m_axi_awready),

        .m_axi_wdata             (m_axi_wdata),
        .m_axi_wstrb             (m_axi_wstrb),
        .m_axi_wlast             (m_axi_wlast),
        .m_axi_wvalid            (m_axi_wvalid),
        .m_axi_wready            (m_axi_wready),

        .m_axi_bid               (m_axi_bid),
        .m_axi_bresp             (m_axi_bresp),
        .m_axi_bvalid            (m_axi_bvalid),
        .m_axi_bready            (m_axi_bready)
    );

    // ============================================================
    // Descriptor / executor AXI read mux
    // ============================================================

    axi_read_mux #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_axi_read_mux (
        .clk          (clk),
        .reset        (reset),

        .desc_arid    (desc_axi_arid),
        .desc_araddr  (desc_axi_araddr),
        .desc_arlen   (desc_axi_arlen),
        .desc_arsize  (desc_axi_arsize),
        .desc_arburst (desc_axi_arburst),
        .desc_arvalid (desc_axi_arvalid),
        .desc_arready (desc_axi_arready),

        .desc_rid     (desc_axi_rid),
        .desc_rdata   (desc_axi_rdata),
        .desc_rresp   (desc_axi_rresp),
        .desc_rlast   (desc_axi_rlast),
        .desc_rvalid  (desc_axi_rvalid),
        .desc_rready  (desc_axi_rready),

        .gemm_arid    (gemm_axi_arid),
        .gemm_araddr  (gemm_axi_araddr),
        .gemm_arlen   (gemm_axi_arlen),
        .gemm_arsize  (gemm_axi_arsize),
        .gemm_arburst (gemm_axi_arburst),
        .gemm_arvalid (gemm_axi_arvalid),
        .gemm_arready (gemm_axi_arready),

        .gemm_rid     (gemm_axi_rid),
        .gemm_rdata   (gemm_axi_rdata),
        .gemm_rresp   (gemm_axi_rresp),
        .gemm_rlast   (gemm_axi_rlast),
        .gemm_rvalid  (gemm_axi_rvalid),
        .gemm_rready  (gemm_axi_rready),

        .m_axi_arid   (m_axi_arid),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),

        .m_axi_rid    (m_axi_rid),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rresp  (m_axi_rresp),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rready (m_axi_rready)
    );

    // ============================================================
    // Status
    // ============================================================

    assign busy =
        frontend_busy ||
        executor_busy ||
        desc_axi_busy ||
        desc_axi_done ||
        unsupported_pending_q;

    assign done = frontend_done;

    always_ff @(posedge clk) begin

        if (reset) begin

            error <= 1'b0;

        end else begin

            if (start && !busy) begin

                error <= 1'b0;

            end else if (
                desc_axi_error ||
                executor_error ||
                unsupported_accept
            ) begin

                error <= 1'b1;

            end

        end

    end

    initial begin

        if (ADDR_WIDTH != 64)
            $fatal(1, "npu_top requires ADDR_WIDTH == 64");

        if (MEM_WORD_WIDTH != 32)
            $fatal(1, "npu_top requires MEM_WORD_WIDTH == 32");

        if ((ROWS < 1) || (COLS < 1))
            $fatal(1, "Invalid systolic array dimensions");

    end

endmodule
