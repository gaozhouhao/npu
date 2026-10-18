// Current validation is blocked by APG SYNH-14; see docs/eda_learning_notes.md.
// One dedicated SRAM for checking the DC-supplied MBIST components.
// The NPU is not connected to this experiment.
module dw_mbist_sram_probe (
    input logic clk,
    input logic rst_n,
    input logic mbrun,
    input logic shift_dr,
    input logic mode_reg_si,
    input logic inject_fault,
    output logic mode_reg_so,
    output logic [15:0] mode_reg_out,
    output logic [4:0] memory_address,
    output logic memory_ce_n,
    output logic memory_we_n,
    output logic [63:0] memory_write_data
);
    wire bist_mode, segment_en, segment_active, mem_fail_n;
    wire atpg_1, continue_test, cont_pause_on_error;
    wire load_parallel_pattern, load_serial_pattern, serial_pattern_out;
    wire [4:0] segment_descr;
    wire [3:0] port_no;
    wire [63:0] memory_q, compare_data;

    // No extra registers between the APG and the synchronous SRAM.
    dw_mbist_controller_probe #(.REGISTERED_IO(0)) u_controller (
        .clk(clk), .rst_n(rst_n), .mbrun(mbrun),
        .mode_reg_in(16'b0), .mode_reg_si(mode_reg_si),
        .shift_dr(shift_dr), .parallel_dr(1'b0),
        .segment_active(segment_active), .mem_fail_n(mem_fail_n),
        .mr_ctrl_sel_rst(1'b1), .mr_marchlr_rst(1'b0),
        .mr_marchc_rst(1'b1), .mr_mats_rst(1'b0), .mr_retn_rst(1'b0),
        .mr_debug_mode_rst(1'b1), .mr_mem_sel_stat_rst(1'b1),
        .mode_reg_so(mode_reg_so), .mode_reg_out(mode_reg_out),
        .atpg_1(atpg_1), .bist_mode(bist_mode),
        .segment_descr(segment_descr), .segment_en(segment_en),
        .port_no(port_no), .continue_test(continue_test),
        .cont_pause_on_error(cont_pause_on_error),
        .load_parallel_pattern(load_parallel_pattern),
        .load_serial_pattern(load_serial_pattern),
        .serial_pattern_out(serial_pattern_out)
    );

    DW_mbist_apg #(
        .addr_width(5), .data_width(64), .num_ports(1),
        .registered_io(0), .memory_full(1),
        .mem_start_addr(0), .mem_end_addr(31)
    ) u_pattern_generator (
        .bist_clk(clk), .bist_clk_t(clk),
        .rst_n_a(rst_n), .rst_t_n_a(rst_n),
        .simulation_mode(1'b0), .bist_mode(bist_mode), .dbist_mode(1'b0),
        .port_no(port_no), .atpg_1(atpg_1),
        .load_parallel_pattern(load_parallel_pattern),
        .load_serial_pattern(load_serial_pattern),
        .serial_pattern_out(serial_pattern_out),
        .segment_descr(segment_descr), .segment_en(segment_en),
        .continue_test(continue_test), .cont_pause_on_error(cont_pause_on_error),
        .debug_en(1'b0), .debug_si(1'b0), .custom_pattern(64'b0),
        .cap_mem_addr_0(5'b0), .cap_mem_addr_1(5'b0),
        .cap_mem_addr_2(5'b0), .cap_mem_addr_3(5'b0),
        .cap_mem_wr_addr_0(5'b0), .cap_mem_wr_addr_1(5'b0),
        .cap_mem_wr_addr_2(5'b0), .cap_mem_wr_addr_3(5'b0),
        .cap_mem_rd_addr_0(5'b0), .cap_mem_rd_addr_1(5'b0),
        .cap_mem_rd_addr_2(5'b0), .cap_mem_rd_addr_3(5'b0),
        .cap_mem_wr_data_0(64'b0), .cap_mem_wr_data_1(64'b0),
        .cap_mem_wr_data_2(64'b0), .cap_mem_wr_data_3(64'b0),
        .cap_mem_cs_0(1'b0), .cap_mem_cs_1(1'b0),
        .cap_mem_cs_2(1'b0), .cap_mem_cs_3(1'b0),
        .cap_mem_we_0(1'b0), .cap_mem_we_1(1'b0),
        .cap_mem_we_2(1'b0), .cap_mem_we_3(1'b0),
        .cap_mem_oe_0(1'b0), .cap_mem_oe_1(1'b0),
        .cap_mem_oe_2(1'b0), .cap_mem_oe_3(1'b0),
        .bist_rd_data_0(compare_data), .bist_rd_data_1(64'b0),
        .bist_rd_data_2(64'b0), .bist_rd_data_3(64'b0),
        .segment_active(segment_active), .mem_fail_n(mem_fail_n),
        .bist_cs_n_0(memory_ce_n), .bist_we_n_0(memory_we_n),
        .bist_addr_0(memory_address), .bist_wr_data_0(memory_write_data)
    );

    // Inject a stuck-at-0 on read-data bit 0 for the negative test only.
    assign compare_data = {memory_q[63:1], inject_fault ? 1'b0 : memory_q[0]};
    TS5N28HPCPSVTA32X64M2F u_memory (
        .CLK(clk), .CEB(memory_ce_n), .WEB(memory_we_n),
        .A(memory_address), .D(memory_write_data), .Q(memory_q)
    );
endmodule
