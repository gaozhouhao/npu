class pe_monitor extends uvm_monitor;
    `uvm_component_utils(pe_monitor)

    virtual pe_if vif;
    uvm_analysis_port #(pe_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual pe_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "pe_monitor needs pe_if from config_db")
    endfunction

    virtual task run_phase(uvm_phase phase);
        pe_item observed;
        forever begin
            @(posedge vif.clk);
            // The DUT uses <=; wait until its register updates have completed.
            #1ns;
            observed = pe_item::type_id::create("observed");
            observed.reset = vif.reset;
            observed.clear = vif.clear;
            observed.a_in = vif.a_in;
            observed.b_in = vif.b_in;
            observed.a_valid_in = vif.a_valid_in;
            observed.b_valid_in = vif.b_valid_in;
            observed.a_out = vif.a_out;
            observed.b_out = vif.b_out;
            observed.a_valid_out = vif.a_valid_out;
            observed.b_valid_out = vif.b_valid_out;
            observed.acc_out = vif.acc_out;
            `uvm_info("MON", observed.convert2string(), UVM_HIGH)
            ap.write(observed);
        end
    endtask
endclass
