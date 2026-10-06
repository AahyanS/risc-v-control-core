// tb_cosim.v
// Dumps a per-instruction execution trace from the real core, in the
// same line format cosim/iss.py produces, so the two can be directly
// diffed by cosim/compare_traces.py to catch any divergence.
//
// Same load approach as tb_compliance.v: the compiled program is
// loaded into both imem and dmem (this core's Harvard split means a
// load/store test needs its data mirrored into dmem - see
// docs/DESIGN_LOG.md). iss.py's load_hex does the identical mirroring, so
// both simulations start from the same state.
//
// Run with:
//   iverilog -o sim_cosim rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu.v tb/tb_cosim.v
//   vvp sim_cosim +HEXFILE=path/to.hex +CYCLES=N +TRACE=out.trace

`timescale 1ns/1ps

module tb_cosim;

    reg clk;
    reg reset;
    integer i;
    reg [8*256-1:0] hexfile;
    reg [8*256-1:0] tracefile;
    integer num_cycles;
    integer fd;

    // Captured before each clock edge, describing the instruction
    // about to retire - combinational control signals are only valid
    // for the current instruction until the edge moves the PC on.
    reg [31:0] cap_pc, cap_instr;
    reg        cap_reg_write;
    reg [4:0]  cap_rd;
    reg        cap_mem_write;
    reg [31:0] cap_mem_addr, cap_mem_data;

    cpu uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    function [31:0] peek_reg(input [4:0] reg_num);
        peek_reg = (reg_num == 5'd0) ? 32'd0 : uut.regfile_inst.regs[reg_num];
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        if (!$value$plusargs("HEXFILE=%s", hexfile)) begin
            $display("Usage: +HEXFILE=<path> +CYCLES=<n> +TRACE=<path>");
            $finish;
        end
        if (!$value$plusargs("CYCLES=%d", num_cycles))
            num_cycles = 200;
        if (!$value$plusargs("TRACE=%s", tracefile))
            tracefile = "cosim.trace";

        for (i = 0; i < 8192; i = i + 1)
            uut.dmem_inst.poke(i, 8'd0);

        $readmemh(hexfile, uut.imem_inst.mem);
        uut.dmem_inst.load_hex(hexfile);

        fd = $fopen(tracefile, "w");

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < num_cycles; i = i + 1) begin
            // Sample the currently-fetched instruction's control
            // signals right before the edge that retires it
            #1;
            cap_pc        = uut.pc_curr;
            cap_instr     = uut.instr;
            cap_reg_write = uut.reg_write;
            cap_rd        = uut.rd;
            cap_mem_write = uut.mem_write;
            cap_mem_addr  = uut.alu_result;
            cap_mem_data  = uut.rs2_data;

            @(posedge clk); @(negedge clk);

            if (cap_reg_write)
                $fwrite(fd, "PC=%08x INSTR=%08x REG=%0d:%08x MEM=-\n",
                        cap_pc, cap_instr, cap_rd, peek_reg(cap_rd));
            else if (cap_mem_write)
                $fwrite(fd, "PC=%08x INSTR=%08x REG=- MEM=%08x:%08x\n",
                        cap_pc, cap_instr, cap_mem_addr, cap_mem_data);
            else
                $fwrite(fd, "PC=%08x INSTR=%08x REG=- MEM=-\n",
                        cap_pc, cap_instr);
        end

        $fclose(fd);
        $display("Wrote %0d-cycle trace to %0s", num_cycles, tracefile);
        $finish;
    end

endmodule
