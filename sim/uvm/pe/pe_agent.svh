// The first lesson uses one active agent and the standard UVM sequencer.
class pe_agent extends uvm_agent;
    `uvm_component_utils(pe_agent)

    uvm_sequencer #(pe_item) sequencer;
    pe_driver driver;
    pe_monitor monitor;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sequencer = uvm_sequencer#(pe_item)::type_id::create("sequencer", this);
        driver = pe_driver::type_id::create("driver", this);
        monitor = pe_monitor::type_id::create("monitor", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
endclass
