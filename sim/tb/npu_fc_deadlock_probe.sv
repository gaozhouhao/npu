
`timescale 1ns/1ps

module npu_fc_deadlock_probe (
    input logic clk,
    input logic reset,
    input logic enable,
    input logic progress,

    input logic [1:0] load_state,
    input logic [2:0] compute_state,

    input logic [15:0] next_m,
    input logic [15:0] next_n,
    input logic [15:0] next_k,

    input logic [15:0] load_m,
    input logic [15:0] load_n,
    input logic [15:0] load_k,

    input logic [15:0] compute_m,
    input logic [15:0] compute_n,
    input logic [15:0] compute_k,

    input logic ready_valid,
    input logic resident_a_valid,
    input logic [15:0] resident_a_m,
    input logic [15:0] resident_a_k,

    input logic [1:0] a_bank0,
    input logic [1:0] a_bank1,
    input logic [1:0] b_bank0,
    input logic [1:0] b_bank1,

    input logic a_load_req,
    input logic b_load_req,
    input logic a_compute_req,
    input logic b_compute_req,

    input logic core_done,
    input logic psum_busy,
    input logic psum_done,

    input logic c_tile_pending,
    input logic c_write_busy,
    input logic final_result_wait
);

    logic [15:0] stalled_q;

    // Bank encoding from buffer_manager.sv:
    // 0 EMPTY, 1 LOADING, 2 READY, 3 COMPUTING.
    //
    // Scheduler state encoding:
    // load: 0 IDLE, 1 REQ, 2 WAIT
    // compute: 0 IDLE, 1 ACQUIRE,
    //          2 LAUNCH, 3 RUN, 4 WAIT_WRITEBACK.

    always_ff @(posedge clk) begin
        if (reset || !enable || progress) begin
            stalled_q <= '0;
        end else begin
            if (stalled_q < 16'd2048)
                stalled_q <= stalled_q + 16'd1;

            if (stalled_q == 16'd1024) begin
                $display("");
                $display("========== FC NO-PROGRESS ==========");
                $display(
                    "load_state=%0d compute_state=%0d",
                    load_state, compute_state
                );
                $display(
                    "next=(%0d,%0d,%0d) load=(%0d,%0d,%0d)",
                    next_m, next_n, next_k,
                    load_m, load_n, load_k
                );
                $display(
                    "compute=(%0d,%0d,%0d) ready_valid=%0b",
                    compute_m, compute_n, compute_k,
                    ready_valid
                );
                $display(
                    "resident_A valid=%0b tag=(%0d,%0d)",
                    resident_a_valid,
                    resident_a_m,
                    resident_a_k
                );
                $display(
                    "A Banks=[%0d,%0d] B Banks=[%0d,%0d]",
                    a_bank0, a_bank1,
                    b_bank0, b_bank1
                );
                $display(
                    "requests: Aload=%0b Bload=%0b Acompute=%0b Bcompute=%0b",
                    a_load_req, b_load_req,
                    a_compute_req, b_compute_req
                );
                $display(
                    "core_done=%0b psum_busy=%0b psum_done=%0b",
                    core_done, psum_busy, psum_done
                );
                $display(
                    "C pending=%0b write_busy=%0b final_wait=%0b",
                    c_tile_pending,
                    c_write_busy,
                    final_result_wait
                );
                $display("====================================");
            end

            if (stalled_q == 16'd2048)
                $fatal(1, "FC stalled for 2048 cycles");
        end
    end

endmodule

// Bound into the existing executor.
// No changes to gemm_executor.sv are required.
//
// The current MNIST configuration uses two A banks
// and two B banks, and TILE_COUNT_WIDTH = 16.

bind gemm_executor npu_fc_deadlock_probe
u_npu_fc_deadlock_probe (
    .clk   (clk),
    .reset (reset),

    .enable (
        scheduler_busy &&
        (k_tile_count_q > TILE_COUNT_WIDTH'(1))
    ),

    .progress (
        scheduler_matrix_start ||
        matrix_done_effective ||
        scheduler_a_load_accept ||
        scheduler_b_load_accept ||
        scheduler_a_compute_grant ||
        scheduler_b_compute_grant ||
        c_write_tile_accept ||
        c_write_done ||
        (m_axi_rvalid && m_axi_rready) ||
        (m_axi_wvalid && m_axi_wready)
    ),

    .load_state (
        u_tile_scheduler.load_state
    ),
    .compute_state (
        u_tile_scheduler.compute_state
    ),

    .next_m (u_tile_scheduler.next_m_q),
    .next_n (u_tile_scheduler.next_n_q),
    .next_k (u_tile_scheduler.next_k_q),

    .load_m (u_tile_scheduler.load_m_q),
    .load_n (u_tile_scheduler.load_n_q),
    .load_k (u_tile_scheduler.load_k_q),

    .compute_m (u_tile_scheduler.compute_m_q),
    .compute_n (u_tile_scheduler.compute_n_q),
    .compute_k (u_tile_scheduler.compute_k_q),

    .ready_valid (
        u_tile_scheduler.ready_valid_q
    ),

    .resident_a_valid (
        u_tile_scheduler.resident_a_valid_q
    ),
    .resident_a_m (
        u_tile_scheduler.resident_a_m_q
    ),
    .resident_a_k (
        u_tile_scheduler.resident_a_k_q
    ),

    .a_bank0 (
        u_a_buffer_manager.bank_state[0]
    ),
    .a_bank1 (
        u_a_buffer_manager.bank_state[1]
    ),

    .b_bank0 (
        u_b_buffer_manager.bank_state[0]
    ),
    .b_bank1 (
        u_b_buffer_manager.bank_state[1]
    ),

    .a_load_req (
        scheduler_a_load_req
    ),
    .b_load_req (
        scheduler_b_load_req
    ),
    .a_compute_req (
        scheduler_a_compute_req
    ),
    .b_compute_req (
        scheduler_b_compute_req
    ),

    .core_done (core_done),
    .psum_busy (psum_busy),
    .psum_done (psum_done),

    .c_tile_pending (
        c_tile_pending_q
    ),
    .c_write_busy (
        c_write_busy
    ),
    .final_result_wait (
        final_result_wait_q
    )
);
