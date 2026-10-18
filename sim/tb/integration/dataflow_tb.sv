
`timescale 1ns/1ps

module dataflow_tb;

    localparam int unsigned R = 4;
    localparam int unsigned C = 4;
    localparam int unsigned SLOTS = 2;
    localparam int unsigned TW = R * C * 32;
    localparam int unsigned RW = C * 32;

    logic clk;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    logic reset, start;
    logic [1:0] mode;

    logic busy, done, error, valid, retire;
    logic [7:0] m, n, k;
    logic [0:0] slot;

    logic load_a, load_b;
    logic release_a, release_b;
    logic use_psum, first_k, last_k;

    logic engine_start, engine_busy, engine_done;
    logic [TW-1:0] pe_tile;

    logic sr_rd_en, sr_rd_valid, sr_wr_en;
    logic [0:0] sr_rd_slot, sr_wr_slot;
    logic [1:0] sr_rd_row, sr_wr_row;
    logic [RW-1:0] sr_rd_data, sr_wr_data;

    logic alu_active;
    logic [RW-1:0] alu_a, alu_b, alu_result;

    logic inflight;
    integer events;
    integer ticks;

    dataflow_tile_iterator #(
        .COUNT_WIDTH (8),
        .PSUM_SLOTS  (SLOTS)
    ) u_iter (
        .clk             (clk),
        .reset           (reset),
        .start           (start),
        .dataflow_mode   (mode),
        .m_tile_count    (8'd2),
        .n_tile_count    (8'd5),
        .k_tile_count    (8'd3),
        .busy            (busy),
        .done            (done),
        .error           (error),
        .tile_valid      (valid),
        .tile_retire     (retire),
        .tile_m          (m),
        .tile_n          (n),
        .tile_k          (k),
        .c_slot          (slot),
        .load_a          (load_a),
        .load_b          (load_b),
        .release_a       (release_a),
        .release_b       (release_b),
        .use_psum_sram   (use_psum),
        .psum_first_k    (first_k),
        .psum_last_k     (last_k)
    );

    psum_tile_engine #(
        .ROWS       (R),
        .COLS       (C),
        .PSUM_SLOTS (SLOTS)
    ) u_engine (
        .clk          (clk),
        .reset        (reset),
        .start        (engine_start),
        .first_k      (first_k),
        .slot         (slot),
        .pe_tile      (pe_tile),
        .busy         (engine_busy),
        .done         (engine_done),
        .sram_rd_en   (sr_rd_en),
        .sram_rd_slot (sr_rd_slot),
        .sram_rd_row  (sr_rd_row),
        .sram_rd_valid(sr_rd_valid),
        .sram_rd_data (sr_rd_data),
        .sram_wr_en   (sr_wr_en),
        .sram_wr_slot (sr_wr_slot),
        .sram_wr_row  (sr_wr_row),
        .sram_wr_data (sr_wr_data),
        .alu_use_psum (alu_active),
        .alu_a        (alu_a),
        .alu_b        (alu_b),
        .alu_sum      (alu_result)
    );

    psum_tile_sram #(
        .ROWS       (R),
        .COLS       (C),
        .PSUM_SLOTS (SLOTS)
    ) u_store (
        .clk      (clk),
        .reset    (reset),
        .rd_en    (sr_rd_en),
        .rd_slot  (sr_rd_slot),
        .rd_row   (sr_rd_row),
        .rd_valid (sr_rd_valid),
        .rd_data  (sr_rd_data),
        .wr_en    (sr_wr_en),
        .wr_slot  (sr_wr_slot),
        .wr_row   (sr_wr_row),
        .wr_data  (sr_wr_data)
    );

    // Standalone reference ALU.
    // Integrated design will reuse Bias adders.
    for (genvar lane = 0; lane < C; lane++) begin : gen_alu
        assign alu_result[lane*32 +: 32] =
            alu_a[lane*32 +: 32] +
            alu_b[lane*32 +: 32];
    end

    function automatic integer raw_elem(
        input integer mi,
        input integer ni,
        input integer ki,
        input integer ri,
        input integer ci
    );
        return
            (mi + 1) * 1000 +
            (ni + 1) * 100 +
            (ki + 1) * 10 +
            ri * C + ci;
    endfunction

    initial begin
        reset = 1'b1;
        start = 1'b0;
        mode = '0;

        retire = 1'b0;
        engine_start = 1'b0;
        pe_tile = '0;
        inflight = 1'b0;
        events = 0;

        repeat (4)
            @(negedge clk);

        reset = 1'b0;

        for (int cfg = 0; cfg < 3; cfg++) begin
            @(negedge clk);

            mode = 2'(cfg);
            start = 1'b1;

            @(negedge clk);
            start = 1'b0;

            events = 0;
            ticks = 0;
            inflight = 1'b0;
            retire = 1'b0;
            engine_start = 1'b0;

            while (!done && ticks < 4000) begin
                @(negedge clk);
                ticks++;

                retire = 1'b0;
                engine_start = 1'b0;

                if (valid) begin
                    if (!busy || !(load_a || load_b))
                        $fatal(
                            1,
                            "Invalid busy/load control"
                        );

                    if (
                        (cfg != 1 && !release_a) ||
                        (cfg != 2 && !release_b)
                    )
                        $fatal(
                            1,
                            "Invalid operand retention"
                        );

                    if (use_psum != (cfg != 0))
                        $fatal(
                            1,
                            "Invalid psum flag"
                        );

                    if (engine_busy && !inflight)
                        $fatal(
                            1,
                            "Unexpected PSUM engine activity"
                        );

                    if (alu_active && !sr_wr_en)
                        $fatal(
                            1,
                            "Unexpected shared ALU operation"
                        );

                    if (cfg == 0) begin
                        retire = 1'b1;
                        events++;
                    end else if (!inflight) begin

                        for (int r = 0; r < R; r++) begin
                            for (int c = 0; c < C; c++) begin
                                pe_tile[
                                    (r*C+c)*32 +: 32
                                ] = 32'(
                                    raw_elem(
                                        int'(m),
                                        int'(n),
                                        int'(k),
                                        r,
                                        c
                                    )
                                );
                            end
                        end

                        engine_start = 1'b1;
                        inflight = 1'b1;

                    end else if (engine_done) begin

                        if (last_k) begin
                            for (int r = 0; r < R; r++) begin
                                for (int c = 0; c < C; c++) begin

                                    if (
                                        u_store.mem[
                                            int'(slot)*R+r
                                        ][c*32 +: 32] !==
                                        32'(
                                            raw_elem(
                                                int'(m),
                                                int'(n),
                                                0, r, c
                                            ) +
                                            raw_elem(
                                                int'(m),
                                                int'(n),
                                                1, r, c
                                            ) +
                                            raw_elem(
                                                int'(m),
                                                int'(n),
                                                2, r, c
                                            )
                                        )
                                    )
                                        $fatal(
                                            1,
                                            "PSUM mismatch mode=%0d m=%0d n=%0d r=%0d c=%0d",
                                            cfg, m, n, r, c
                                        );

                                end
                            end
                        end

                        retire = 1'b1;
                        inflight = 1'b0;
                        events++;

                    end
                end
            end

            if (!done || events != 30 || error)
                $fatal(
                    1,
                    "Iterator failure mode=%0d events=%0d ticks=%0d error=%0b",
                    cfg, events, ticks, error
                );

            $display(
                "PASS mode=%0d tiles=%0d cycles=%0d",
                cfg, events, ticks
            );

            repeat (3)
                @(negedge clk);
        end

        $display("Three-mode RTL smoke test PASS");
        $finish;
    end

endmodule
