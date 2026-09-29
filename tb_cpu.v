// tb_cpu.v
// Testbench for cpu.v
//
// Run with:
//   iverilog -o sim_cpu alu.v regfile.v control.v pc.v imem.v cpu.v tb_cpu.v
//   vvp sim_cpu
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_cpu;

    reg clk;
    reg reset;

    cpu uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    // Reads a register directly out of the regfile submodule via
    // hierarchical reference - the same trick used to load imem.
    // x0's raw storage (regs[0]) is never written by regfile.v at all
    // (only its read port is hardwired to return 0), so peeking at
    // regs[0] directly would see stale/unknown data; mirror the same
    // "address 0 reads as 0" rule the real read ports apply.
    function [31:0] peek_reg(input [4:0] reg_num);
        peek_reg = (reg_num == 5'd0) ? 32'd0 : uut.regfile_inst.regs[reg_num];
    endfunction

    task check_reg(input [4:0] reg_num, input [31:0] exp_val,
                    input [63:0] opname);
        begin
            #1;
            if (peek_reg(reg_num) !== exp_val)
                $display("FAIL [%0s]: x%0d got=%0h expected=%0h",
                          opname, reg_num, peek_reg(reg_num), exp_val);
            else
                $display("PASS [%0s]: x%0d = %0h",
                          opname, reg_num, peek_reg(reg_num));
        end
    endtask

    // imem.v is byte-addressable now (matching what a real objcopy hex
    // dump loads via $readmemh), so a 32-bit instruction word has to be
    // split into 4 little-endian byte writes instead of one word write.
    task load_instr(input [31:0] byte_addr, input [31:0] word);
        begin
            uut.imem_inst.mem[byte_addr]   = word[7:0];
            uut.imem_inst.mem[byte_addr+1] = word[15:8];
            uut.imem_inst.mem[byte_addr+2] = word[23:16];
            uut.imem_inst.mem[byte_addr+3] = word[31:24];
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        // Hand-assembled test program, loaded directly into instruction
        // memory (no RISC-V toolchain yet). Encodings verified by hand
        // against the RV32I field layout:
        //   addi x1, x0, 5    -> x1 = 5
        //   addi x2, x0, 10   -> x2 = 10
        //   add  x3, x1, x2   -> x3 = 15
        //   sub  x4, x2, x1   -> x4 = 5
        //   and  x5, x1, x2   -> x5 = 0
        //   or   x6, x1, x2   -> x6 = 15
        //   addi x7, x0, -1   -> x7 = 0xFFFFFFFF
        load_instr(32'd0,  32'h00500093);
        load_instr(32'd4,  32'h00A00113);
        load_instr(32'd8,  32'h002081B3);
        load_instr(32'd12, 32'h40110233);
        load_instr(32'd16, 32'h0020F2B3);
        load_instr(32'd20, 32'h0020E333);
        load_instr(32'd24, 32'hFFF00393);

        // Load/store extension to the same program:
        //   addi x1, x0, 100  -> x1 = 100 (base address)
        //   addi x2, x0, 42   -> x2 = 42  (value to store)
        //   sw   x2, 0(x1)    -> mem[100] = 42
        //   lw   x3, 0(x1)    -> x3 = 42  (read back)
        //   addi x4, x0, -5   -> x4 = 0xFFFFFFFB
        //   sb   x4, 4(x1)    -> mem[104] = 0xFB (low byte of x4)
        //   lb   x5, 4(x1)    -> x5 = 0xFFFFFFFB (sign-extended)
        //   lbu  x6, 4(x1)    -> x6 = 0x000000FB (zero-extended)
        load_instr(32'd28, 32'h06400093);
        load_instr(32'd32, 32'h02A00113);
        load_instr(32'd36, 32'h0020A023);
        load_instr(32'd40, 32'h0000A183);
        load_instr(32'd44, 32'hFFB00213);
        load_instr(32'd48, 32'h00408223);
        load_instr(32'd52, 32'h00408283);
        load_instr(32'd56, 32'h0040C303);

        // Branch/jump extension: a real loop, plus a function call/
        // return. PC-relative immediates are relative offsets, so this
        // whole block can be appended here unchanged - the encoded
        // branch/jump targets shift along with wherever the block
        // itself lands (byte address 60 onward), no recomputation
        // needed.
        //   addi x1, x0, 0     -> x1 = 0            (sum)
        //   addi x2, x0, 1     -> x2 = 1            (i)
        //   addi x3, x0, 6     -> x3 = 6            (limit)
        // loop:
        //   add  x1, x1, x2    -> sum += i
        //   addi x2, x2, 1     -> i++
        //   blt  x2, x3, loop  -> repeat while i < 6
        //   addi x5, x0, 100   -> x5 = 100 (proves control resumed after the loop)
        //   jal  x6, func      -> x6 = return address; jump to func
        // (return point, right after the jal:)
        //   addi x9, x0, 999   -> x9 = 999 (proves jalr returned here)
        //   jal  x0, skip      -> unconditional "goto" (rd=x0: no link
        //                         saved), jumps past func so execution
        //                         never falls back into it a second time
        // func:
        //   addi x7, x0, 77    -> x7 = 77
        //   jalr x0, x6, 0     -> return to whatever x6 holds
        // skip:
        //   lui   x10, 0x12345 -> x10 = 0x12345000
        //   auipc x11, 0x1     -> x11 = pc_of_this_instr + 0x1000
        //
        // Expected: x1=15 (1+2+3+4+5), x2=6, x3=6, x5=100, x7=77, x9=999,
        // x10=0x12345000, x11=pc+0x1000
        load_instr(32'd60,  32'h00000093);
        load_instr(32'd64,  32'h00100113);
        load_instr(32'd68,  32'h00600193);
        load_instr(32'd72,  32'h002080B3);
        load_instr(32'd76,  32'h00110113);
        load_instr(32'd80,  32'hFE314CE3);
        load_instr(32'd84,  32'h06400293);
        load_instr(32'd88,  32'h00C0036F);
        load_instr(32'd92,  32'h3E700493);
        load_instr(32'd96,  32'h00C0006F);
        load_instr(32'd100, 32'h04D00393);
        load_instr(32'd104, 32'h00030067);
        load_instr(32'd108, 32'h12345537);
        load_instr(32'd112, 32'h00001597);

        // Hold reset through one clock edge to establish pc = 0, then
        // release it at a safe (falling-edge) point
        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Single-cycle core: each subsequent clock edge retires exactly
        // one instruction, in program order
        @(posedge clk); @(negedge clk);
        check_reg(5'd1, 32'd5, "ADDI_X1");

        @(posedge clk); @(negedge clk);
        check_reg(5'd2, 32'd10, "ADDI_X2");

        @(posedge clk); @(negedge clk);
        check_reg(5'd3, 32'd15, "ADD_X3");

        @(posedge clk); @(negedge clk);
        check_reg(5'd4, 32'd5, "SUB_X4");

        @(posedge clk); @(negedge clk);
        check_reg(5'd5, 32'd0, "AND_X5");

        @(posedge clk); @(negedge clk);
        check_reg(5'd6, 32'd15, "OR_X6");

        @(posedge clk); @(negedge clk);
        check_reg(5'd7, 32'hFFFFFFFF, "ADDI_X7_NEG1");

        @(posedge clk); @(negedge clk);
        check_reg(5'd1, 32'd100, "ADDI_X1_BASE");

        @(posedge clk); @(negedge clk);
        check_reg(5'd2, 32'd42, "ADDI_X2_VAL");

        @(posedge clk); @(negedge clk);
        // SW doesn't write a register - check the memory word directly
        #1;
        if (uut.dmem_inst.peek(100) !== 8'd42 || uut.dmem_inst.peek(101) !== 8'd0 ||
            uut.dmem_inst.peek(102) !== 8'd0  || uut.dmem_inst.peek(103) !== 8'd0)
            $display("FAIL [SW_STORED_WORD]: mem[100..103] got=%0h %0h %0h %0h",
                      uut.dmem_inst.peek(100), uut.dmem_inst.peek(101),
                      uut.dmem_inst.peek(102), uut.dmem_inst.peek(103));
        else
            $display("PASS [SW_STORED_WORD]: mem[100..103] = 42,0,0,0");

        @(posedge clk); @(negedge clk);
        check_reg(5'd3, 32'd42, "LW_READBACK");

        @(posedge clk); @(negedge clk);
        check_reg(5'd4, 32'hFFFFFFFB, "ADDI_X4_NEG5");

        @(posedge clk); @(negedge clk);
        #1;
        if (uut.dmem_inst.peek(104) !== 8'hFB)
            $display("FAIL [SB_STORED_BYTE]: mem[104] got=%0h expected=fb",
                      uut.dmem_inst.peek(104));
        else
            $display("PASS [SB_STORED_BYTE]: mem[104] = fb");

        @(posedge clk); @(negedge clk);
        check_reg(5'd5, 32'hFFFFFFFB, "LB_SIGN_EXTEND");

        @(posedge clk); @(negedge clk);
        check_reg(5'd6, 32'h000000FB, "LBU_ZERO_EXTEND");

        // pc should now sit past all 15 load/store-program instructions
        #1;
        if (uut.pc_curr !== 32'd60)
            $display("FAIL [PC_AFTER_LOADSTORE]: got=%0d expected=60", uut.pc_curr);
        else
            $display("PASS [PC_AFTER_LOADSTORE]: pc=%0d", uut.pc_curr);

        // ---- Loop: 3 setup instructions ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd1, 32'd0, "LOOP_INIT_SUM");

        @(posedge clk); @(negedge clk);
        check_reg(5'd2, 32'd1, "LOOP_INIT_I");

        @(posedge clk); @(negedge clk);
        check_reg(5'd3, 32'd6, "LOOP_INIT_LIMIT");

        // ---- 5 loop iterations: add, addi, blt each time. Checking
        // sum and i right after each blt confirms both the loop body's
        // arithmetic and the branch decision (taken 4 times, then not
        // taken on the 5th, when i finally reaches the limit). ----
        @(posedge clk); @(negedge clk); // add
        @(posedge clk); @(negedge clk); // addi
        @(posedge clk); @(negedge clk); // blt (taken: 2 < 6)
        check_reg(5'd1, 32'd1, "LOOP_ITER1_SUM");
        check_reg(5'd2, 32'd2, "LOOP_ITER1_I");

        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); // blt (taken: 3 < 6)
        check_reg(5'd1, 32'd3, "LOOP_ITER2_SUM");
        check_reg(5'd2, 32'd3, "LOOP_ITER2_I");

        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); // blt (taken: 4 < 6)
        check_reg(5'd1, 32'd6, "LOOP_ITER3_SUM");
        check_reg(5'd2, 32'd4, "LOOP_ITER3_I");

        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); // blt (taken: 5 < 6)
        check_reg(5'd1, 32'd10, "LOOP_ITER4_SUM");
        check_reg(5'd2, 32'd5, "LOOP_ITER4_I");

        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); // blt (NOT taken: 6 < 6 is false)
        check_reg(5'd1, 32'd15, "LOOP_ITER5_SUM_FINAL");
        check_reg(5'd2, 32'd6, "LOOP_ITER5_I_FINAL");

        // ---- After the loop: proves control fell through the loop
        // correctly instead of continuing to branch ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd5, 32'd100, "AFTER_LOOP");

        // ---- JAL: jumps to func, saves the return address in x6 ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd6, 32'd92, "JAL_LINK_ADDR");

        // ---- func body ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd7, 32'd77, "FUNC_BODY");

        // ---- JALR: returns to whatever x6 holds. rd=x0 here, so this
        // also re-confirms x0's hardwired-zero guarantee holds even
        // when a real instruction (not just a testbench poke) tries to
        // write it. ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd0, 32'd0, "JALR_RD_X0_IGNORED");
        #1;
        if (uut.pc_curr !== 32'd92)
            $display("FAIL [JALR_RETURN_TARGET]: got=%0d expected=92", uut.pc_curr);
        else
            $display("PASS [JALR_RETURN_TARGET]: pc=%0d", uut.pc_curr);

        // ---- Return point: proves execution resumed exactly where
        // the jal left off, not somewhere else ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd9, 32'd999, "RETURN_POINT");

        // ---- Unconditional skip jump (jal x0, skip): rd=x0 so nothing
        // is written; this only proves the jump itself was taken,
        // landing past func rather than falling through into it again ----
        @(posedge clk); @(negedge clk);
        #1;
        if (uut.pc_curr !== 32'd108)
            $display("FAIL [SKIP_JUMP_TARGET]: got=%0d expected=108", uut.pc_curr);
        else
            $display("PASS [SKIP_JUMP_TARGET]: pc=%0d", uut.pc_curr);

        // ---- LUI: rd gets the raw upper-immediate value, no ALU/pc
        // involved at all ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd10, 32'h12345000, "LUI");

        // ---- AUIPC: rd = pc-of-this-instruction + imm_u. The AUIPC
        // instruction itself sits at byte 112, so 112 + 0x1000 = 4208 ----
        @(posedge clk); @(negedge clk);
        check_reg(5'd11, 32'd4208, "AUIPC");

        #1;
        if (uut.pc_curr !== 32'd116)
            $display("FAIL [PC_FINAL]: got=%0d expected=116", uut.pc_curr);
        else
            $display("PASS [PC_FINAL]: pc=%0d", uut.pc_curr);

        $display("Testbench complete.");
        $finish;
    end

endmodule
