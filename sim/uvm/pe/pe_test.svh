class pe_smoke_test extends uvm_test;
    `uvm_component_utils(pe_smoke_test)

    pe_env env;
    pe_smoke_sequence seq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = pe_env::type_id::create("env", this);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        seq = pe_smoke_sequence::type_id::create("seq");
        seq.start(env.agent.sequencer);
        // Each item_done follows monitor sampling, including the last item.
        phase.drop_objection(this);
    endtask

    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        // Include the startup reset at 5ns before the first driven item.
        if (seq == null) begin
            `uvm_error("NO_SEQUENCE", "The smoke sequence did not run")
        end else if (seq.sent_count == 0 ||
                     env.scoreboard.checked_cycles != seq.sent_count + 1) begin
            `uvm_error("CYCLE_COUNT", $sformatf("sent=%0d observed=%0d (expected sent+1)",
                seq.sent_count, env.scoreboard.checked_cycles))
        end
    endfunction

    virtual function void report_phase(uvm_phase phase);
        uvm_report_server server;
        super.report_phase(phase);
        server = uvm_report_server::get_server();
        if (server.get_severity_count(UVM_ERROR) == 0 &&
            server.get_severity_count(UVM_FATAL) == 0)
            `uvm_info("TEST_PASS", $sformatf("%s checked %0d cycles",
                get_type_name(), env.scoreboard.checked_cycles), UVM_NONE)
    endfunction
endclass
