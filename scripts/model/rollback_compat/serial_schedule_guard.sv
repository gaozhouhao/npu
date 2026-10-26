// Verification only. This module never drives a DUT signal or changes timing.
module serial_schedule_guard #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned K_TILE_SIZE = 256,
    parameter int unsigned K_SIZE_WIDTH = $clog2(K_TILE_SIZE + 1)
) (
    input logic clk, reset, start, busy, done,
    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count, n_tile_count, k_tile_count,
    input logic [K_SIZE_WIDTH-1:0] last_k_size,
    input logic a_load_req, a_load_accept, a_load_done,
    input logic b_load_req, b_load_accept, b_load_done,
    input logic matrix_start, matrix_done, clear_acc, writeback_en,
    input logic [K_SIZE_WIDTH-1:0] current_k_size,
    input logic [TILE_COUNT_WIDTH-1:0] m_tile_idx, n_tile_idx, k_tile_idx
);
    longint unsigned expected_tiles_q, m_count_q, n_count_q, k_count_q;
    longint unsigned a_loads_q, b_loads_q, a_finished_q, b_finished_q;
    longint unsigned launched_q, completed_q;
    logic compute_active_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            expected_tiles_q <= 0;
            m_count_q <= 0; n_count_q <= 0; k_count_q <= 0;
            a_loads_q <= 0; b_loads_q <= 0;
            a_finished_q <= 0; b_finished_q <= 0;
            launched_q <= 0; completed_q <= 0;
            compute_active_q <= 0;
        end else begin
            if (start && !busy && !done) begin
                expected_tiles_q <= 64'(m_tile_count) * 64'(n_tile_count) * 64'(k_tile_count);
                m_count_q <= 64'(m_tile_count);
                n_count_q <= 64'(n_tile_count);
                k_count_q <= 64'(k_tile_count);
                a_loads_q <= 0; b_loads_q <= 0;
                a_finished_q <= 0; b_finished_q <= 0;
                launched_q <= 0; completed_q <= 0;
                compute_active_q <= 0;
            end
            if (compute_active_q && (a_load_req || b_load_req || a_load_accept || b_load_accept))
                $fatal(1, "SERIAL_SCHEDULE_CHECK: operand load overlaps compute/writeback");
            if (a_load_req && a_load_accept) a_loads_q <= a_loads_q + 1;
            if (b_load_req && b_load_accept) b_loads_q <= b_loads_q + 1;
            if (a_load_done) a_finished_q <= a_finished_q + 1;
            if (b_load_done) b_finished_q <= b_finished_q + 1;
            if (matrix_start) begin
                if (compute_active_q || (launched_q != completed_q))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: multiple tiles in flight");
                if ((a_loads_q != launched_q + 1) || (b_loads_q != launched_q + 1) ||
                    (a_finished_q != launched_q + 1) || (b_finished_q != launched_q + 1))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: every K tile requires one fresh completed A and B load");
                if ((64'(k_tile_idx) != launched_q % k_count_q) ||
                    (64'(n_tile_idx) != (launched_q / k_count_q) % n_count_q) ||
                    (64'(m_tile_idx) != launched_q / (k_count_q * n_count_q)))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: expected historical M/N/K tile order");
                if ((clear_acc != (k_tile_idx == 0)) ||
                    (writeback_en != (64'(k_tile_idx) == k_count_q - 1)))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: historical K accumulation controls differ");
                if (current_k_size != (writeback_en ? last_k_size : K_SIZE_WIDTH'(K_TILE_SIZE)))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: K tile length differs");
                launched_q <= launched_q + 1;
                compute_active_q <= 1;
            end
            if (matrix_done && compute_active_q) begin
                completed_q <= completed_q + 1;
                compute_active_q <= 0;
            end
            if (done) begin
                if (compute_active_q || (launched_q != expected_tiles_q) ||
                    (completed_q != expected_tiles_q) || (a_loads_q != expected_tiles_q) ||
                    (b_loads_q != expected_tiles_q) || (a_finished_q != expected_tiles_q) ||
                    (b_finished_q != expected_tiles_q))
                    $fatal(1, "SERIAL_SCHEDULE_CHECK: incomplete tile / fresh operand load counts");
                $display("SERIAL_SCHEDULE_CHECK PASS tiles=%0d a_loads=%0d b_loads=%0d no_overlap=1 no_reuse=1", expected_tiles_q, a_loads_q, b_loads_q);
            end
        end
    end
endmodule

module serial_single_bank_guard #(
    parameter int unsigned A_BUFFER_COUNT = 1,
    parameter int unsigned B_BUFFER_COUNT = 1
) ();
    initial begin
        if ((A_BUFFER_COUNT != 1) || (B_BUFFER_COUNT != 1))
            $fatal(1, "SERIAL_BANK_CHECK: exactly one physical bank required per operand");
        $display("SERIAL_BANK_CHECK PASS a_banks=%0d b_banks=%0d", A_BUFFER_COUNT, B_BUFFER_COUNT);
    end
endmodule

bind tile_scheduler serial_schedule_guard #(
    .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH), .K_TILE_SIZE(K_TILE_SIZE), .K_SIZE_WIDTH(K_SIZE_WIDTH)
) u_serial_schedule_guard (
    .clk(clk), .reset(reset), .start(start), .busy(busy), .done(done),
    .m_tile_count(m_tile_count), .n_tile_count(n_tile_count), .k_tile_count(k_tile_count),
    .last_k_size(last_k_size),
    .a_load_req(a_load_req), .a_load_accept(a_load_accept), .a_load_done(a_load_done),
    .b_load_req(b_load_req), .b_load_accept(b_load_accept), .b_load_done(b_load_done),
    .matrix_start(matrix_start), .matrix_done(matrix_done),
    .clear_acc(clear_acc), .writeback_en(writeback_en), .current_k_size(current_k_size),
    .m_tile_idx(m_tile_idx), .n_tile_idx(n_tile_idx), .k_tile_idx(k_tile_idx)
);
bind npu_top serial_single_bank_guard #(
    .A_BUFFER_COUNT(A_BUFFER_COUNT), .B_BUFFER_COUNT(B_BUFFER_COUNT)
) u_serial_single_bank_guard ();
