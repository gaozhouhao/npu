
module npu_top #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DESC_COUNT_WIDTH = 16,
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned ID_WIDTH = 1,
    parameter int unsigned K_TILE_SIZE = 256,
    parameter int unsigned A_BUFFER_COUNT = 2,
    parameter int unsigned B_BUFFER_COUNT = 2
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

    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input  logic m_axi_arready,

    input  logic [ID_WIDTH-1:0] m_axi_rid,
    input  logic [MEM_WORD_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0] m_axi_rresp,
    input  logic m_axi_rlast,
    input  logic m_axi_rvalid,
    output logic m_axi_rready,

    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input  logic m_axi_awready,

    output logic [MEM_WORD_WIDTH-1:0] m_axi_wdata,
    output logic [(MEM_WORD_WIDTH/8)-1:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input  logic m_axi_wready,

    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [1:0] m_axi_bresp,
    input  logic m_axi_bvalid,
    output logic m_axi_bready

`ifdef NPU_PERF_ENABLE
    ,
    output logic [63:0] perf_total_cycles,
    output logic [63:0] perf_executor_cycles,
    output logic [63:0] perf_pool_cycles,
    output logic [63:0] perf_ar_transactions,
    output logic [63:0] perf_r_beats,
    output logic [63:0] perf_aw_transactions,
    output logic [63:0] perf_w_beats,
    output logic [63:0] perf_written_bytes,
    output logic [63:0] perf_ar_stall_cycles,
    output logic [63:0] perf_r_wait_cycles,
    output logic [63:0] perf_aw_stall_cycles,
    output logic [63:0] perf_w_stall_cycles,
    output logic [63:0] perf_b_wait_cycles,
    output logic perf_layer_done_pulse,
    output logic [31:0] perf_completed_layer_index,
    output logic [7:0] perf_completed_layer_opcode,
    output logic [63:0] perf_completed_layer_cycles,
    output logic [63:0] perf_completed_layer_executor_cycles,
    output logic [63:0] perf_completed_layer_pool_cycles,
    output logic [63:0] perf_completed_layer_ar,
    output logic [63:0] perf_completed_layer_r_beats,
    output logic [63:0] perf_completed_layer_aw,
    output logic [63:0] perf_completed_layer_w_beats
`endif
);

    localparam logic [7:0] OP_GEMM = 8'h01;
    localparam logic [7:0] OP_CONV = 8'h02;
    localparam logic [7:0] OP_MAXPOOL = 8'h03;

    // ============================================================
    // Internal AXI Bundles
    // ============================================================

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        logic [ADDR_WIDTH-1:0] addr;
        logic [7:0] len;
        logic [2:0] size;
        logic [1:0] burst;
        logic valid;
    } axar_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        logic [MEM_WORD_WIDTH-1:0] data;
        logic [1:0] resp;
        logic last;
        logic valid;
    } axr_t;

    typedef axar_t axaw_t;

    typedef struct packed {
        logic [MEM_WORD_WIDTH-1:0] data;
        logic [(MEM_WORD_WIDTH/8)-1:0] strb;
        logic last;
        logic valid;
    } axw_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        logic [1:0] resp;
        logic valid;
    } axb_t;

    axar_t desc_ar;
    axar_t exec_ar;
    axar_t pool_ar;
    axar_t selected_ar;

    axr_t desc_r;
    axr_t exec_r;
    axr_t pool_r;
    axr_t selected_r;

    axaw_t exec_aw;
    axaw_t pool_aw;

    axw_t exec_w;
    axw_t pool_w;

    axb_t exec_b;
    axb_t pool_b;

    logic desc_arready;
    logic desc_rready;
    logic exec_arready;
    logic exec_rready;
    logic pool_arready;
    logic pool_rready;
    logic selected_arready;
    logic selected_rready;
    logic exec_awready;
    logic pool_awready;
    logic exec_wready;
    logic pool_wready;
    logic exec_bready;
    logic pool_bready;

    // ============================================================
    // Command Frontend
    // ============================================================

    logic frontend_mem_read_req;
    logic frontend_mem_read_ready;
    logic frontend_mem_read_valid;
    logic [63:0] frontend_mem_read_addr;
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

    logic desc_axi_busy;
    logic desc_axi_done;
    logic desc_axi_error;

    logic desc_req_ready;
    logic desc_data_valid;
    logic desc_data_last;
    logic [MEM_WORD_WIDTH-1:0] desc_data;

    // ============================================================
    // Descriptor Decoding and Conv Geometry
    // ============================================================

    logic conv_mode;
    logic common_flags_valid;
    logic conv_geometry_valid;

    logic frontend_bias_en;
    logic frontend_requant_en;
    logic frontend_relu_en;

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

    logic [31:0] exec_a_stride;
    logic [31:0] exec_b_stride;
    logic [31:0] exec_c_stride;

    assign frontend_bias_en = frontend_cmd_flags[0];
    assign frontend_requant_en = frontend_cmd_flags[1];
    assign frontend_relu_en = frontend_cmd_flags[2];

    assign conv_mode = (frontend_cmd_opcode == OP_CONV);

    assign conv_input_h =
        {16'd0, frontend_cfg_a_stride[15:0]};
    assign conv_input_w =
        {16'd0, frontend_cfg_a_stride[31:16]};
    assign conv_input_c =
        {16'd0, frontend_cfg_b_stride[15:0]};

    assign conv_kernel_h =
        {24'd0, frontend_cfg_b_stride[23:16]};
    assign conv_kernel_w =
        {24'd0, frontend_cfg_b_stride[31:24]};

    assign conv_stride_h =
        {24'd0, frontend_cfg_c_stride[7:0]};
    assign conv_stride_w =
        {24'd0, frontend_cfg_c_stride[15:8]};
    assign conv_pad_top =
        {24'd0, frontend_cfg_c_stride[23:16]};
    assign conv_pad_left =
        {24'd0, frontend_cfg_c_stride[31:24]};

    assign common_flags_valid =
        frontend_cmd_flags[23:3] == 21'd0 &&
        !(frontend_relu_en && !frontend_requant_en) &&
        (
            frontend_bias_en ||
            frontend_requant_en ||
            (
                frontend_cfg_param0 == 32'd0 &&
                frontend_cfg_param1 == 32'd0
            )
        );

    always_comb begin
        conv_padded_h =
            64'(conv_input_h) + (64'(conv_pad_top) << 1);
        conv_padded_w =
            64'(conv_input_w) + (64'(conv_pad_left) << 1);

        conv_hout_calc = 64'd0;
        conv_wout_calc = 64'd0;

        if (
            conv_kernel_h != 32'd0 &&
            conv_padded_h >= 64'(conv_kernel_h)
        ) begin
            if (conv_stride_h == 32'd1)
                conv_hout_calc =
                    conv_padded_h - 64'(conv_kernel_h) + 64'd1;
            else if (conv_stride_h == 32'd2)
                conv_hout_calc =
                    ((conv_padded_h - 64'(conv_kernel_h)) >> 1)
                    + 64'd1;
        end

        if (
            conv_kernel_w != 32'd0 &&
            conv_padded_w >= 64'(conv_kernel_w)
        ) begin
            if (conv_stride_w == 32'd1)
                conv_wout_calc =
                    conv_padded_w - 64'(conv_kernel_w) + 64'd1;
            else if (conv_stride_w == 32'd2)
                conv_wout_calc =
                    ((conv_padded_w - 64'(conv_kernel_w)) >> 1)
                    + 64'd1;
        end

        conv_m_calc = conv_hout_calc * conv_wout_calc;
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

    assign conv_output_w = 32'(conv_wout_calc);
    assign conv_output_positions = 32'(conv_m_calc);

    assign conv_geometry_valid =
        conv_input_h != 32'd0 &&
        conv_input_w != 32'd0 &&
        conv_input_c != 32'd0 &&
        conv_kernel_h != 32'd0 &&
        conv_kernel_w != 32'd0 &&
        (conv_stride_h == 32'd1 || conv_stride_h == 32'd2) &&
        (conv_stride_w == 32'd1 || conv_stride_w == 32'd2) &&
        conv_m_calc != 64'd0 &&
        conv_wout_calc <= 64'hffff_ffff &&
        conv_m_calc == 64'(frontend_cfg_m) &&
        conv_k_calc == 64'(frontend_cfg_k) &&
        frontend_cfg_n != 32'd0 &&
        frontend_cfg_m % 32'(ROWS) == 32'd0 &&
        frontend_cfg_n % 32'(COLS) == 32'd0 &&
        conv_b_stride_calc <= 64'hffff_ffff &&
        conv_c_stride_calc <= 64'hffff_ffff &&
        frontend_cfg_b_base[1:0] == 2'b00 &&
        frontend_cfg_c_base[1:0] == 2'b00;

    assign exec_a_stride =
        conv_mode ? 32'd0 : frontend_cfg_a_stride;
    assign exec_b_stride =
        conv_mode ? 32'(conv_b_stride_calc) :
                    frontend_cfg_b_stride;
    assign exec_c_stride =
        conv_mode ? 32'(conv_c_stride_calc) :
                    frontend_cfg_c_stride;

    // ============================================================
    // Command Routing
    // ============================================================

    logic gemm_conv_cmd;
    logic pool_cmd;
    logic pool_descriptor_valid;
    logic descriptor_supported;
    logic unsupported_accept;
    logic unsupported_pending_q;

    logic executor_cmd_valid;
    logic executor_cmd_ready;
    logic executor_busy;
    logic executor_done;
    logic executor_error;

    logic pool_cmd_valid;
    logic pool_cmd_ready;
    logic pool_busy;
    logic pool_done;
    logic pool_error;
    logic pool_active_q;

    assign gemm_conv_cmd =
        (frontend_cmd_opcode == OP_GEMM) || conv_mode;

    assign pool_cmd =
        (frontend_cmd_opcode == OP_MAXPOOL);

    assign pool_descriptor_valid =
        pool_cmd &&
        frontend_cmd_flags == 24'd0 &&
        frontend_cfg_m >= 32'd2 &&
        frontend_cfg_n >= 32'd2 &&
        frontend_cfg_k != 32'd0 &&
        frontend_cfg_k[1:0] == 2'b00 &&
        frontend_cfg_a_base[1:0] == 2'b00 &&
        frontend_cfg_c_base[1:0] == 2'b00 &&
        frontend_cfg_b_base == 64'd0 &&
        frontend_cfg_a_stride == 32'd0 &&
        frontend_cfg_b_stride == 32'd0 &&
        frontend_cfg_c_stride == 32'd0 &&
        frontend_cfg_param0 == 32'd0 &&
        frontend_cfg_param1 == 32'd0;

    assign descriptor_supported =
        (
            gemm_conv_cmd &&
            common_flags_valid &&
            (!conv_mode || conv_geometry_valid)
        ) ||
        pool_descriptor_valid;

    assign executor_cmd_valid =
        frontend_cmd_valid &&
        descriptor_supported &&
        gemm_conv_cmd;

    assign pool_cmd_valid =
        frontend_cmd_valid &&
        pool_descriptor_valid &&
        !pool_active_q;

    assign frontend_cmd_ready =
        descriptor_supported ?
        (
            pool_cmd ?
            (pool_cmd_ready && !pool_active_q) :
            executor_cmd_ready
        ) :
        1'b1;

    assign unsupported_accept =
        frontend_cmd_valid &&
        frontend_cmd_ready &&
        !descriptor_supported;

    assign frontend_exec_done =
        executor_done ||
        pool_done ||
        unsupported_pending_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            unsupported_pending_q <= 1'b0;
            pool_active_q <= 1'b0;
        end else begin
            unsupported_pending_q <= unsupported_accept;
            if (pool_cmd_valid && pool_cmd_ready)
                pool_active_q <= 1'b1;
            else if (pool_done)
                pool_active_q <= 1'b0;
        end
    end

    // ============================================================
    // Command Frontend
    // ============================================================

    command_frontend #(
        .DESC_COUNT_WIDTH(DESC_COUNT_WIDTH)
    ) u_frontend (
        .clk(clk),
        .reset(reset),
        .start(start),
        .desc_base(desc_base),
        .desc_count(desc_count),
        .mem_read_req(frontend_mem_read_req),
        .mem_read_addr(frontend_mem_read_addr),
        .mem_read_ready(frontend_mem_read_ready),
        .mem_read_valid(frontend_mem_read_valid),
        .mem_read_data(frontend_mem_read_data),
        .cmd_valid(frontend_cmd_valid),
        .cmd_ready(frontend_cmd_ready),
        .cmd_opcode(frontend_cmd_opcode),
        .cmd_flags(frontend_cmd_flags),
        .cfg_m(frontend_cfg_m),
        .cfg_n(frontend_cfg_n),
        .cfg_k(frontend_cfg_k),
        .cfg_a_base(frontend_cfg_a_base),
        .cfg_b_base(frontend_cfg_b_base),
        .cfg_c_base(frontend_cfg_c_base),
        .cfg_a_stride(frontend_cfg_a_stride),
        .cfg_b_stride(frontend_cfg_b_stride),
        .cfg_c_stride(frontend_cfg_c_stride),
        .cfg_param0(frontend_cfg_param0),
        .cfg_param1(frontend_cfg_param1),
        .exec_done(frontend_exec_done),
        .busy(frontend_busy),
        .done(frontend_done)
    );

    // ============================================================
    // Descriptor AXI Reader
    // ============================================================

    assign frontend_mem_read_ready = desc_req_ready;
    assign frontend_mem_read_valid =
        desc_data_valid && desc_data_last;
    assign frontend_mem_read_data = desc_data;

    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) u_desc_reader (
        .clk(clk),
        .reset(reset),
        .req_valid(frontend_mem_read_req),
        .req_ready(desc_req_ready),
        .req_addr(ADDR_WIDTH'(frontend_mem_read_addr)),
        .req_beats(32'd1),
        .data_valid(desc_data_valid),
        .data_ready(1'b1),
        .data(desc_data),
        .data_last(desc_data_last),
        .busy(desc_axi_busy),
        .done(desc_axi_done),
        .error(desc_axi_error),
        .m_axi_arid(desc_ar.id),
        .m_axi_araddr(desc_ar.addr),
        .m_axi_arlen(desc_ar.len),
        .m_axi_arsize(desc_ar.size),
        .m_axi_arburst(desc_ar.burst),
        .m_axi_arvalid(desc_ar.valid),
        .m_axi_arready(desc_arready),
        .m_axi_rid(desc_r.id),
        .m_axi_rdata(desc_r.data),
        .m_axi_rresp(desc_r.resp),
        .m_axi_rlast(desc_r.last),
        .m_axi_rvalid(desc_r.valid),
        .m_axi_rready(desc_rready)
    );

    // ============================================================
    // GEMM / Conv Executor
    // ============================================================

    gemm_executor #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .MEM_WORD_WIDTH(MEM_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .K_TILE_SIZE(K_TILE_SIZE),
        .A_BUFFER_COUNT(A_BUFFER_COUNT),
        .B_BUFFER_COUNT(B_BUFFER_COUNT)
    ) u_gemm_executor (
        .clk(clk),
        .reset(reset),
        .cmd_valid(executor_cmd_valid),
        .cmd_ready(executor_cmd_ready),
        .cmd_m(frontend_cfg_m),
        .cmd_n(frontend_cfg_n),
        .cmd_k(frontend_cfg_k),
        .cmd_a_base(ADDR_WIDTH'(frontend_cfg_a_base)),
        .cmd_b_base(ADDR_WIDTH'(frontend_cfg_b_base)),
        .cmd_c_base(ADDR_WIDTH'(frontend_cfg_c_base)),
        .cmd_a_stride_bytes(exec_a_stride),
        .cmd_b_stride_bytes(exec_b_stride),
        .cmd_c_stride_bytes(exec_c_stride),
        .cmd_conv_mode(conv_mode),
        .cmd_conv_input_h(conv_input_h),
        .cmd_conv_input_w(conv_input_w),
        .cmd_conv_input_c(conv_input_c),
        .cmd_conv_kernel_h(conv_kernel_h),
        .cmd_conv_kernel_w(conv_kernel_w),
        .cmd_conv_stride_h(conv_stride_h),
        .cmd_conv_stride_w(conv_stride_w),
        .cmd_conv_pad_top(conv_pad_top),
        .cmd_conv_pad_left(conv_pad_left),
        .cmd_conv_output_w(conv_output_w),
        .cmd_conv_output_positions(conv_output_positions),
        .cmd_bias_en(frontend_bias_en),
        .cmd_requant_en(frontend_requant_en),
        .cmd_relu_en(frontend_relu_en),
        .cmd_param_base(
            ADDR_WIDTH'({
                frontend_cfg_param1,
                frontend_cfg_param0
            })
        ),
        .busy(executor_busy),
        .done(executor_done),
        .error(executor_error),
        .acc_out(acc_out),

        .m_axi_arid(exec_ar.id),
        .m_axi_araddr(exec_ar.addr),
        .m_axi_arlen(exec_ar.len),
        .m_axi_arsize(exec_ar.size),
        .m_axi_arburst(exec_ar.burst),
        .m_axi_arvalid(exec_ar.valid),
        .m_axi_arready(exec_arready),
        .m_axi_rid(exec_r.id),
        .m_axi_rdata(exec_r.data),
        .m_axi_rresp(exec_r.resp),
        .m_axi_rlast(exec_r.last),
        .m_axi_rvalid(exec_r.valid),
        .m_axi_rready(exec_rready),

        .m_axi_awid(exec_aw.id),
        .m_axi_awaddr(exec_aw.addr),
        .m_axi_awlen(exec_aw.len),
        .m_axi_awsize(exec_aw.size),
        .m_axi_awburst(exec_aw.burst),
        .m_axi_awvalid(exec_aw.valid),
        .m_axi_awready(exec_awready),
        .m_axi_wdata(exec_w.data),
        .m_axi_wstrb(exec_w.strb),
        .m_axi_wlast(exec_w.last),
        .m_axi_wvalid(exec_w.valid),
        .m_axi_wready(exec_wready),
        .m_axi_bid(exec_b.id),
        .m_axi_bresp(exec_b.resp),
        .m_axi_bvalid(exec_b.valid),
        .m_axi_bready(exec_bready)
    );

    // ============================================================
    // MaxPool Engine
    // ============================================================

    pool2d_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) u_pool (
        .clk(clk),
        .reset(reset),
        .cmd_valid(pool_cmd_valid),
        .cmd_ready(pool_cmd_ready),
        .cmd_input_base(
            ADDR_WIDTH'(frontend_cfg_a_base)
        ),
        .cmd_output_base(
            ADDR_WIDTH'(frontend_cfg_c_base)
        ),
        .cmd_input_h(frontend_cfg_m),
        .cmd_input_w(frontend_cfg_n),
        .cmd_channels(frontend_cfg_k),
        .busy(pool_busy),
        .done(pool_done),
        .error(pool_error),

        .m_axi_arid(pool_ar.id),
        .m_axi_araddr(pool_ar.addr),
        .m_axi_arlen(pool_ar.len),
        .m_axi_arsize(pool_ar.size),
        .m_axi_arburst(pool_ar.burst),
        .m_axi_arvalid(pool_ar.valid),
        .m_axi_arready(pool_arready),
        .m_axi_rid(pool_r.id),
        .m_axi_rdata(pool_r.data),
        .m_axi_rresp(pool_r.resp),
        .m_axi_rlast(pool_r.last),
        .m_axi_rvalid(pool_r.valid),
        .m_axi_rready(pool_rready),

        .m_axi_awid(pool_aw.id),
        .m_axi_awaddr(pool_aw.addr),
        .m_axi_awlen(pool_aw.len),
        .m_axi_awsize(pool_aw.size),
        .m_axi_awburst(pool_aw.burst),
        .m_axi_awvalid(pool_aw.valid),
        .m_axi_awready(pool_awready),
        .m_axi_wdata(pool_w.data),
        .m_axi_wstrb(pool_w.strb),
        .m_axi_wlast(pool_w.last),
        .m_axi_wvalid(pool_w.valid),
        .m_axi_wready(pool_wready),
        .m_axi_bid(pool_b.id),
        .m_axi_bresp(pool_b.resp),
        .m_axi_bvalid(pool_b.valid),
        .m_axi_bready(pool_bready)
    );

    // ============================================================
    // Shared AXI Read Mux
    // ============================================================

    assign selected_ar =
        pool_active_q ? pool_ar : exec_ar;

    assign exec_arready =
        !pool_active_q && selected_arready;

    assign pool_arready =
        pool_active_q && selected_arready;

    assign selected_rready =
        pool_active_q ? pool_rready : exec_rready;

    assign exec_r =
        pool_active_q ? '0 : selected_r;

    assign pool_r =
        pool_active_q ? selected_r : '0;

    axi_read_mux #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) u_axi_read_mux (
        .clk(clk),
        .reset(reset),

        .desc_arid(desc_ar.id),
        .desc_araddr(desc_ar.addr),
        .desc_arlen(desc_ar.len),
        .desc_arsize(desc_ar.size),
        .desc_arburst(desc_ar.burst),
        .desc_arvalid(desc_ar.valid),
        .desc_arready(desc_arready),
        .desc_rid(desc_r.id),
        .desc_rdata(desc_r.data),
        .desc_rresp(desc_r.resp),
        .desc_rlast(desc_r.last),
        .desc_rvalid(desc_r.valid),
        .desc_rready(desc_rready),

        .gemm_arid(selected_ar.id),
        .gemm_araddr(selected_ar.addr),
        .gemm_arlen(selected_ar.len),
        .gemm_arsize(selected_ar.size),
        .gemm_arburst(selected_ar.burst),
        .gemm_arvalid(selected_ar.valid),
        .gemm_arready(selected_arready),
        .gemm_rid(selected_r.id),
        .gemm_rdata(selected_r.data),
        .gemm_rresp(selected_r.resp),
        .gemm_rlast(selected_r.last),
        .gemm_rvalid(selected_r.valid),
        .gemm_rready(selected_rready),

        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    // ============================================================
    // Shared AXI Write Path
    // ============================================================

    assign m_axi_awid =
        pool_active_q ? pool_aw.id : exec_aw.id;

    assign m_axi_awaddr =
        pool_active_q ? pool_aw.addr : exec_aw.addr;

    assign m_axi_awlen =
        pool_active_q ? pool_aw.len : exec_aw.len;

    assign m_axi_awsize =
        pool_active_q ? pool_aw.size : exec_aw.size;

    assign m_axi_awburst =
        pool_active_q ? pool_aw.burst : exec_aw.burst;

    assign m_axi_awvalid =
        pool_active_q ? pool_aw.valid : exec_aw.valid;

    assign exec_awready =
        !pool_active_q && m_axi_awready;

    assign pool_awready =
        pool_active_q && m_axi_awready;

    assign m_axi_wdata =
        pool_active_q ? pool_w.data : exec_w.data;

    assign m_axi_wstrb =
        pool_active_q ? pool_w.strb : exec_w.strb;

    assign m_axi_wlast =
        pool_active_q ? pool_w.last : exec_w.last;

    assign m_axi_wvalid =
        pool_active_q ? pool_w.valid : exec_w.valid;

    assign exec_wready =
        !pool_active_q && m_axi_wready;

    assign pool_wready =
        pool_active_q && m_axi_wready;

    assign exec_b =
        pool_active_q ?
        '0 :
        {m_axi_bid, m_axi_bresp, m_axi_bvalid};

    assign pool_b =
        pool_active_q ?
        {m_axi_bid, m_axi_bresp, m_axi_bvalid} :
        '0;

    assign m_axi_bready =
        pool_active_q ? pool_bready : exec_bready;

    // ============================================================
    // Top-Level Status
    // ============================================================

    assign busy =
        frontend_busy ||
        executor_busy ||
        pool_busy ||
        pool_active_q ||
        desc_axi_busy ||
        desc_axi_done ||
        unsupported_pending_q;

    assign done = frontend_done;

    always_ff @(posedge clk) begin
        if (reset)
            error <= 1'b0;
        else if (start && !busy)
            error <= 1'b0;
        else if (
            desc_axi_error ||
            executor_error ||
            pool_error ||
            unsupported_accept
        )
            error <= 1'b1;
    end

    // ============================================================
    // Performance Monitor
    //
    // With NPU_PERF_ENABLE:
    //   - Outputs are exposed as real module ports.
    //   - The testbench connects every output explicitly.
    //   - No unused internal performance wires remain.
    //
    // Without NPU_PERF_ENABLE:
    //   - Original npu_top interface is unchanged.
    // ============================================================

`ifdef NPU_PERF_ENABLE

    logic perf_run_start;
    logic perf_layer_start;
    logic perf_layer_done;

    assign perf_run_start = start && !busy;

    assign perf_layer_start =
        (executor_cmd_valid && executor_cmd_ready) ||
        (pool_cmd_valid && pool_cmd_ready);

    assign perf_layer_done = frontend_exec_done;

    npu_perf_monitor #(
        .DATA_WIDTH(MEM_WORD_WIDTH)
    ) u_perf_monitor (
        .clk(clk),
        .reset(reset),

        .run_start(perf_run_start),
        .run_done(done),

        .layer_start(perf_layer_start),
        .layer_done(perf_layer_done),
        .layer_opcode(frontend_cmd_opcode),

        .executor_busy(executor_busy),
        .pool_busy(pool_busy),

        .arvalid(m_axi_arvalid),
        .arready(m_axi_arready),
        .rvalid(m_axi_rvalid),
        .rready(m_axi_rready),
        .rlast(m_axi_rlast),

        .awvalid(m_axi_awvalid),
        .awready(m_axi_awready),
        .wvalid(m_axi_wvalid),
        .wready(m_axi_wready),
        .wstrb(m_axi_wstrb),
        .wlast(m_axi_wlast),
        .bvalid(m_axi_bvalid),
        .bready(m_axi_bready),

        .total_cycles(perf_total_cycles),
        .executor_cycles(perf_executor_cycles),
        .pool_cycles(perf_pool_cycles),

        .ar_transactions(perf_ar_transactions),
        .r_beats(perf_r_beats),
        .aw_transactions(perf_aw_transactions),
        .w_beats(perf_w_beats),
        .written_bytes(perf_written_bytes),

        .ar_stall_cycles(perf_ar_stall_cycles),
        .r_wait_cycles(perf_r_wait_cycles),
        .aw_stall_cycles(perf_aw_stall_cycles),
        .w_stall_cycles(perf_w_stall_cycles),
        .b_wait_cycles(perf_b_wait_cycles),

        .layer_done_pulse(perf_layer_done_pulse),
        .completed_layer_index(perf_completed_layer_index),
        .completed_layer_opcode(perf_completed_layer_opcode),
        .completed_layer_cycles(perf_completed_layer_cycles),
        .completed_layer_executor_cycles(
            perf_completed_layer_executor_cycles
        ),
        .completed_layer_pool_cycles(
            perf_completed_layer_pool_cycles
        ),
        .completed_layer_ar(perf_completed_layer_ar),
        .completed_layer_r_beats(
            perf_completed_layer_r_beats
        ),
        .completed_layer_aw(perf_completed_layer_aw),
        .completed_layer_w_beats(
            perf_completed_layer_w_beats
        )
    );

`endif

    initial begin
        if (ADDR_WIDTH != 64 || MEM_WORD_WIDTH != 32)
            $fatal(
                1,
                "npu_top requires ADDR_WIDTH=64, MEM_WORD_WIDTH=32"
            );

        if (ROWS < 1 || COLS < 1)
            $fatal(1, "Invalid array dimensions");
    end

endmodule
