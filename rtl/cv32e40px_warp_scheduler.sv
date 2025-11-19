// Copyright 2025 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Simple round-robin warp scheduler used to select the next warp that should
// issue a fetch request. This is a first step towards supporting multiple warps
// in flight; the logic currently only depends on the per-warp active/stall
// status and advances the internal pointer whenever the caller indicates that a
// fetch request has been accepted.

module cv32e40px_warp_scheduler #(
    parameter int unsigned NUM_WARPS   = 1,
    parameter int unsigned WID_WIDTH   = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS)
) (
    input  logic clk,
    input  logic rst_n,

    // Scheduler advances when this enable is asserted in the same cycle in
    // which a warp has been granted.
    input  logic sched_enable_i,

    // Warp status.
    input  logic [NUM_WARPS-1:0] warp_active_i,
    input  logic [NUM_WARPS-1:0] warp_stall_i,

    // Selected warp.
    output logic                          warp_valid_o,
    output logic [WID_WIDTH-1:0]          warp_id_o
);

  logic [WID_WIDTH-1:0] last_grant_q, last_grant_d;
  logic [WID_WIDTH-1:0] next_warp;
  logic                 next_valid;

  logic [NUM_WARPS-1:0] ready_mask;
  assign ready_mask = warp_active_i & ~warp_stall_i;

  always_comb begin
    next_warp  = '0;
    next_valid = 1'b0;

    if (NUM_WARPS == 0) begin
      // No warps configured.
      next_warp  = '0;
      next_valid = 1'b0;
    end else begin
      for (int unsigned offset = 0; offset < NUM_WARPS; offset++) begin
        int unsigned candidate = (last_grant_q + offset) % NUM_WARPS;
        if (ready_mask[candidate]) begin
          next_warp  = candidate[WID_WIDTH-1:0];
          next_valid = 1'b1;
          break;
        end
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
    end else begin
      last_grant_q <= last_grant_d;
    end
  end

endmodule
