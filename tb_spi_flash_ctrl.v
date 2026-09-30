// tb_spi_flash_ctrl.v
// Testbench for spi_flash_ctrl.v, verified against spi_flash_model.v
// (a genuine SPI slave, not a shortcut) - checks that real bit-serial
// protocol timing round-trips correctly, and that the controller can
// be reused for multiple back-to-back reads, and that abort ends a
// read cleanly at any point.
//
// Run with:
//   iverilog -o sim_spi_flash spi_flash_ctrl.v spi_flash_model.v tb_spi_flash_ctrl.v
//   vvp sim_spi_flash

`timescale 1ns/1ps

module tb_spi_flash_ctrl;

    reg clk;
    reg reset;
    reg  [23:0] addr;
    reg         req;
    reg         abort = 1'b0;
    wire        ready;
    wire [31:0] rdata;
    wire        busy;

    wire sck, cs_n, mosi, miso;

    spi_flash_ctrl ctrl (
        .clk(clk), .reset(reset),
        .addr(addr), .req(req), .abort(abort), .ready(ready), .rdata(rdata), .busy(busy),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model model (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    task do_read(input [23:0] a, input [31:0] exp_val, input [8*32-1:0] opname);
        begin
            @(negedge clk);
            addr = a;
            req  = 1'b1;
            @(negedge clk);
            req  = 1'b0;

            // Wait for ready, with a generous timeout
            begin : wait_ready
                integer wait_cycles;
                wait_cycles = 0;
                while (!ready && wait_cycles < 500) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                if (!ready)
                    $display("FAIL [%0s]: timed out waiting for ready", opname);
                else if (rdata !== exp_val)
                    $display("FAIL [%0s]: addr=%0d got=%08h expected=%08h",
                              opname, a, rdata, exp_val);
                else
                    $display("PASS [%0s]: addr=%0d rdata=%08h (took %0d cycles)",
                              opname, a, rdata, wait_cycles);
            end
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        req   = 1'b0;
        addr  = 24'd0;

        // Load the model with known, easily-distinguishable bytes at
        // a few different addresses.
        model.mem[0] = 8'h93; model.mem[1] = 8'h00; model.mem[2] = 8'h50; model.mem[3] = 8'h00; // 0x00500093
        model.mem[4] = 8'hAA; model.mem[5] = 8'hBB; model.mem[6] = 8'hCC; model.mem[7] = 8'hDD; // 0xDDCCBBAA
        model.mem[100] = 8'h11; model.mem[101] = 8'h22; model.mem[102] = 8'h33; model.mem[103] = 8'h44; // 0x44332211

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        do_read(24'd0,   32'h00500093, "READ_ADDR_0");
        do_read(24'd4,   32'hDDCCBBAA, "READ_ADDR_4");
        do_read(24'd100, 32'h44332211, "READ_ADDR_100_REUSE");

        // Re-read address 0 again, proving the controller isn't stuck
        // in some stale state from prior transactions
        do_read(24'd0,   32'h00500093, "READ_ADDR_0_AGAIN");

        // ---- abort mid-transaction ----
        // Start a read, abort it partway through the data phase (40
        // SCK edges in: past the 32-bit command+address), and check it
        // really stopped: chip-select up, no ready, controller idle.
        // Then a normal read must still return the right data - the
        // flash model, like a real flash, forgets the aborted command
        // when chip-select rises.
        @(negedge clk);
        addr = 24'd4; req = 1'b1;
        @(negedge clk);
        req = 1'b0;
        repeat (80) @(negedge clk);
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        if (cs_n !== 1'b1 || busy !== 1'b0)
            $display("FAIL [ABORT_STOPS_TRANSACTION]: cs_n=%b busy=%b", cs_n, busy);
        else
            $display("PASS [ABORT_STOPS_TRANSACTION]: chip-select high, idle, one cycle after abort");
        begin : no_ready_check
            integer k, saw_ready;
            saw_ready = 0;
            for (k = 0; k < 200; k = k + 1) begin
                if (ready) saw_ready = 1;
                @(negedge clk);
            end
            if (saw_ready)
                $display("FAIL [ABORT_GIVES_NO_READY]: an aborted read still produced ready");
            else
                $display("PASS [ABORT_GIVES_NO_READY]: no ready from the aborted read");
        end
        do_read(24'd100, 32'h44332211, "READ_AFTER_ABORT_CORRECT");

        // abort in the same cycle as req: the req is dropped
        @(negedge clk);
        addr = 24'd0; req = 1'b1; abort = 1'b1;
        @(negedge clk);
        req = 1'b0; abort = 1'b0;
        if (cs_n !== 1'b1 || busy !== 1'b0)
            $display("FAIL [ABORT_WINS_OVER_SAME_CYCLE_REQ]: cs_n=%b busy=%b", cs_n, busy);
        else
            $display("PASS [ABORT_WINS_OVER_SAME_CYCLE_REQ]: no transaction started");
        do_read(24'd4, 32'hDDCCBBAA, "READ_AFTER_DROPPED_REQ_CORRECT");

        $display("Testbench complete.");
        $finish;
    end

endmodule
