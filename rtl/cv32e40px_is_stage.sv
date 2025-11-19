// Copyright 2025 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Issue stage with a simple per-warp scoreboard. One decoded instruction per
// warp can be resident in the local buffer; the scoreboard tracks register
// dependencies so that multiple instructions from the same warp can be in
// flight simultaneously once this block is connected to the rest of the
// pipeline.

module cv32e40px_is_stage #(
    parameter int unsigned NUM_WARPS      = 1,
    parameter int unsigned WID_WIDTH      = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS),
    parameter int unsigned PAYLOAD_WIDTH  = 64,
    parameter int unsigned NUM_REGS       = 32
) (
    input  logic clk,
    input  logic rst_n,

    // Push interface from decode.
    input  logic                  push_valid_i,
    output logic                  push_ready_o,
    input  logic [WID_WIDTH-1:0]  push_wid_i,
    input  logic [31:0]           push_pc_i,
    input  logic [4:0]            push_rd_i,
    input  logic                  push_rd_we_i,
    input  logic [4:0]            push_rs1_i,
    input  logic [4:0]            push_rs2_i,
    input  logic [4:0]            push_rs3_i,
    input  logic [PAYLOAD_WIDTH-1:0] push_payload_i,

    // Structural readiness per warp (e.g. unit availability).
    input  logic [NUM_WARPS-1:0] warp_struct_ready_i,

    // Issue interface towards execute.
    output logic                 issue_valid_o,
    input  logic                 issue_ready_i,
    output logic [WID_WIDTH-1:0] issue_wid_o,
    output logic [31:0]          issue_pc_o,
    output logic [4:0]           issue_rd_o,
    output logic                 issue_rd_we_o,
    output logic [4:0]           issue_rs1_o,
    output logic [4:0]           issue_rs2_o,
    output logic [4:0]           issue_rs3_o,
    output logic [PAYLOAD_WIDTH-1:0] issue_payload_o,

    // Feedback from writeback to clear scoreboard entries.
    input  logic                 wb_valid_i,
    input  logic [WID_WIDTH-1:0] wb_wid_i,
    input  logic [4:0]           wb_rd_i,
    input  logic                 wb_rd_we_i,

    // Per-warp stall indication back to IF scheduler.
    output logic [NUM_WARPS-1:0] warp_stall_o
);

  typedef struct packed {
    logic [31:0]             pc;
    logic [4:0]              rd;
    logic                    rd_we;
    logic [4:0]              rs1;
    logic [4:0]              rs2;
    logic [4:0]              rs3;
    logic [PAYLOAD_WIDTH-1:0] payload;
  } issue_slot_t;

  issue_slot_t               slot_q   [NUM_WARPS];
  logic [NUM_WARPS-1:0]      slot_valid_q;
  issue_slot_t               slot_d   [NUM_WARPS];
  logic [NUM_WARPS-1:0]      slot_valid_d;

  logic [NUM_WARPS-1:0][NUM_REGS-1:0] reg_busy_q, reg_busy_d;

  logic [NUM_WARPS-1:0] data_ready_mask;
  logic [NUM_WARPS-1:0] issue_ready_mask;

  // ---------------------------------------------------------------------------
  // Push interface
  // ---------------------------------------------------------------------------

  assign push_ready_o = ~slot_valid_q[push_wid_i]; // Backpressure if warp already has a buffered instruction.

  always_comb begin
    slot_d       = slot_q;
    slot_valid_d = slot_valid_q;

    if (push_valid_i && push_ready_o) begin
      slot_d[push_wid_i].pc       = push_pc_i;
      slot_d[push_wid_i].rd       = push_rd_i;
      slot_d[push_wid_i].rd_we    = push_rd_we_i;
      slot_d[push_wid_i].rs1      = push_rs1_i;
      slot_d[push_wid_i].rs2      = push_rs2_i;
      slot_d[push_wid_i].rs3      = push_rs3_i;
      slot_d[push_wid_i].payload  = push_payload_i;
      slot_valid_d[push_wid_i]    = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Scoreboard
  // ---------------------------------------------------------------------------

  function automatic logic reg_is_ready (
      input logic [NUM_REGS-1:0] busy_vec,
      input logic [4:0]          reg_sel
  );
    logic ready;
    begin
      if (reg_sel == 5'd0) begin
        ready = 1'b1;
      end else begin
        ready = ~busy_vec[reg_sel];
      end
      return ready;
    end
  endfunction

  always_comb begin
    data_ready_mask = '0;
    for (int unsigned w = 0; w < NUM_WARPS; w++) begin
      if (slot_valid_q[w]) begin
        logic rs1_ready = reg_is_ready(reg_busy_q[w], slot_q[w].rs1);
        logic rs2_ready = reg_is_ready(reg_busy_q[w], slot_q[w].rs2);
        logic rs3_ready = reg_is_ready(reg_busy_q[w], slot_q[w].rs3);
        logic rd_ready  = reg_is_ready(reg_busy_q[w], slot_q[w].rd);
        data_ready_mask[w] = rs1_ready & rs2_ready & rs3_ready & rd_ready;
      end
    end
  end

  // Warp can issue if it has a buffered instruction, no data hazard, and its target unit is ready.
  assign issue_ready_mask = slot_valid_q & data_ready_mask & warp_struct_ready_i;

  logic [WID_WIDTH-1:0] issue_rr_ptr_q, issue_rr_ptr_d;
  logic [WID_WIDTH-1:0] issue_sel_wid;
  logic issue_sel_valid;

  always_comb begin
    issue_sel_wid   = '0;
    issue_sel_valid = 1'b0;
    if (NUM_WARPS != 0) begin
      for (int unsigned offset = 0; offset < NUM_WARPS; offset++) begin
        int unsigned candidate = (issue_rr_ptr_q + offset) % NUM_WARPS;
        if (issue_ready_mask[candidate]) begin
          issue_sel_wid   = candidate[WID_WIDTH-1:0];
          issue_sel_valid = 1'b1;
          break;
        end
      end
    end
  end

  assign issue_valid_o   = issue_sel_valid;
  assign issue_wid_o     = issue_sel_wid;
  assign issue_pc_o      = slot_q[issue_sel_wid].pc;
  assign issue_rd_o      = slot_q[issue_sel_wid].rd;
  assign issue_rd_we_o   = slot_q[issue_sel_wid].rd_we;
  assign issue_rs1_o     = slot_q[issue_sel_wid].rs1;
  assign issue_rs2_o     = slot_q[issue_sel_wid].rs2;
  assign issue_rs3_o     = slot_q[issue_sel_wid].rs3;
  assign issue_payload_o = slot_q[issue_sel_wid].payload;

  function automatic logic [WID_WIDTH-1:0] wid_inc (
      input logic [WID_WIDTH-1:0] val
  );
    logic [WID_WIDTH-1:0] next;
    begin
      if (NUM_WARPS <= 1) begin
        next = '0;
      end else if (val == WID_WIDTH'(NUM_WARPS - 1)) begin
        next = '0;
      end else begin
        next = val + 1'b1;
      end
      return next;
    end
  endfunction

  logic issue_fire;
  assign issue_fire = issue_valid_o && issue_ready_i;

  always_comb begin
    issue_rr_ptr_d = issue_rr_ptr_q;
    reg_busy_d     = reg_busy_q;

    if (issue_fire) begin
      slot_valid_d[issue_sel_wid] = 1'b0;
      if (slot_q[issue_sel_wid].rd_we && (slot_q[issue_sel_wid].rd != 5'd0)) begin
        reg_busy_d[issue_sel_wid][slot_q[issue_sel_wid].rd] = 1'b1;
      end
      issue_rr_ptr_d = wid_inc(issue_sel_wid);
    end

    if (wb_valid_i && wb_rd_we_i && (wb_rd_i != 5'd0)) begin
      reg_busy_d[wb_wid_i][wb_rd_i] = 1'b0;
    end
  end

  // Warp stall feedback
  // A warp is considered stalled if it holds an instruction that cannot currently issue.
  assign warp_stall_o = slot_valid_q & ~issue_ready_mask;

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slot_q        <= '{default: '0};
      slot_valid_q  <= '0;
      reg_busy_q    <= '{default: '0};
      issue_rr_ptr_q <= '0;
    end else begin
      slot_q        <= slot_d;
      slot_valid_q  <= slot_valid_d;
      reg_busy_q    <= reg_busy_d;
      issue_rr_ptr_q <= issue_rr_ptr_d;
    end
  end

endmodule
