module buffer_manager #(
    parameter int BUFFER_COUNT = 1
) (
    input logic clk,
    input logic reset,

    // Load side
    input  logic load_req,
    output logic load_grant,
    output logic load_bank,
    input  logic load_done,

    // Compute side
    input  logic compute_req,
    output logic compute_grant,
    output logic compute_bank,

    input  logic compute_done,
    input  logic release_bank
);

    // ============================================================
    // Bank states
    // ============================================================

    typedef enum logic [1:0] {
        EMPTY,
        LOADING,
        READY,
        COMPUTING
    } bank_state_t;

    bank_state_t bank_state [0:BUFFER_COUNT-1];


    // ============================================================
    // Active operations
    // ============================================================

    logic load_active;
    logic load_bank_q;

    logic compute_active;
    logic compute_bank_q;


    // ============================================================
    // Bank search result
    // ============================================================

    logic empty_found;
    logic empty_bank;

    logic ready_found;
    logic ready_bank;


    // Loop variables
    integer empty_idx;
    integer ready_idx;
    integer reset_idx;


    // ============================================================
    // Find first EMPTY bank
    // ============================================================

    always_comb begin

        empty_found = 1'b0;
        empty_bank  = 1'b0;

        for (
            empty_idx = 0;
            empty_idx < BUFFER_COUNT;
            empty_idx = empty_idx + 1
        ) begin

            if (
                !empty_found &&
                (bank_state[empty_idx] == EMPTY)
            ) begin

                empty_found = 1'b1;

                // BUFFER_COUNT only supports 1 or 2
                empty_bank = (empty_idx == 1);

            end

        end

    end


    // ============================================================
    // Find first READY bank
    // ============================================================

    always_comb begin

        ready_found = 1'b0;
        ready_bank  = 1'b0;

        for (
            ready_idx = 0;
            ready_idx < BUFFER_COUNT;
            ready_idx = ready_idx + 1
        ) begin

            if (
                !ready_found &&
                (bank_state[ready_idx] == READY)
            ) begin

                ready_found = 1'b1;

                // BUFFER_COUNT only supports 1 or 2
                ready_bank = (ready_idx == 1);

            end

        end

    end


    // ============================================================
    // Handshake
    // ============================================================

    assign load_grant =
        load_req &&
        !load_active &&
        empty_found;

    assign compute_grant =
        compute_req &&
        !compute_active &&
        ready_found;


    // ============================================================
    // Bank selection
    // ============================================================

    // Once an operation starts, keep bank selection stable.

    assign load_bank =
        load_active
            ? load_bank_q
            : empty_bank;

    assign compute_bank =
        compute_active
            ? compute_bank_q
            : ready_bank;


    // ============================================================
    // State update
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            load_active    <= 1'b0;
            load_bank_q    <= 1'b0;

            compute_active <= 1'b0;
            compute_bank_q <= 1'b0;

            for (
                reset_idx = 0;
                reset_idx < BUFFER_COUNT;
                reset_idx = reset_idx + 1
            ) begin

                bank_state[reset_idx] <= EMPTY;

            end

        end else begin

            // ----------------------------------------------------
            // Start load
            // EMPTY -> LOADING
            // ----------------------------------------------------

            if (load_grant) begin

                load_active <= 1'b1;
                load_bank_q <= empty_bank;

                bank_state[empty_bank] <= LOADING;

            end


            // ----------------------------------------------------
            // Load complete
            // LOADING -> READY
            // ----------------------------------------------------

            if (load_active && load_done) begin

                bank_state[load_bank_q] <= READY;

                load_active <= 1'b0;

            end


            // ----------------------------------------------------
            // Start compute
            // READY -> COMPUTING
            // ----------------------------------------------------

            if (compute_grant) begin

                compute_active <= 1'b1;
                compute_bank_q <= ready_bank;

                bank_state[ready_bank] <= COMPUTING;

            end


            // ----------------------------------------------------
            // Compute complete
            //
            // release_bank = 1:
            // COMPUTING -> EMPTY
            //
            // release_bank = 0:
            // COMPUTING -> READY
            // ----------------------------------------------------

            if (compute_active && compute_done) begin

                if (release_bank) begin

                    bank_state[compute_bank_q] <= EMPTY;

                end else begin

                    bank_state[compute_bank_q] <= READY;

                end

                compute_active <= 1'b0;

            end

        end

    end


    // ============================================================
    // Parameter check
    // ============================================================

    initial begin

        if (
            (BUFFER_COUNT != 1) &&
            (BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "BUFFER_COUNT must be 1 or 2"
            );

        end

    end

endmodule
