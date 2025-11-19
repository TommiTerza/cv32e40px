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
// Engineer:       Francesco Conti - f.conti@unibo.it                         //
//                                                                            //
// Additional contributions by:                                               //
//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                                                                            //
// Design Name:    RISC-V register file                                       //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Register file with 31x 32 bit wide registers. Register 0   //
//                 is fixed to 0. This register file is based on flip-flops.  //
//                 Also supports the fp-register file now if FPU=1            //
//                 If ZFINX is 1, floating point operations take values       //
//                 from the X register file                                   //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40px_register_file #(
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 32,
    parameter FPU        = 0,
    parameter ZFINX      = 0,
    parameter COREV_X_IF = 0,
    parameter X_DUALREAD = 0,
    parameter int unsigned NUM_WARPS = 1,
    parameter int unsigned WID_WIDTH = (NUM_WARPS <= 1) ? 1 : $clog2(NUM_WARPS)
) (
    // Clock and Reset
    input logic clk,
    input logic rst_n,

    input logic scan_cg_en_i,

    input logic [2:0] dualread_i,

    //Read port R1
    input logic [ADDR_WIDTH-1:0] raddr_a_i,
    input logic [WID_WIDTH-1:0]  raddr_a_wid_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_a_o,

    //Read port R2
    input logic [ADDR_WIDTH-1:0] raddr_b_i,
    input logic [WID_WIDTH-1:0]  raddr_b_wid_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_b_o,

    //Read port R3
    input logic [ADDR_WIDTH-1:0] raddr_c_i,
    input logic [WID_WIDTH-1:0]  raddr_c_wid_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_c_o,

    // Write port W1
    input logic [ADDR_WIDTH-1:0] waddr_a_i,
    input logic [WID_WIDTH-1:0]  waddr_a_wid_i,
    input logic [DATA_WIDTH-1:0] wdata_a_i,
    input logic                  we_a_i,

    // Write port W2
    input logic [ADDR_WIDTH-1:0] waddr_b_i,
    input logic [WID_WIDTH-1:0]  waddr_b_wid_i,
    input logic [DATA_WIDTH-1:0] wdata_b_i,
    input logic                  we_b_i
);

  // number of integer registers
  localparam NUM_WORDS = 2 ** (ADDR_WIDTH - 1);
  // number of floating point registers
  localparam NUM_FP_WORDS = 2 ** (ADDR_WIDTH - 1);

  typedef logic [DATA_WIDTH-1:0] reg_data_t;

  reg_data_t mem   [NUM_WARPS-1:0][NUM_WORDS-1:0];
  reg_data_t mem_fp[NUM_WARPS-1:0][NUM_FP_WORDS-1:0];

  function automatic reg_data_t read_data (
      input logic [WID_WIDTH-1:0] wid,
      input logic [ADDR_WIDTH-1:0] addr
  );
    reg_data_t ret;
    begin
      if ((FPU == 1) && (ZFINX == 0) && addr[5]) begin
        ret = mem_fp[wid][addr[4:0]];
      end else begin
        ret = mem[wid][addr[4:0]];
      end
      return ret;
    end
  endfunction

  function automatic logic [ADDR_WIDTH-1:0] dualread_addr (
      input logic [ADDR_WIDTH-1:0] addr
  );
    logic [ADDR_WIDTH-1:0] dual_addr;
    begin
      dual_addr = addr;
      dual_addr[4:1] = addr[4:1];
      dual_addr[0]   = addr[0] | 1'b1;
      return dual_addr;
    end
  endfunction

  //-----------------------------------------------------------------------------
  //-- READ : Read address decoder RAD
  //-----------------------------------------------------------------------------
  generate
    if (COREV_X_IF != 0) begin : gen_corev_x_if
      if (X_DUALREAD) begin : gen_corev_x_if_dualread
        always_comb begin
          rdata_a_o[0] = read_data(raddr_a_wid_i, raddr_a_i);
          rdata_b_o[0] = read_data(raddr_b_wid_i, raddr_b_i);
          rdata_c_o[0] = read_data(raddr_c_wid_i, raddr_c_i);
          if (dualread_i[0]) begin
            rdata_a_o[1] = read_data(raddr_a_wid_i, dualread_addr(raddr_a_i));
          end else begin
            rdata_a_o[1] = '0;
          end
          if (dualread_i[1]) begin
            rdata_b_o[1] = read_data(raddr_b_wid_i, dualread_addr(raddr_b_i));
          end else begin
            rdata_b_o[1] = '0;
          end
          if (dualread_i[2]) begin
            rdata_c_o[1] = read_data(raddr_c_wid_i, dualread_addr(raddr_c_i));
          end else begin
            rdata_c_o[1] = '0;
          end
        end
      end else begin : gen_corev_x_if_no_dualread
        assign rdata_a_o[0] = read_data(raddr_a_wid_i, raddr_a_i);
        assign rdata_b_o[0] = read_data(raddr_b_wid_i, raddr_b_i);
        assign rdata_c_o[0] = read_data(raddr_c_wid_i, raddr_c_i);
      end
    end else begin : gen_no_corev_x_if
      if (X_DUALREAD) begin : gen_no_corev_x_if_dualread
        always_comb begin
          rdata_a_o[0] = read_data(raddr_a_wid_i, raddr_a_i);
          rdata_b_o[0] = read_data(raddr_b_wid_i, raddr_b_i);
          rdata_c_o[0] = read_data(raddr_c_wid_i, raddr_c_i);
          rdata_a_o[1] = read_data(raddr_a_wid_i, dualread_addr(raddr_a_i));
          rdata_b_o[1] = read_data(raddr_b_wid_i, dualread_addr(raddr_b_i));
          rdata_c_o[1] = read_data(raddr_c_wid_i, dualread_addr(raddr_c_i));
        end
      end else begin : gen_no_corev_x_if_no_dualread
        assign rdata_a_o[0] = read_data(raddr_a_wid_i, raddr_a_i);
        assign rdata_b_o[0] = read_data(raddr_b_wid_i, raddr_b_i);
        assign rdata_c_o[0] = read_data(raddr_c_wid_i, raddr_c_i);
      end
    end
  endgenerate

  //-----------------------------------------------------------------------------
  //-- WRITE : Write operation
  //-----------------------------------------------------------------------------
  genvar warp_idx, reg_idx;
  generate
    for (warp_idx = 0; warp_idx < NUM_WARPS; warp_idx++) begin : gen_warps
      // R0 per warp is always zero
      always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
          mem[warp_idx][0] <= '0;
        end else begin
          mem[warp_idx][0] <= '0;
        end
      end

      for (reg_idx = 1; reg_idx < NUM_WORDS; reg_idx++) begin : gen_rf
        always_ff @(posedge clk or negedge rst_n) begin
          if (~rst_n) begin
            mem[warp_idx][reg_idx] <= '0;
          end else begin
            if (we_b_i && (waddr_b_wid_i == WID_WIDTH'(warp_idx)) && (waddr_b_i[5] == 1'b0) &&
                (waddr_b_i[4:0] == 5'(reg_idx))) begin
              mem[warp_idx][reg_idx] <= wdata_b_i;
            end else if (we_a_i && (waddr_a_wid_i == WID_WIDTH'(warp_idx)) && (waddr_a_i[5] == 1'b0) &&
                         (waddr_a_i[4:0] == 5'(reg_idx))) begin
              mem[warp_idx][reg_idx] <= wdata_a_i;
            end
          end
        end
      end
    end

    if (FPU == 1 && ZFINX == 0) begin : gen_mem_fp_write
      genvar fp_warp, fp_idx;
      for (fp_warp = 0; fp_warp < NUM_WARPS; fp_warp++) begin : gen_fp_warp
        for (fp_idx = 0; fp_idx < NUM_FP_WORDS; fp_idx++) begin : fp_regs
          always_ff @(posedge clk or negedge rst_n) begin
            if (~rst_n) begin
              mem_fp[fp_warp][fp_idx] <= '0;
            end else begin
              if (we_b_i && (waddr_b_wid_i == WID_WIDTH'(fp_warp)) && (waddr_b_i[5] == 1'b1) &&
                  (waddr_b_i[4:0] == 5'(fp_idx))) begin
                mem_fp[fp_warp][fp_idx] <= wdata_b_i;
              end else if (we_a_i && (waddr_a_wid_i == WID_WIDTH'(fp_warp)) && (waddr_a_i[5] == 1'b1) &&
                           (waddr_a_i[4:0] == 5'(fp_idx))) begin
                mem_fp[fp_warp][fp_idx] <= wdata_a_i;
              end
            end
          end
        end
      end
    end else begin : gen_no_mem_fp_write
      genvar fp_warp_zero, fp_idx_zero;
      for (fp_warp_zero = 0; fp_warp_zero < NUM_WARPS; fp_warp_zero++) begin : gen_fp_zero
        for (fp_idx_zero = 0; fp_idx_zero < NUM_FP_WORDS; fp_idx_zero++) begin : gen_fp_zero_idx
          assign mem_fp[fp_warp_zero][fp_idx_zero] = '0;
        end
      end
    end
  endgenerate

endmodule
