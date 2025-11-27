// Copyright 2025 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Round-robin warp scheduler with per-warp state tracking. This keeps all
// warp-specific bookkeeping out of the core and feeds the IF stage with the
// next warp to fetch from.


module cvt40_warp_scheduler #(
    parameter int unsigned NUM_WARPS = 1,
    parameter int unsigned WID_WIDTH = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS)
) (
    input  logic clk,
    input  logic rst_n,

    // Scheduler advances only when the IF stage issues an instruction.
    input  logic sched_enable_i,

    // SIMT control operations.
    input  logic                         simt_cmd_valid_i,
    input  cvt40_pkg::simt_opcode_e      simt_cmd_op_i,
    input  logic [WID_WIDTH-1:0]         simt_cmd_wid_i,
    input  logic [NUM_WARPS-1:0]         simt_cmd_mask_i,

    // Selected warp
    output logic                          warp_valid_o,
    output logic [WID_WIDTH-1:0]          warp_id_o
);

  import cvt40_pkg::*;

  typedef enum logic [1:0] {
    W_STATE_INACTIVE = 2'b00,
    W_STATE_ACTIVE   = 2'b01,
    W_STATE_DONE     = 2'b10
  } warp_state_e;

  warp_state_e warp_state_q[NUM_WARPS];
  warp_state_e warp_state_d[NUM_WARPS];
  logic [NUM_WARPS-1:0] warp_active_mask;

  logic [WID_WIDTH-1:0] last_grant_q, last_grant_d;
  logic [WID_WIDTH-1:0] next_warp;
  logic                 next_valid;

  always_comb begin
    warp_state_d     = warp_state_q;
    warp_active_mask = '0;

    // SIMT control operations update per-warp state.
    if (simt_cmd_valid_i) begin
      unique case (simt_cmd_op_i)
        SIMT_OP_WSPAWN: begin
          for (int unsigned w = 0; w < NUM_WARPS; w++) begin
            if (simt_cmd_mask_i[w]) begin
              warp_state_d[w] = W_STATE_ACTIVE;
            end
          end
        end
        SIMT_OP_EXIT: begin
          warp_state_d[simt_cmd_wid_i] = W_STATE_DONE;
        end
        default: ;
      endcase
    end

    for (int unsigned w = 0; w < NUM_WARPS; w++) begin
      warp_active_mask[w] = (warp_state_q[w] == W_STATE_ACTIVE);
    end
  end

  always_comb begin
    next_warp  = '0;
    next_valid = 1'b0;

    logic [WID_WIDTH-1:0] probe;
    probe = last_grant_q;

    // Round-robin search for the next active warp.
    for (int unsigned i = 0; i < NUM_WARPS; i++) begin
      if (probe == NUM_WARPS-1) begin
        probe = '0;
      end else begin
        probe = probe + 1'b1;
      end

      if (warp_active_mask[probe]) begin
        next_warp  = probe;
        next_valid = 1'b1;
        break;
      end
    end
  end

  assign warp_valid_o = next_valid;
  assign warp_id_o    = next_warp;

  always_comb begin
    last_grant_d = last_grant_q;
    if (sched_enable_i && next_valid) begin
      last_grant_d = next_warp;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_grant_q <= '0;
      for (int unsigned w = 0; w < NUM_WARPS; w++) begin
        warp_state_q[w] <= (0 == w) ? W_STATE_ACTIVE : W_STATE_INACTIVE;
      end
    end else begin
      last_grant_q <= last_grant_d;
      for (int unsigned w = 0; w < NUM_WARPS; w++) begin
        warp_state_q[w] <= warp_state_d[w];
      end
    end
  end

endmodule
