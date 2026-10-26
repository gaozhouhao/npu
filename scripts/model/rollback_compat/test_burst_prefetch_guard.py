#!/usr/bin/env python3
"""Test observation assertions and handshake counters without changing a DUT."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).with_name('burst_prefetch_guard.sv')

TB = r'''module burst_guard_tb;
  logic clk = 0;
  always #5 clk = !clk;
  logic reset = 1, cmd_valid = 0, cmd_ready = 1, done = 0;
  logic [31:0] cmd_m = 4, cmd_n = 4, cmd_k = 768;
  logic cmd_conv_mode = 1;
  logic a_load_req = 0, a_load_accept = 0, a_load_done = 0;
  logic b_load_req = 0, b_load_accept = 0, b_load_done = 0;
  logic [15:0] load_m = 0, load_n = 0, load_k = 0;
  logic matrix_start = 0, core_done = 0, core_busy = 0;
  logic operand_rvalid = 0, operand_rready = 0, a_wen = 0, b_wen = 0;
  logic conv_req_valid = 0, conv_req_ready = 0;
  logic [31:0] conv_req_beats = 2;
  logic conv_data_valid = 0, conv_data_ready = 0;
  integer which = 0;
  burst_prefetch_guard #(.EXPECTED_BANKS(`TEST_BANKS),
    .A_BUFFER_COUNT(`TEST_ACTUAL_BANKS), .B_BUFFER_COUNT(`TEST_ACTUAL_BANKS)) monitor (.*);
  task tick;
    @(posedge clk); #1; @(negedge clk);
  endtask
  task load_operands(input integer index_value);
    load_k = 16'(index_value);
    a_load_req = 1; b_load_req = 1;
    // Request without acceptance is not a new load.
    repeat (2) tick();
    a_load_accept = 1; b_load_accept = 1; tick();
    a_load_req = 0; b_load_req = 0; a_load_accept = 0; b_load_accept = 0;
    conv_req_valid = 1;
    // Held valid under backpressure must count exactly once.
    repeat (3) tick();
    conv_req_ready = 1; tick();
    conv_req_valid = 0; conv_req_ready = 0;
    conv_data_valid = 1; conv_data_ready = 1;
    operand_rvalid = 1; operand_rready = 1; a_wen = 1;
    tick();
    if (which != 6) tick();
    conv_data_valid = 0; conv_data_ready = 0;
    operand_rvalid = 0; operand_rready = 0; a_wen = 0;
    a_load_done = 1; b_load_done = 1; tick();
    a_load_done = 0; b_load_done = 0; tick();
  endtask
  task launch;
    matrix_start = 1; tick(); matrix_start = 0; core_busy = 1; tick();
  endtask
  task finish_core;
    repeat (3) tick(); core_busy = 0; core_done = 1; tick(); core_done = 0; tick();
  endtask
  initial begin
    if (!$value$plusargs("CASE=%d", which)) which = 0;
    $display("BURST_GUARD_CASE,%0d", which);
    tick(); reset = 0; cmd_valid = 1; tick(); cmd_valid = 0;
    load_operands(0);
    if (which == 5) begin
      a_load_done = 1; tick();
      $fatal(1, "NEGATIVE_CASE_WAS_NOT_REJECTED");
    end
    launch();
    if (which == 4) begin
      load_operands(0);
      $fatal(1, "NEGATIVE_CASE_WAS_NOT_REJECTED");
    end
    if (which == 0 || which == 3) finish_core();
    if (which != 3) load_operands(1);
    if (which == 1 || which == 2 || which == 4 || which == 5 || which == 6) finish_core();
    launch();
    if (which == 3) $fatal(1, "NEGATIVE_CASE_WAS_NOT_REJECTED");
    if (which == 0) finish_core();
    load_operands(2);
    if (which != 0) finish_core();
    launch(); finish_core();
    done = 1; tick(); done = 0;
    if (which == 6) $fatal(1, "NEGATIVE_CASE_WAS_NOT_REJECTED");
    $display("BURST_GUARD_UNIT_PASS"); $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'build/resnet50-burst-guard-tests')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    raw = SOURCE.read_bytes()
    module = raw.split(b'module burst_prefetch_bank_guard', 1)[0]
    (out / 'guard_module.sv').write_bytes(module)
    (out / 'burst_guard_tb.sv').write_text(TB)
    cases = [
        (0, 1, 1, 'serial_no_overlap', 'BURST_GUARD_UNIT_PASS'),
        (1, 2, 2, 'prefetch_overlap', 'BURST_GUARD_UNIT_PASS'),
        (2, 1, 1, 'reject_single_bank_overlap', 'single-bank load/compute overlap'),
        (3, 2, 2, 'reject_missing_reload', 'compute requires fresh completed A/B loads'),
        (4, 2, 2, 'reject_wrong_load_order', 'A must reload every M/N/K tile in order'),
        (5, 2, 2, 'reject_unaccepted_completion', 'A completion without an accepted load'),
        (6, 2, 2, 'reject_missing_burst_data', 'Conv requested/received word mismatch'),
        (7, 2, 1, 'reject_wrong_bank_count', 'unexpected executor bank counts'),
    ]
    builds = {}
    results = []
    for case, banks, actual, name, message in cases:
        key = (banks, actual)
        if key not in builds:
            binary = out / ('simv-%d-%d' % key)
            command = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps',
                       '+define+TEST_BANKS=%d+TEST_ACTUAL_BANKS=%d' % key,
                       '-top', 'burst_guard_tb', str(out / 'guard_module.sv'),
                       str(out / 'burst_guard_tb.sv'), '-Mdir=' + str(binary) + '.csrc',
                       '-o', str(binary)]
            with (out / ('compile-%d-%d.log' % key)).open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=out)
            builds[key] = binary
        result = subprocess.run([str(builds[key]), '+CASE=%d' % case],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, cwd=out, timeout=30)
        (out / ('case-%d.log' % case)).write_text(result.stdout)
        passed = message in result.stdout and 'NEGATIVE_CASE_WAS_NOT_REJECTED' not in result.stdout
        if case in (0, 1):
            passed = passed and result.returncode == 0 and all(text in result.stdout for text in [
                'tiles=3,a_loads=3,b_loads=3,a_finished=3,b_finished=3,launched=3,completed=3',
                'conv_requests=3,conv_words=6,conv_max_beats=2,conv_multibeat_requests=3,conv_received=6'])
            line = next((line for line in result.stdout.splitlines()
                         if line.startswith('BURST_PREFETCH_CHECK,PASS,')), '')
            fields = dict(field.split('=', 1) for field in line.split(',')[2:])
            passed = passed and (int(fields.get('overlap_cycles', '-1')) == 0 if case == 0
                                 else int(fields.get('overlap_cycles', '0')) > 0)
        else:
            # This VCS release may return zero for $fatal. Match the guard's
            # diagnostic and exclude both the fallback fatal and normal pass.
            passed = passed and 'Fatal:' in result.stdout and 'guard_module.sv' in result.stdout
            passed = passed and 'BURST_GUARD_UNIT_PASS' not in result.stdout
        results.append(dict(case=case, name=name, expected=message,
                            returncode=result.returncode, passed=passed))
    report = dict(guard_sha256=hashlib.sha256(raw).hexdigest(), cases=results,
                  source_unchanged=SOURCE.read_bytes() == raw,
                  passed=all(item['passed'] for item in results) and SOURCE.read_bytes() == raw)
    (out / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
