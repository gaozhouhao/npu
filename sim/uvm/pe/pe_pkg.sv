package pe_pkg;
    timeunit 1ns;
    timeprecision 1ps;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Compile order follows the dependency between the small classes.
    `include "pe_item.svh"
    `include "pe_sequence.svh"
    `include "pe_driver.svh"
    `include "pe_monitor.svh"
    `include "pe_agent.svh"
    `include "pe_scoreboard.svh"
    `include "pe_env.svh"
    `include "pe_test.svh"
    `include "pe_user_test.svh"
endpackage
