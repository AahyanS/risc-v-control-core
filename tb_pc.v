// tb_pc.v
// Testbench for pc.v
//
// Run with:
//   iverilog -o sim_pc pc.v tb_pc.v
//   vvp sim_pc
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_pc;

    reg         clk;
    reg         reset;
    reg  [31:0] pc_next;
    wire [31:0] pc;

    pc uut (
        .clk(clk),
        .reset(reset),
        .pc_next(pc_next),
        .pc(pc)
    );

    // 10ns period clock
    always #5 clk = ~clk;

    task check(input [31:0] exp_pc, input [63:0] opname);
        begin
            #1; // let the registered output settle after the edge
            if (pc !== exp_pc)
                $display("FAIL [%0s]: got pc=%0d expected=%0d",
                          opname, pc, exp_pc);
            else
                $display("PASS [%0s]: pc=%0d", opname, pc);
        end
    endtask

    initial begin
        clk     = 1'b0;
        reset   = 1'b1;
        pc_next = 32'd0;

        // Hold reset through one clock edge: pc must come up at 0,
        // regardless of whatever pc_next happens to be
        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        check(32'd0, "RESET");

        // Deassert reset and step pc forward by 4, like a real fetch
        // stage would (pc_next = pc + 4 computed outside this module)
        reset   = 1'b0;
        pc_next = pc + 32'd4;
        @(posedge clk);
        @(negedge clk);
        check(32'd4, "STEP_1");

        // Step again
        pc_next = pc + 32'd4;
        @(posedge clk);
        @(negedge clk);
        check(32'd8, "STEP_2");

        // A few more steps in a row, to confirm it keeps counting
        pc_next = pc + 32'd4;
        @(posedge clk);
        @(negedge clk);
        check(32'd12, "STEP_3");

        pc_next = pc + 32'd4;
        @(posedge clk);
        @(negedge clk);
        check(32'd16, "STEP_4");

        // Jump: pc_next can be driven to an arbitrary address (this is
        // how a future branch/jump target would be applied)
        pc_next = 32'h00001000;
        @(posedge clk);
        @(negedge clk);
        check(32'h00001000, "JUMP");

        // Reset mid-stream must force pc back to 0 even after a jump,
        // and even while pc_next is pointed elsewhere
        reset   = 1'b1;
        pc_next = 32'hDEADBEEF;
        @(posedge clk);
        @(negedge clk);
        check(32'd0, "RESET_MID_STREAM");

        $display("Testbench complete.");
        $finish;
    end

endmodule
