class pe_driver extends uvm_driver #(pe_item);
    `uvm_component_utils(pe_driver)

    virtual pe_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual pe_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "pe_driver needs pe_if from config_db")
    endfunction

    virtual task run_phase(uvm_phase phase);
        pe_item req;
        forever begin
            seq_item_port.get_next_item(req);
            // Drive halfway before the PE's active edge to avoid a race.
            @(negedge vif.clk);
            vif.reset = req.reset;
            vif.clear = req.clear;
            vif.a_in = req.a_in;
            vif.b_in = req.b_in;
            vif.a_valid_in = req.a_valid_in;
            vif.b_valid_in = req.b_valid_in;
            `uvm_info("DRV", req.convert2string(), UVM_HIGH)

            @(posedge vif.clk);
            // Monitor samples at +1ns. Only finish after that check has run.
            #2ns;
            seq_item_port.item_done();
        end
    endtask
endclass
