class pe_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(pe_scoreboard)

    uvm_analysis_imp #(pe_item, pe_scoreboard) analysis_export;
    int signed expected_acc = 0;
    int unsigned checked_cycles = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
    endfunction

    // Called by the monitor's analysis port. No driver/sequence predictions.
    virtual function void write(pe_item observed);
        int signed a, b;
        logic signed [7:0] expected_a, expected_b;
        logic expected_a_valid, expected_b_valid;
        checked_cycles++;

        if ($isunknown({observed.reset, observed.clear, observed.a_in,
                        observed.b_in, observed.a_valid_in, observed.b_valid_in})) begin
            `uvm_error("UNKNOWN_INPUT", "PE inputs contain X/Z")
            return;
        end

        // Explicit signed 32-bit operands make negative multiplication clear.
        a = observed.a_in;
        b = observed.b_in;
        if (observed.reset || observed.clear)
            expected_acc = 0;
        else if (observed.a_valid_in && observed.b_valid_in)
            expected_acc = expected_acc + a * b;

        // clear affects only acc. Invalid operands still travel to the next PE.
        expected_a = observed.reset ? 8'sd0 : observed.a_in;
        expected_b = observed.reset ? 8'sd0 : observed.b_in;
        expected_a_valid = observed.reset ? 1'b0 : observed.a_valid_in;
        expected_b_valid = observed.reset ? 1'b0 : observed.b_valid_in;

        if (observed.acc_out !== expected_acc ||
            observed.a_out !== expected_a || observed.b_out !== expected_b ||
            observed.a_valid_out !== expected_a_valid ||
            observed.b_valid_out !== expected_b_valid) begin
            `uvm_error("PE_MISMATCH", $sformatf(
                "cycle=%0d %s | expected acc=%0d a=%0d b=%0d valid=%0b%0b; observed acc=%0d a=%0d b=%0d valid=%0b%0b",
                checked_cycles, observed.convert2string(), expected_acc,
                expected_a, expected_b, expected_a_valid, expected_b_valid,
                observed.acc_out, observed.a_out, observed.b_out,
                observed.a_valid_out, observed.b_valid_out))
        end else begin
            `uvm_info("PE_CHECK", $sformatf("cycle=%0d %s -> acc=%0d OK",
                checked_cycles, observed.convert2string(), observed.acc_out), UVM_MEDIUM)
        end
    endfunction

    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (checked_cycles == 0)
            `uvm_error("NO_CHECKS", "Monitor sent no samples to the scoreboard")
    endfunction
endclass
