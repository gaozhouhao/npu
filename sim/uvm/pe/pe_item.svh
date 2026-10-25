// One item describes the inputs for ONE clock cycle.
// The monitor also fills in the outputs it actually observed that cycle.
class pe_item extends uvm_sequence_item;
    `uvm_object_utils(pe_item)

    logic reset = 0;
    logic clear = 0;
    logic signed [7:0] a_in = 0;
    logic signed [7:0] b_in = 0;
    logic a_valid_in = 0;
    logic b_valid_in = 0;

    logic signed [7:0] a_out;
    logic signed [7:0] b_out;
    logic a_valid_out;
    logic b_valid_out;
    logic signed [31:0] acc_out;

    function new(string name = "pe_item");
        super.new(name);
    endfunction

    virtual function string convert2string();
        return $sformatf("reset=%0b clear=%0b a=%0d b=%0d valid=%0b%0b",
                         reset, clear, a_in, b_in, a_valid_in, b_valid_in);
    endfunction
endclass
