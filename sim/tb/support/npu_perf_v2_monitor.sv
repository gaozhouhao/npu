module npu_perf_v2_monitor #(
    parameter int unsigned PE_COUNT = 16,
    parameter int unsigned MAC_WIDTH = $clog2(PE_COUNT + 1)
) (
    input  logic clk,
    input  logic reset,

    input  logic run_start,
    input  logic run_done,

    input  logic layer_start,
    input  logic layer_done,

    input  logic matrix_start,
    input  logic matrix_done,

    input  logic [MAC_WIDTH-1:0] pe_mac_fires,

    input  logic executor_busy,
    input  logic read_path_busy,

    input  logic a_compute_req,
    input  logic a_compute_grant,
    input  logic b_compute_req,
    input  logic b_compute_grant,

    output logic [63:0] matrix_cycles,
    output logic [63:0] matrix_tiles,
    output logic [63:0] pe_mac_events,
    output logic [63:0] pe_active_cycles,
    output logic [63:0] bank_wait_cycles,
    output logic [63:0] dma_compute_overlap_cycles,
    output logic [63:0] dma_only_cycles,

    output logic layer_done_pulse,
    output logic [63:0] completed_matrix_cycles,
    output logic [63:0] completed_matrix_tiles,
    output logic [63:0] completed_pe_mac_events,
    output logic [63:0] completed_pe_active_cycles,
    output logic [63:0] completed_bank_wait_cycles,
    output logic [63:0] completed_dma_overlap_cycles,
    output logic [63:0] completed_dma_only_cycles
);

    logic run_active_q;
    logic layer_active_q;
    logic matrix_active_q;

    logic bank_wait_event;
    logic dma_overlap_event;
    logic dma_only_event;
    logic pe_active_event;

    logic [63:0] layer_matrix_cycles_q;
    logic [63:0] layer_matrix_tiles_q;
    logic [63:0] layer_pe_mac_events_q;
    logic [63:0] layer_pe_active_cycles_q;
    logic [63:0] layer_bank_wait_cycles_q;
    logic [63:0] layer_dma_overlap_cycles_q;
    logic [63:0] layer_dma_only_cycles_q;

    assign bank_wait_event =
        (a_compute_req && !a_compute_grant) ||
        (b_compute_req && !b_compute_grant);

    assign dma_overlap_event =
        matrix_active_q && read_path_busy;

    assign dma_only_event =
        executor_busy &&
        !matrix_active_q &&
        read_path_busy;

    assign pe_active_event =
        matrix_active_q && (pe_mac_fires != '0);

    always_ff @(posedge clk) begin
        if (reset) begin
            run_active_q <= 1'b0;
            layer_active_q <= 1'b0;
            matrix_active_q <= 1'b0;

            matrix_cycles <= '0;
            matrix_tiles <= '0;
            pe_mac_events <= '0;
            pe_active_cycles <= '0;
            bank_wait_cycles <= '0;
            dma_compute_overlap_cycles <= '0;
            dma_only_cycles <= '0;

            layer_matrix_cycles_q <= '0;
            layer_matrix_tiles_q <= '0;
            layer_pe_mac_events_q <= '0;
            layer_pe_active_cycles_q <= '0;
            layer_bank_wait_cycles_q <= '0;
            layer_dma_overlap_cycles_q <= '0;
            layer_dma_only_cycles_q <= '0;

            layer_done_pulse <= 1'b0;
            completed_matrix_cycles <= '0;
            completed_matrix_tiles <= '0;
            completed_pe_mac_events <= '0;
            completed_pe_active_cycles <= '0;
            completed_bank_wait_cycles <= '0;
            completed_dma_overlap_cycles <= '0;
            completed_dma_only_cycles <= '0;

        end else begin

            layer_done_pulse <= 1'b0;

            if (run_start) begin
                run_active_q <= 1'b1;
                layer_active_q <= 1'b0;
                matrix_active_q <= 1'b0;

                matrix_cycles <= '0;
                matrix_tiles <= '0;
                pe_mac_events <= '0;
                pe_active_cycles <= '0;
                bank_wait_cycles <= '0;
                dma_compute_overlap_cycles <= '0;
                dma_only_cycles <= '0;

                layer_matrix_cycles_q <= '0;
                layer_matrix_tiles_q <= '0;
                layer_pe_mac_events_q <= '0;
                layer_pe_active_cycles_q <= '0;
                layer_bank_wait_cycles_q <= '0;
                layer_dma_overlap_cycles_q <= '0;
                layer_dma_only_cycles_q <= '0;

                completed_matrix_cycles <= '0;
                completed_matrix_tiles <= '0;
                completed_pe_mac_events <= '0;
                completed_pe_active_cycles <= '0;
                completed_bank_wait_cycles <= '0;
                completed_dma_overlap_cycles <= '0;
                completed_dma_only_cycles <= '0;

            end else begin

                if (matrix_start)
                    matrix_active_q <= 1'b1;
                else if (matrix_done)
                    matrix_active_q <= 1'b0;

                if (run_active_q) begin

                    if (matrix_active_q)
                        matrix_cycles <= matrix_cycles + 64'd1;

                    if (matrix_done)
                        matrix_tiles <= matrix_tiles + 64'd1;

                    if (pe_active_event) begin
                        pe_active_cycles <=
                            pe_active_cycles + 64'd1;
                    end

                    if (matrix_active_q) begin
                        pe_mac_events <=
                            pe_mac_events + 64'(pe_mac_fires);
                    end

                    if (bank_wait_event)
                        bank_wait_cycles <=
                            bank_wait_cycles + 64'd1;

                    if (dma_overlap_event)
                        dma_compute_overlap_cycles <=
                            dma_compute_overlap_cycles + 64'd1;

                    if (dma_only_event)
                        dma_only_cycles <=
                            dma_only_cycles + 64'd1;
                end

                if (layer_start) begin
                    layer_active_q <= 1'b1;

                    layer_matrix_cycles_q <= '0;
                    layer_matrix_tiles_q <= '0;
                    layer_pe_mac_events_q <= '0;
                    layer_pe_active_cycles_q <= '0;
                    layer_bank_wait_cycles_q <= '0;
                    layer_dma_overlap_cycles_q <= '0;
                    layer_dma_only_cycles_q <= '0;

                end else if (layer_active_q) begin

                    if (matrix_active_q)
                        layer_matrix_cycles_q <=
                            layer_matrix_cycles_q + 64'd1;

                    if (matrix_done)
                        layer_matrix_tiles_q <=
                            layer_matrix_tiles_q + 64'd1;

                    if (pe_active_event)
                        layer_pe_active_cycles_q <=
                            layer_pe_active_cycles_q + 64'd1;

                    if (matrix_active_q)
                        layer_pe_mac_events_q <=
                            layer_pe_mac_events_q +
                            64'(pe_mac_fires);

                    if (bank_wait_event)
                        layer_bank_wait_cycles_q <=
                            layer_bank_wait_cycles_q + 64'd1;

                    if (dma_overlap_event)
                        layer_dma_overlap_cycles_q <=
                            layer_dma_overlap_cycles_q + 64'd1;

                    if (dma_only_event)
                        layer_dma_only_cycles_q <=
                            layer_dma_only_cycles_q + 64'd1;
                end

                if (layer_done && layer_active_q) begin
                    layer_active_q <= 1'b0;
                    layer_done_pulse <= 1'b1;

                    completed_matrix_cycles <=
                        layer_matrix_cycles_q +
                        64'(matrix_active_q);

                    completed_matrix_tiles <=
                        layer_matrix_tiles_q +
                        64'(matrix_done);

                    completed_pe_mac_events <=
                        layer_pe_mac_events_q +
                        (matrix_active_q ? 64'(pe_mac_fires) : 64'd0);

                    completed_pe_active_cycles <=
                        layer_pe_active_cycles_q +
                        64'(pe_active_event);

                    completed_bank_wait_cycles <=
                        layer_bank_wait_cycles_q +
                        64'(bank_wait_event);

                    completed_dma_overlap_cycles <=
                        layer_dma_overlap_cycles_q +
                        64'(dma_overlap_event);

                    completed_dma_only_cycles <=
                        layer_dma_only_cycles_q +
                        64'(dma_only_event);
                end

                if (run_done)
                    run_active_q <= 1'b0;
            end
        end
    end

    initial begin
        if (PE_COUNT < 1)
            $fatal(1, "PE_COUNT must be positive");
    end

endmodule
