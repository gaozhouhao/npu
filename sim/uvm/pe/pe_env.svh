class pe_env extends uvm_env;
    `uvm_component_utils(pe_env)

    pe_agent agent;
    pe_scoreboard scoreboard;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = pe_agent::type_id::create("agent", this);
        scoreboard = pe_scoreboard::type_id::create("scoreboard", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.monitor.ap.connect(scoreboard.analysis_export);
    endfunction
endclass
