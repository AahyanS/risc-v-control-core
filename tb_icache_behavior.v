// tb_icache_behavior.v
// White-box test proving icache.v actually caches - not just that
// architectural results stay correct (that's tb_cpu_pipeline_cache*.v),
// but that repeated fetches to the same line are served WITHOUT going
// back to flash. Uses sw/pipeline_predictor_test.s, whose loop body
// executes 7 times (see tb_cpu_pipeline_predictor.v) - once the loop's
// cache line(s) are filled on the first pass, every later pass should
// hit.
//
// Counts, by peeking directly at icache_inst's internal state every
// cycle IDLE accepts a request:
//   total_requests - every fetch the CPU asked the cache for
//   total_misses   - how many of those actually needed a flash fill
// A working cache must show total_requests > total_misses (some
// hits actually happened) and total_misses staying small relative to
// total_requests despite the loop executing 7 times.
//
// Run with:
//   iverilog -o sim_icache_behavior alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v cpu_pipeline_cache.v tb_icache_behavior.v
//   vvp sim_icache_behavior

`timescale 1ns/1ps

module tb_icache_behavior;

    reg clk;
    reg reset;
    integer i;
    integer total_requests;
    integer total_misses;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        total_requests = 0;
        total_misses   = 0;

        $readmemh("sw/pipeline_predictor_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 5000; i = i + 1) begin
            @(posedge clk);
            if (uut.icache_inst.state == 2'd0 && uut.icache_inst.req) begin
                total_requests = total_requests + 1;
                if (!uut.icache_inst.req_hit)
                    total_misses = total_misses + 1;
            end
            @(negedge clk);
        end

        $display("Total fetch requests to icache: %0d", total_requests);
        $display("Of which misses (had to fill from flash): %0d", total_misses);
        $display("Of which hits (served from cache): %0d", total_requests - total_misses);

        if (total_requests <= total_misses)
            $display("FAIL [CACHE_HITS_OCCUR]: no hits observed - every fetch missed");
        else
            $display("PASS [CACHE_HITS_OCCUR]: %0d hit(s) out of %0d requests",
                      total_requests - total_misses, total_requests);

        // The loop body is a handful of instructions repeated 7 times;
        // a working cache should need far fewer misses than total
        // fetches once warm. Generous bound: fewer than half the
        // fetches should ever miss.
        if (total_misses * 2 >= total_requests)
            $display("FAIL [MISS_RATE_REASONABLE]: %0d misses out of %0d requests - cache barely helping",
                      total_misses, total_requests);
        else
            $display("PASS [MISS_RATE_REASONABLE]: %0d misses out of %0d requests",
                      total_misses, total_requests);

        $display("Testbench complete.");
        $finish;
    end

endmodule
