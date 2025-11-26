// Copyright 2025 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Round-robin warp scheduler with per-warp PC/state tracking. This keeps all
// warp-specific bookkeeping out of the core and feeds the IF stage with the
// next warp to fetch from.

//TODO: make the PC management in the if aligner

module cvt40_warp_scheduler #(
    parameter int unsigned NUM_WARPS = 1,
    parameter int unsigned WID_WIDTH = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS)
) (
    input  logic clk,
    input  logic rst_n,

    // Scheduler advances when this enable is asserted in the same cycle in
    // which a warp has been granted.
    input  logic sched_enable_i,

    // Sequential PC update for the issued warp.
    input  logic                 instr_issue_i,
    input  logic [31:0]          instr_pc_i,
    input  logic [WID_WIDTH-1:0] instr_warp_i,

    // Redirect PC for a given warp (branches/interrupts).
    input  logic                 branch_set_i,
    input  logic [WID_WIDTH-1:0] branch_warp_i,
    input  logic [31:0]          branch_target_i,

    // Stall the warp currently in ID when downstream is not ready.
    input  logic                 hold_warp_i,
    input  logic [WID_WIDTH-1:0] hold_warp_id_i,

    // SIMT control operations.
    input  logic                         simt_cmd_valid_i,
    input  cvt40_pkg::simt_opcode_e      simt_cmd_op_i,
    input  logic [WID_WIDTH-1:0]         simt_cmd_wid_i,
    input  logic [NUM_WARPS-1:0]         simt_cmd_mask_i,
    input  logic [31:0]                  simt_cmd_pc_i,

    // Boot address for initial PC.
    input  logic [31:0] boot_addr_i,

    // Selected warp and its PC.
    output logic                          warp_valid_o,
    output logic [WID_WIDTH-1:0]          warp_id_o,
    output logic [31:0]                   warp_pc_o
);

  import cvt40_pkg::*;

  typedef enum logic [1:0] {
    W_STATE_INACTIVE = 2'b00,
    W_STATE_ACTIVE   = 2'b01,
    W_STATE_DONE     = 2'b10
  } warp_state_e;

  warp_state_e warp_state_q[NUM_WARPS];
  warp_state_e warp_state_d[NUM_WARPS];
  logic [31:0] warp_pc_q   [NUM_WARPS];
  logic [31:0] warp_pc_d   [NUM_WARPS];
  logic [NUM_WARPS-1:0] warp_ready_mask;
  logic [NUM_WARPS-1:0] warp_active_mask;
  logic [NUM_WARPS-1:0] warp_stall_mask;

  logic [WID_WIDTH-1:0] idx;
  logic [WID_WIDTH-1:0] last_grant_q, last_grant_d;
  logic [WID_WIDTH-1:0] next_warp;
  logic                 next_valid;

  always_comb begin
    warp_pc_d        = warp_pc_q;
    warp_state_d     = warp_state_q;
    warp_stall_mask  = '0;
    warp_active_mask = '0;

    // Hold a warp out of scheduling when ID is stalled on it.
    if (hold_warp_i) begin
      warp_stall_mask[hold_warp_id_i] = 1'b1;
    end

    // Sequential PC bump for the issued warp.
    if (instr_issue_i) begin
      warp_pc_d[instr_warp_i] = instr_pc_i + 32'd4;
    end

    // Redirect overrides sequential update.
    if (branch_set_i) begin
      warp_pc_d[branch_warp_i] = branch_target_i;
    end

    // SIMT control operations update per-warp state.
    if (simt_cmd_valid_i) begin
      unique case (simt_cmd_op_i)
        SIMT_OP_WSPAWN: begin
          for (int unsigned w = 0; w < NUM_WARPS; w++) begin
            if (simt_cmd_mask_i[w]) begin
              warp_pc_d[w]    = simt_cmd_pc_i;
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
    warp_ready_mask = warp_active_mask & ~warp_stall_mask;
  end

  always_comb begin
    next_warp  = '0;
    next_valid = 1'b0;
    idx = 0;

    // If the last granted warp is ready, give it priority.
    if (warp_ready_mask[last_grant_q]) begin
      next_warp  = last_grant_q;
      next_valid = 1'b1;
    end else begin
      
      idx = last_grant_q;

      // Otherwise, search for the next ready warp in a round-robin fashion.
      for (int i = 1; i < NUM_WARPS; i++) begin
        
        // Check if idx has wrapped around the maximum warp ID (all 1s) 
        if (&idx == 1'b1) begin
          idx = '0;
        end else begin
          idx = idx + 1;
        end

        if (warp_ready_mask[idx]) begin
          next_warp  = idx;
          next_valid = 1'b1;
          break;
        end
      end
    end
  end

  assign warp_valid_o = next_valid;
  assign warp_id_o    = next_warp;
  assign warp_pc_o    = warp_pc_q[next_warp];

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
        warp_pc_q[w]    <= boot_addr_i;
        warp_state_q[w] <= (0 == w) ? W_STATE_ACTIVE : W_STATE_INACTIVE;
      end
    end else begin
      last_grant_q <= last_grant_d;
      for (int unsigned w = 0; w < NUM_WARPS; w++) begin
        warp_pc_q[w]    <= warp_pc_d[w];
        warp_state_q[w] <= warp_state_d[w];
      end
    end
  end

endmodule
