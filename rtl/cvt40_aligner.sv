// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Pasquale Davide Schiavone - pschiavo@iis.ee.ethz.ch        //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@greenwaves-technologies.com            //
//                                                                            //
// Design Name:    Instruction Aligner                                         //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cvt40_aligner #(
    parameter int unsigned NUM_WARPS = 1,
    parameter int unsigned WID_WIDTH = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS)
)  (
    input logic clk,
    input logic rst_n,

    input  logic fetch_valid_i,
    output logic aligner_ready_o,  //prevents overwriting the fethced instruction

    input logic if_valid_i,

    input logic [WID_WIDTH-1:0] warp_id_i,

    input logic [31:0] simt_cmd_pc_i,
    input cvt40_pkg::simt_opcode_e simt_cmd_op_i,
    input  logic [NUM_WARPS-1:0]         simt_cmd_mask_i,
    input  logic                         simt_cmd_valid_i,

    input  logic [31:0] fetch_rdata_i,
    output logic [31:0] instr_aligned_o,
    output logic        instr_valid_o,

    input logic [31:0] branch_addr_i,
    input logic        branch_i,  // Asserted if we are branching/jumping now

    input logic [31:0] hwlp_addr_i,
    input logic        hwlp_update_pc_i,

    output logic [31:0] pc_o
);

  import cvt40_pkg::*;

  typedef enum logic [2:0] {
    ALIGNED32,
    MISALIGNED32,
    MISALIGNED16,
    BRANCH_MISALIGNED,
    WAIT_VALID_BRANCH
  } aligner_state_t;

  // Per-warp context.
  aligner_state_t  state_cur   [NUM_WARPS];
  aligner_state_t  state_next  [NUM_WARPS];
  logic [15:0]     r_instr_h[NUM_WARPS]; // Hold the upper half of a 32bit instruction when misaligned
  logic [31:0]     hwlp_addr[NUM_WARPS];
  logic [NUM_WARPS-1:0] aligner_ready;
  logic [NUM_WARPS-1:0] hwlp_update_pc;
  logic [31:0]     pc_q     [NUM_WARPS];

  // Working (selected warp) context.
  logic [15:0] r_instr_h_cur;
  logic [31:0] hwlp_addr_cur;
  logic        aligner_ready_cur;
  logic        hwlp_update_pc_cur;

  logic update_state;
  logic [31:0] pc_plus4, pc_plus2;
  logic [31:0] pc_n;

  assign pc_o    = pc_q[warp_id_i];
  assign pc_plus2 = pc_q[warp_id_i] + 2;
  assign pc_plus4 = pc_q[warp_id_i] + 4;
  assign r_instr_h_cur = r_instr_h[warp_id_i];
  assign hwlp_addr_cur = hwlp_addr[warp_id_i];
  assign aligner_ready_cur = aligner_ready[warp_id_i];
  assign hwlp_update_pc_cur = hwlp_update_pc[warp_id_i];

  always_ff @(posedge clk or negedge rst_n) begin : proc_SEQ_FSM
    if (~rst_n) begin
      for (int unsigned w = 0; w < NUM_WARPS; w++) begin
        state_cur[w]       <= ALIGNED32;
        r_instr_h[w]       <= '0;
        hwlp_addr[w]       <= '0;
        aligner_ready[w]   <= 1'b0;
        hwlp_update_pc[w]  <= 1'b0;
        pc_q[w]            <= '0;
      end
    end else begin
      if (update_state) begin
        if (simt_cmd_op_i == SIMT_OP_WSPAWN && simt_cmd_valid_i) begin
          // On warp spawn, rebase PC and reset aligner state.
          for (int unsigned w = 0; w < NUM_WARPS; w++) begin
            if (simt_cmd_mask_i[w]) begin
              state_cur[w]         <= ALIGNED32;
              pc_q[w]              <= simt_cmd_pc_i;
              r_instr_h[w]       <= '0;
              aligner_ready[w]   <= 1'b0;
              hwlp_update_pc[w]  <= 1'b0;
              hwlp_addr[w]       <= '0;
            end
          end
        end else begin
          state_cur[warp_id_i] <= state_next[warp_id_i];
          pc_q[warp_id_i]  <= pc_n;
          r_instr_h[warp_id_i] <= fetch_rdata_i[31:16];
          aligner_ready[warp_id_i] <= aligner_ready_o;
          hwlp_update_pc[warp_id_i] <= 1'b0;
        end
      end else begin
        if (hwlp_update_pc_i) begin
          hwlp_addr[warp_id_i]      <= hwlp_addr_i;  // Save the JUMP target address to keep pc_n up to date during the stall
          hwlp_update_pc[warp_id_i] <= 1'b1;
        end

      end
    end
  end

  always_comb begin

    //default outputs
    pc_n            = pc_q[warp_id_i];
    instr_valid_o   = fetch_valid_i;
    instr_aligned_o = fetch_rdata_i;
    aligner_ready_o = 1'b1;
    update_state    = 1'b0;

    state_next[warp_id_i] = state_cur[warp_id_i];

    case (state_cur[warp_id_i])
      ALIGNED32: begin
        if (fetch_rdata_i[1:0] == 2'b11) begin
          /*
                  Before we fetched a 32bit aligned instruction
                  Therefore, now the address is aligned too and it is 32bits
                */
          state_next[warp_id_i]      = ALIGNED32;
          pc_n            = pc_plus4;
          instr_aligned_o = fetch_rdata_i;
          //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
          update_state    = fetch_valid_i & if_valid_i;
          if (hwlp_update_pc_i || hwlp_update_pc_cur)
            pc_n = hwlp_update_pc_i ? hwlp_addr_i : hwlp_addr_cur;
        end else begin
          /*
                  Before we fetched a 32bit aligned instruction
                  Therefore, now the address is aligned too and it is 16bits
                */
          state_next[warp_id_i]      = MISALIGNED32;
          pc_n            = pc_plus2;
          instr_aligned_o = fetch_rdata_i;  //only the first 16b are used
          //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
          update_state    = fetch_valid_i & if_valid_i;
        end
      end


      MISALIGNED32: begin
        if (r_instr_h_cur[1:0] == 2'b11) begin
          /*
                  Before we fetched a 32bit misaligned instruction
                  So now the beginning of the next instruction is the stored one
                  The istruction is 32bits so it is misaligned again
                */
          state_next[warp_id_i]      = MISALIGNED32;
          pc_n            = pc_plus4;
          instr_aligned_o = {fetch_rdata_i[15:0], r_instr_h_cur[15:0]};
          //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
          update_state    = fetch_valid_i & if_valid_i;
        end else begin
          /*
                  Before we fetched a 32bit misaligned instruction
                  So now the beginning of the next instruction is the stored one
                  The istruction is 16bits misaligned
                */
          instr_aligned_o = {fetch_rdata_i[31:16], r_instr_h_cur[15:0]};  //only the first 16b are used
          state_next[warp_id_i]      = MISALIGNED16;
          instr_valid_o   = 1'b1;
          pc_n            = pc_plus2;
          //we cannot overwrite the 32bit instruction just fetched
          //so tell the IF stage to stall, the coming instruction goes to the FIFO
          aligner_ready_o = !fetch_valid_i;
          //not need to gate id_valid with fetch_valid as the next state depends only on r_instr_h
          update_state    = if_valid_i;
        end
      end


      MISALIGNED16: begin
        //this is 1 as we holded the value before with raw_instr_hold_o
        instr_valid_o = !aligner_ready_cur || fetch_valid_i;
        if (fetch_rdata_i[1:0] == 2'b11) begin
          /*
                  Before we fetched a 16bit misaligned instruction
                  So now the beginning of the next instruction is the new one
                  The istruction is 32bits so it is aligned
                */
          state_next[warp_id_i]      = ALIGNED32;
          pc_n            = pc_plus4;
          instr_aligned_o = fetch_rdata_i;
          //no gate id_valid with fetch_valid as the next state sdepends only on mem content that has be held the previous cycle with raw_instr_hold_o
          update_state    = (!aligner_ready_cur | fetch_valid_i) & if_valid_i;
        end else begin
          /*
                  Before we fetched a 16bit misaligned  instruction
                  So now the beginning of the next instruction is the new one
                  The istruction is 16bit aligned
                */
          state_next[warp_id_i] = MISALIGNED32;
          pc_n = pc_plus2;
          instr_aligned_o = fetch_rdata_i;  //only the first 16b are used
          //no gate id_valid with fetch_valid as the next state sdepends only on mem content that has be held the previous cycle with raw_instr_hold_o
          update_state = (!aligner_ready_cur | fetch_valid_i) & if_valid_i;
        end
      end


      BRANCH_MISALIGNED: begin
        //we jumped to a misaligned location, so now we received {TARGET, XXXX}
        if (fetch_rdata_i[17:16] == 2'b11) begin
          /*
                  We jumped to a misaligned location that contains 32bits instruction
                */
          state_next[warp_id_i]      = MISALIGNED32;
          instr_valid_o   = 1'b0;
          pc_n            = pc_q[warp_id_i];
          instr_aligned_o = fetch_rdata_i;
          //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
          update_state    = fetch_valid_i & if_valid_i;
        end else begin
          /*
                  We jumped to a misaligned location that contains 16bits instruction, as we consumed the whole word, we can preted to start again from ALIGNED32
                */
          state_next[warp_id_i] = ALIGNED32;
          pc_n = pc_plus2;
          instr_aligned_o = {
            fetch_rdata_i[31:16], fetch_rdata_i[31:16]
          };  //only the first 16b are used
          //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
          update_state = fetch_valid_i & if_valid_i;
        end
      end

    endcase  // state


    // JUMP, BRANCH, SPECIAL JUMP control
    if (branch_i) begin
      update_state = 1'b1;
      pc_n         = branch_addr_i;
      state_next[warp_id_i]   = branch_addr_i[1] ? BRANCH_MISALIGNED : ALIGNED32;
    end

  end

  /*
  When a branch is taken in EX, if_valid_i is asserted because the BRANCH is resolved also in
  case of stalls. This is because the branch information is stored in the IF stage (in the prefetcher)
  when branch_i is asserted. We introduced here an apparently unuseful  special case for
  the JUMPS for a cleaner and more robust HW: theoretically, we don't need to save the instruction
  after a taken branch in EX, thus we will not do it.
*/

  //////////////////////////////////////////////////////////////////////////////
  // Assertions
  //////////////////////////////////////////////////////////////////////////////

`ifdef CV32E40P_ASSERT_ON

  // Hardware Loop check
  property p_hwlp_update_pc;
    @(posedge clk) disable iff (!rst_n) (1'b1) |-> (!(hwlp_update_pc_i && hwlp_update_pc[warp_id_i]));
  endproperty

  a_hwlp_update_pc :
  assert property (p_hwlp_update_pc);

`endif

endmodule
