// Lesson 2: add a test while reusing the existing driver, monitor and checker.
class pe_clear_priority_sequence extends pe_smoke_sequence;
    `uvm_object_utils(pe_clear_priority_sequence)

    function new(string name = "pe_clear_priority_sequence");
        super.new(name);
    endfunction

    // Test writers put the input scenario here. send_cycle is inherited.
    virtual task body();
        sent_count = 0;
        // label                  reset clear a  b  a_valid b_valid
        send_cycle("reset",           1, 0,  0, 0, 0, 0); // acc = 0
        send_cycle("make_nonzero",    0, 0,  3, 4, 1, 1); // acc = 12
        send_cycle("clear_beats_mac", 0, 1,  7, 8, 1, 1); // acc = 0; still forward 7,8
        send_cycle("resume",          0, 0,  2, 3, 1, 1); // acc = 6
    endtask
endclass

class pe_clear_priority_test extends pe_smoke_test;
    `uvm_component_utils(pe_clear_priority_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // The inherited build/connect/check phases keep the same environment.
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        // Assign the inherited seq handle so the inherited count check sees it.
        seq = pe_clear_priority_sequence::type_id::create("seq");
        seq.start(env.agent.sequencer);
        phase.drop_objection(this);
    endtask
endclass
