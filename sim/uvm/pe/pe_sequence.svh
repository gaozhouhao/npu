// Directed examples followed by ten small random input cycles.
class pe_smoke_sequence extends uvm_sequence #(pe_item);
    `uvm_object_utils(pe_smoke_sequence)

    int unsigned sent_count = 0;

    function new(string name = "pe_smoke_sequence");
        super.new(name);
    endfunction

    task send_cycle(string label, bit reset, bit clear,
                    int signed a, int signed b, bit a_valid, bit b_valid);
        pe_item req;
        req = pe_item::type_id::create(label);
        start_item(req);
        req.reset = reset;
        req.clear = clear;
        req.a_in = 8'(a);
        req.b_in = 8'(b);
        req.a_valid_in = a_valid;
        req.b_valid_in = b_valid;
        `uvm_info("SEQ", $sformatf("%s: %s", label, req.convert2string()), UVM_MEDIUM)
        finish_item(req);
        sent_count++;
    endtask

    virtual task body();
        sent_count = 0;
        // label               reset clear  a     b    a_valid b_valid
        send_cycle("reset",        1, 1,    11,   -3,   1, 1);
        send_cycle("first_mac",    0, 0,     3,   -4,   1, 1); // -12
        send_cycle("second_mac",   0, 0,     2,    6,   1, 1); // -12 + 2*6 = 0
        send_cycle("hold_00",      0, 0,     7,    9,   0, 0);
        send_cycle("hold_10",      0, 0,    -8,    6,   1, 0);
        send_cycle("hold_01",      0, 0,     4,   -5,   0, 1);
        send_cycle("clear",        0, 1,     9,    9,   1, 1); // 0, still forward a/b
        send_cycle("negative_pair",0, 0,    -2,   -3,   1, 1); // 6
        send_cycle("min_times_neg",0, 0,  -128,   -1,   1, 1); // 134
        send_cycle("max_pair",     0, 0,   127,  127,   1, 1); // 16263
        send_cycle("min_times_max",0, 0,  -128,  127,   1, 1); // 7
        send_cycle("zero",         0, 0,     0, -128,   1, 1); // 7
        send_cycle("reset_again",  1, 0,    12,   13,   1, 1); // 0
        send_cycle("restart",      0, 0,     4,   -5,   1, 1); // -20
        send_cycle("idle",         0, 0,     0,    0,   0, 0); // -20

        send_cycle("clear_before_random", 0, 1, 0, 0, 0, 0);

        repeat  (10) begin
            int a, b;
            bit a_valid, b_valid;

            a = $urandom_range(15, 0);
            b = $urandom_range(15, 0);

            a -= 8;
            b -= 8;

            a_valid = $urandom_range(1, 0);
            b_valid = $urandom_range(1, 0);

            send_cycle("random_mac", 0, 0, a, b, a_valid, b_valid);

        end

    endtask
endclass
