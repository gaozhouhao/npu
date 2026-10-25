// Lesson 1 fixes the PE at DATA_WIDTH=8 and ACC_WIDTH=32.
interface pe_if(input logic clk);
    timeunit 1ns;
    timeprecision 1ps;

    // Known startup values let the very first rising edge reset the DUT.
    logic reset = 1'b1;
    logic clear = 1'b0;
    logic signed [7:0] a_in = '0;
    logic signed [7:0] b_in = '0;
    logic a_valid_in = 1'b0;
    logic b_valid_in = 1'b0;

    logic signed [7:0] a_out;
    logic signed [7:0] b_out;
    logic a_valid_out;
    logic b_valid_out;
    logic signed [31:0] acc_out;
endinterface
