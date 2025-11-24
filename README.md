# CV32E40PX SIMT Prototype

This repository contains a modified version of the OpenHW Group CORE‑V CV32E40PX 32‑bit in‑order RISC‑V core.
Starting from the upstream CV32E40P/X baseline, this fork experiments with a very small SIMT (GPU‑style) execution
model built around multiple warps, custom warp control instructions, and a multi‑warp register file.

The original CV32E40P/PX documentation (ISA support, micro‑architecture, etc.) is available in the upstream project:
see the references at the end of this file.

## SIMT Extensions Implemented So Far

- **Warped fetch and PC tracking**
  - New core parameter `NUM_WARPS` (default 1) with derived `WID_WIDTH`.
  - Per‑warp program counters and state machines in `cv32e40px_core.sv`; warp 0 starts active, others start inactive.
  - A simple round‑robin warp scheduler (`cv32e40px_warp_scheduler.sv`) integrated into the IF stage
    (`cv32e40px_if_stage.sv`) to choose the next warp to fetch from.
  - Per‑warp stall feedback from the rest of the pipeline back into IF to avoid selecting blocked warps.

- **SIMT ISA hooks**
  - New SIMT opcodes in `cv32e40px_pkg.sv`:
    - `SIMT_OP_WSPAWN` – spawn/activate a set of warps at a given PC.
    - `SIMT_OP_EXIT` – mark the current warp as done.
  - These are encoded as `OPCODE_CUSTOM_0` instructions with dedicated `funct7` values and decoded in
    `cv32e40px_decoder.sv`.
  - The decode stage (`cv32e40px_id_stage.sv`) forwards SIMT metadata (`simt_valid`, `simt_op`, `simt_rs1_ex_o`,
    `simt_rs2_ex_o`, `wid_ex_o`) down to the execute stage.
  - The execute stage (`cv32e40px_ex_stage.sv`) converts these into SIMT commands
    (`simt_cmd_valid/op/wmask/pc`) that update per‑warp PC and state in the core top.

- **Multi‑warp register file**
  - The integer/FP register file has been generalized to hold `NUM_WARPS` independent banks:
    - Storage is declared as `mem[NUM_WARPS][NUM_REGS]` (and `mem_fp[NUM_WARPS][NUM_FP_WORDS]` when FPU is present).
    - Each read and write port now carries both a register address and a warp ID.
  - The ID stage (`cv32e40px_id_stage.sv`) passes the current `wid` into the RF and extends its hazard/forwarding
    logic so that dependencies are only tracked within a warp (no cross‑warp hazards).
  - The EX stage (`cv32e40px_ex_stage.sv`) propagates warp IDs through the EX/WB pipeline, including multicycle
    APU operations, so that late writes are still directed to the correct warp bank.

- **Hardware loops and other state**
  - Hardware loop registers (`cv32e40px_hwloop_regs.sv`) already support per‑warp state; this design keeps that
    structure and feeds them with the appropriate warp ID from the pipeline.

- **Issue‑stage and scoreboard prototype**
  - A standalone issue stage (`cv32e40px_is_stage.sv`) implements:
    - One decoded instruction buffer per warp.
    - A per‑warp register scoreboard to track pending writes.
    - Round‑robin arbitration across ready warps and per‑warp stall feedback.
  - This block is currently designed as a building block for a richer SIMT pipeline; full integration into the
    main pipeline is still work in progress.

## Example: SIMT Vector Addition with 4 Warps

To exercise the SIMT infrastructure, there is a simple vector addition micro‑kernel implemented as firmware:

- **Source:** `cv32e40px/example_tb/core/custom/simt_vector_add.c`
- **Behaviour:**
  - Initializes two integer vectors `A` and `B` (length 64) and a result vector `C`.
  - Uses inline `.insn` sequences to invoke the SIMT warp control instructions:
    - `simt_wspawn(mask, entry)` – spawns 4 warps onto `vector_add_kernel`.
    - `simt_exit()` – terminates the calling warp.
  - Each warp atomically claims a chunk of the input vector, computes `C[i] = A[i] + B[i]` for its slice, and
    signals completion.
  - Once all warps are done, one warp checks the full result and prints either:
    - `SIMT vector add succeeded using 4 warps`
    - or reports the number of mismatches found.

### Building and Running the Example

The SIMT example reuses the existing minimal testbench under `example_tb/core`, adapted from the upstream
CV32E40P environment. It is intended for bring‑up and experimentation only.

Prerequisites:
- RISC‑V GCC toolchain (e.g. `riscv32-unknown-elf-gcc`) and `RISCV` environment variable pointing to it.
- ModelSim/Questa (or compatible) matching the versions assumed in `example_tb/core/Makefile`.

Steps:

1. Build the RTL testbench (once) and the SIMT vector‑add firmware:
   - `cd cv32e40px/example_tb/core`
   - `make vector-add-vsim-run`

2. The `vector-add-vsim-run` target will:
   - Compile the RTL testbench and core according to `cv32e40px/example_tb/core/Makefile`.
   - Build `custom/simt_vector_add.elf` and convert it to `custom/simt_vector_add.hex`.
   - Run the simulation with the SIMT vector‑add firmware preloaded into the model memory.

3. For a GUI run, use:
   - `make vector-add-vsim-run-gui`

Note: the Makefile still references the upstream CV32E40P manifest. In this SIMT fork you should point
`CV_CORE_MANIFEST` (and any related file lists) at the CV32E40PX/SIMT RTL you want to test.

## Current Status and Limitations

- The SIMT machinery (multi‑warp PC/state, SIMT instructions, multi‑warp RF, basic test firmware) is functional
  in simulation, but this is still a prototype:
  - Default top‑level parameters instantiate a single warp; multi‑warp configurations require careful
    re‑parameterization and additional testing.
  - The example testbench is minimal and does not replace the upstream `core-v-verif` environment.
  - Toolchain support for the new SIMT instructions is via inline assembly only; there is no dedicated
    compiler backend or intrinsics library yet.
  - The `cv32e40px_is_stage` scoreboard/issue block is not yet fully wired into the main pipeline.

- As with the original CV32E40PX, this repository is not intended to be a silicon‑ready drop‑in. Treat the
  SIMT extensions as research/prototype code and validate thoroughly in your own environment.

## Documentation and Upstream Project

The base core is the OpenHW Group CORE‑V CV32E40P/X. For the unmodified core’s behaviour, micro‑architecture and
ISA support, consult:

- CV32E40P User Manual (HTML via ReadTheDocs):  
  https://docs.openhwgroup.org/projects/cv32e40p-user-manual/
- CV32E40P/CV32E40X RTL and documentation on GitHub:  
  https://github.com/openhwgroup/cv32e40p

Those documents do not cover the SIMT extensions described here, but they remain the reference for all
non‑SIMT aspects of the design.

## References

1. Gautschi, Michael, et al. “Near‑Threshold RISC‑V Core With DSP Extensions for Scalable IoT Endpoint Devices.”  
   IEEE Transactions on VLSI Systems, vol. 25, no. 10, pp. 2700–2713, Oct. 2017.

2. Schiavone, Pasquale Davide, et al. “Slow and steady wins the race? A comparison of ultra‑low‑power RISC‑V cores for Internet‑of‑Things applications.”  
   27th International Symposium on Power and Timing Modeling, Optimization and Simulation (PATMOS 2017). 

