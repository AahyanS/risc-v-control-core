// cpu_pipeline_xip.v
// 5-stage pipelined RV32I core, executing in place (XIP) from external
// QSPI flash instead of BRAM. This is Configuration 1 of the project's
// core experiment: XIP from flash, no cache - the slow baseline the
// cache (built next) gets measured against.
//
// Identical to cpu_pipeline.v from ID onward - only IF changes, and
// only because a flash read now takes ~128 clock cycles instead of 1.
// cpu_pipeline.v is kept unchanged as a working, fully-tested BRAM
// reference (and the target for the compliance suite going forward,
// since flash fetch timing is orthogonal to instruction correctness).
//
// The core new problem IF has to solve: pc_curr must not move until
// the CURRENT fetch actually completes (flash_ready), not every
// cycle like BRAM allowed. And since a flash transaction can't be
// aborted once started, a misprediction/JALR flush discovered by EX
// while a fetch is already in flight can't be acted on immediately -
// it gets latched (pending_redirect/pending_target) and applied once
// that in-flight (now provably stale) fetch finishes, discarding its
// result instead of using it.
//
// NOP convention, ex_flush/branch predictor/forwarding/load-use stall:
// all unchanged from cpu_pipeline.v - see that file's header comment.

module cpu_pipeline_xip (
    input clk,
    input reset,

    // Physical SPI pins to the (real or simulated) flash chip
    output sck,
    output cs_n,
    output mosi,
    input  miso
);

    // ==================== IF: Instruction Fetch (XIP) ====================

    wire [31:0] pc_curr;
    wire [31:0] pc_next;
    wire [31:0] if_instr;

    pc pc_reg (
        .clk(clk),
        .reset(reset),
        .pc_next(pc_next),
        .pc(pc_curr)
    );

    // Flush/redirect signals, driven combinationally from EX further
    // down this file.
    wire        ex_flush;
    wire [31:0] ex_correct_target;

    // ---- Flash fetch state machine ----
    reg        fetch_issued;      // a flash read is currently outstanding
    reg        pending_redirect;  // EX flushed while mid-fetch - the
                                   // in-flight fetch's result must be
                                   // discarded once it arrives
    reg [31:0] pending_target;

    wire [31:0] flash_rdata;
    wire        flash_ready;
    wire        flash_busy;

    // load_use_hazard is declared/driven further down (needs id_rs1/
    // id_rs2/id_ex_* from the ID section) - used here to avoid both
    // issuing a new fetch, and accepting one that just completed,
    // while the consumer currently sitting in IF/ID isn't allowed to
    // advance yet. In practice this essentially never collides with a
    // fetch completing (a fetch takes ~128 cycles; a load-use hazard
    // only exists for a cycle or two around adjacent real instructions
    // in the 5-stage pipe, which is far shorter), but the guard keeps
    // that pragmatic assumption honest: if it were ever wrong, the
    // fallback is just re-fetching the same address once the hazard
    // clears - wasteful, never incorrect.
    wire load_use_hazard;

    // Start a new fetch whenever we're not already waiting on one and
    // nothing says to hold off.
    wire flash_req = !fetch_issued && !load_use_hazard;

    spi_flash_ctrl flash_ctrl_inst (
        .clk(clk),
        .reset(reset),
        .addr(pc_curr[23:0]),
        .req(flash_req),
        .ready(flash_ready),
        .rdata(flash_rdata),
        .busy(flash_busy),
        .sck(sck),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso)
    );

    // if_instr only actually changes on a ready cycle - flash_rdata is
    // itself a registered output inside spi_flash_ctrl.v, held stable
    // between transactions, so this needs no extra latching here.
    assign if_instr = flash_rdata;

    always @(posedge clk) begin
        if (reset) begin
            fetch_issued     <= 1'b0;
            pending_redirect <= 1'b0;
        end else begin
            if (ex_flush && fetch_issued) begin
                // Can't redirect pc mid-transaction - a flash read
                // can't be aborted once started. Remember where we
                // actually need to go once this (now-stale) fetch
                // finishes.
                pending_redirect <= 1'b1;
                pending_target   <= ex_correct_target;
            end

            if (flash_req)
                fetch_issued <= 1'b1;
            else if (flash_ready) begin
                fetch_issued     <= 1'b0;
                pending_redirect <= 1'b0; // consumed this same cycle below
            end
        end
    end

    // ---- Lightweight IF-stage pre-decode (unchanged from
    // cpu_pipeline.v, just now operating on the flash-sourced if_instr,
    // which is only meaningful on a flash_ready cycle) ----
    wire [6:0]  if_opcode = if_instr[6:0];
    wire [31:0] if_imm_b  = {{20{if_instr[31]}}, if_instr[7], if_instr[30:25], if_instr[11:8], 1'b0};
    wire [31:0] if_imm_j  = {{12{if_instr[31]}}, if_instr[19:12], if_instr[20], if_instr[30:21], 1'b0};
    wire        if_is_branch = (if_opcode == 7'b1100011);
    wire        if_is_jal    = (if_opcode == 7'b1101111);

    // ---- Branch predictor: 2-bit saturating counter, PC-indexed ----
    // Identical design to cpu_pipeline.v - see that file for the full
    // explanation.
    reg [1:0] bht [0:63];
    integer   bht_init_i;
    initial begin
        for (bht_init_i = 0; bht_init_i < 64; bht_init_i = bht_init_i + 1)
            bht[bht_init_i] = 2'b01;
    end

    wire [5:0] if_bht_index     = pc_curr[7:2];
    wire       if_predict_taken = if_is_branch && bht[if_bht_index][1];

    wire [31:0] if_predicted_target = if_is_jal ? (pc_curr + if_imm_j)
                                                 : (pc_curr + if_imm_b);
    wire        if_redirect = if_is_jal || if_predict_taken;

    // pc_curr only ever moves on the exact cycle a fetch completes
    // (flash_ready) - frozen at all other times (mid-fetch, blocked by
    // load_use_hazard, or the brief gap between clearing fetch_issued
    // and the next request actually being accepted). The one
    // exception: ex_flush can still need to redirect immediately even
    // when IF isn't mid-fetch at all (fetch_issued=0, flash_ready=0) -
    // that narrow window is real and has to be handled here too, not
    // just via the mid-fetch latch above.
    //
    // flash_ready MUST be checked before fetch_issued, not after:
    // fetch_issued is a register, and on the exact cycle flash_ready
    // pulses, fetch_issued still shows its OLD (pre-edge) value of 1 -
    // it only clears to 0 on the *next* cycle. Checking fetch_issued
    // first meant this mux always took the "frozen" branch and never
    // reached the "decide where to go" branch at all, permanently
    // stalling pc_curr at 0 after the very first fetch.
    assign pc_next =
        flash_ready  ? (pending_redirect ? pending_target :
                        ex_flush          ? ex_correct_target :
                        if_redirect        ? if_predicted_target :
                                             (pc_curr + 32'd4)) :
        fetch_issued ? pc_curr :
        ex_flush ? ex_correct_target :
                   pc_curr;

    // Accept a freshly completed fetch into IF/ID only if it isn't
    // known-stale (pending_redirect), isn't being immediately
    // superseded by a same-cycle flush, and the consumer already
    // sitting in IF/ID has been allowed to move on (!load_use_hazard).
    wire if_id_accept = flash_ready && !pending_redirect && !ex_flush &&
                         !load_use_hazard;

    // ---- IF/ID pipeline register ----
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_predicted_taken;

    always @(posedge clk) begin
        if (reset) begin
            if_id_pc              <= 32'd0;
            if_id_instr           <= 32'h00000013; // NOP
            if_id_predicted_taken <= 1'b0;
        end else if (if_id_accept) begin
            if_id_pc              <= pc_curr;
            if_id_instr           <= if_instr;
            if_id_predicted_taken <= if_predict_taken;
        end else if (load_use_hazard && !flash_ready) begin
            if_id_pc              <= if_id_pc;     // hold: re-decode the same
            if_id_instr           <= if_id_instr;  // instruction next cycle too
            if_id_predicted_taken <= if_id_predicted_taken;
        end else begin
            // Nothing new and nothing to hold onto either (still
            // mid-fetch, or this fetch just completed but was
            // discarded) - bubble.
            if_id_pc              <= pc_curr;
            if_id_instr           <= 32'h00000013;
            if_id_predicted_taken <= 1'b0;
        end
    end

    // ==================== ID: Instruction Decode ====================
    // Unchanged from cpu_pipeline.v.

    wire [6:0] id_opcode = if_id_instr[6:0];
    wire [4:0] id_rd     = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];
    wire [4:0] id_rs1    = if_id_instr[19:15];
    wire [4:0] id_rs2    = if_id_instr[24:20];
    wire [6:0] id_funct7 = if_id_instr[31:25];

    wire [31:0] id_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] id_imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] id_imm_b = {{20{if_id_instr[31]}}, if_id_instr[7], if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] id_imm_j = {{12{if_id_instr[31]}}, if_id_instr[19:12], if_id_instr[20], if_id_instr[30:21], 1'b0};
    wire [31:0] id_imm_u = {if_id_instr[31:12], 12'b0};

    wire [3:0] id_alu_ctrl;
    wire       id_alu_src;
    wire       id_reg_write;
    wire       id_mem_write;
    wire       id_mem_to_reg;
    wire       id_imm_sel;
    wire       id_branch;
    wire       id_jump;
    wire       id_lui;
    wire       id_auipc;

    control control_inst (
        .opcode(id_opcode),
        .funct3(id_funct3),
        .funct7(id_funct7),
        .alu_ctrl(id_alu_ctrl),
        .alu_src(id_alu_src),
        .reg_write(id_reg_write),
        .mem_write(id_mem_write),
        .mem_to_reg(id_mem_to_reg),
        .imm_sel(id_imm_sel),
        .branch(id_branch),
        .jump(id_jump),
        .lui(id_lui),
        .auipc(id_auipc)
    );

    wire [31:0] id_imm = id_imm_sel ? id_imm_s : id_imm_i;

    wire [31:0] id_rs1_data;
    wire [31:0] id_rs2_data;
    wire [31:0] wb_reg_write_data;
    wire        wb_reg_write;
    wire [4:0]  wb_rd;

    regfile regfile_inst (
        .clk(clk),
        .we(wb_reg_write),
        .rs1_addr(id_rs1),
        .rs2_addr(id_rs2),
        .rd_addr(wb_rd),
        .rd_data(wb_reg_write_data),
        .rs1_data(id_rs1_data),
        .rs2_data(id_rs2_data)
    );

    wire [31:0] id_rs1_fwd = (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == id_rs1)) ? wb_reg_write_data : id_rs1_data;
    wire [31:0] id_rs2_fwd = (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == id_rs2)) ? wb_reg_write_data : id_rs2_data;

    // ---- ID/EX pipeline register ----
    reg [31:0] id_ex_pc;
    reg [6:0]  id_ex_opcode;
    reg [4:0]  id_ex_rd, id_ex_rs1, id_ex_rs2;
    reg [2:0]  id_ex_funct3;
    reg [31:0] id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    reg [31:0] id_ex_imm_b, id_ex_imm_j, id_ex_imm_u;
    reg [3:0]  id_ex_alu_ctrl;
    reg        id_ex_alu_src, id_ex_reg_write, id_ex_mem_write,
               id_ex_mem_to_reg, id_ex_branch, id_ex_jump, id_ex_lui,
               id_ex_auipc, id_ex_predicted_taken;

    always @(posedge clk) begin
        if (reset || ex_flush || load_use_hazard) begin
            id_ex_opcode     <= 7'd0;
            id_ex_reg_write  <= 1'b0;
            id_ex_mem_write  <= 1'b0;
            id_ex_mem_to_reg <= 1'b0;
            id_ex_branch     <= 1'b0;
            id_ex_jump       <= 1'b0;
            id_ex_lui        <= 1'b0;
            id_ex_auipc      <= 1'b0;
            id_ex_rd         <= 5'd0;
        end else begin
            id_ex_pc         <= if_id_pc;
            id_ex_opcode     <= id_opcode;
            id_ex_rd         <= id_rd;
            id_ex_rs1        <= id_rs1;
            id_ex_rs2        <= id_rs2;
            id_ex_funct3     <= id_funct3;
            id_ex_rs1_data   <= id_rs1_fwd;
            id_ex_rs2_data   <= id_rs2_fwd;
            id_ex_imm        <= id_imm;
            id_ex_imm_b      <= id_imm_b;
            id_ex_imm_j      <= id_imm_j;
            id_ex_imm_u      <= id_imm_u;
            id_ex_alu_ctrl   <= id_alu_ctrl;
            id_ex_alu_src    <= id_alu_src;
            id_ex_reg_write  <= id_reg_write;
            id_ex_mem_write  <= id_mem_write;
            id_ex_mem_to_reg <= id_mem_to_reg;
            id_ex_branch     <= id_branch;
            id_ex_jump       <= id_jump;
            id_ex_lui        <= id_lui;
            id_ex_auipc      <= id_auipc;
            id_ex_predicted_taken <= if_id_predicted_taken;
        end
    end

    // ==================== EX: Execute ====================
    // Unchanged from cpu_pipeline.v.

    wire [31:0] fwd_rs1_data =
        (ex_mem_reg_write && !ex_mem_mem_to_reg && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) ? ex_mem_result :
        (mem_wb_reg_write_r && (mem_wb_rd_r != 5'd0) && (mem_wb_rd_r == id_ex_rs1)) ? wb_reg_write_data :
        id_ex_rs1_data;

    wire [31:0] fwd_rs2_data =
        (ex_mem_reg_write && !ex_mem_mem_to_reg && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) ? ex_mem_result :
        (mem_wb_reg_write_r && (mem_wb_rd_r != 5'd0) && (mem_wb_rd_r == id_ex_rs2)) ? wb_reg_write_data :
        id_ex_rs2_data;

    wire [31:0] ex_alu_b = id_ex_alu_src ? id_ex_imm : fwd_rs2_data;
    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;

    alu alu_inst (
        .a(fwd_rs1_data),
        .b(ex_alu_b),
        .alu_ctrl(id_ex_alu_ctrl),
        .result(ex_alu_result),
        .zero(ex_alu_zero)
    );

    wire ex_base_cond    = id_ex_funct3[2] ? ex_alu_result[0] : ex_alu_zero;
    wire ex_branch_taken = id_ex_branch & (ex_base_cond ^ id_ex_funct3[0]);

    wire ex_is_jalr = (id_ex_opcode == 7'b1100111);

    wire ex_branch_mispredicted = id_ex_branch & (ex_branch_taken != id_ex_predicted_taken);

    assign ex_flush = ex_is_jalr | ex_branch_mispredicted;
    assign ex_correct_target = ex_is_jalr    ? (ex_alu_result & ~32'd1) :
                                ex_branch_taken ? (id_ex_pc + id_ex_imm_b) :
                                                   (id_ex_pc + 32'd4);

    always @(posedge clk) begin
        if (id_ex_branch) begin
            if (ex_branch_taken) begin
                if (bht[id_ex_pc[7:2]] != 2'b11)
                    bht[id_ex_pc[7:2]] <= bht[id_ex_pc[7:2]] + 2'b01;
            end else begin
                if (bht[id_ex_pc[7:2]] != 2'b00)
                    bht[id_ex_pc[7:2]] <= bht[id_ex_pc[7:2]] - 2'b01;
            end
        end
    end

    wire [31:0] ex_result = id_ex_lui   ? id_ex_imm_u :
                             id_ex_auipc ? (id_ex_pc + id_ex_imm_u) :
                             id_ex_jump  ? (id_ex_pc + 32'd4) :
                                           ex_alu_result;

    // ---- EX/MEM pipeline register ----
    reg [31:0] ex_mem_alu_result, ex_mem_rs2_data, ex_mem_result;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_reg_write, ex_mem_mem_write, ex_mem_mem_to_reg;

    always @(posedge clk) begin
        if (reset) begin
            ex_mem_reg_write <= 1'b0;
            ex_mem_mem_write <= 1'b0;
        end else begin
            ex_mem_alu_result <= ex_alu_result;
            ex_mem_rs2_data    <= fwd_rs2_data;
            ex_mem_result      <= ex_result;
            ex_mem_rd          <= id_ex_rd;
            ex_mem_funct3      <= id_ex_funct3;
            ex_mem_reg_write   <= id_ex_reg_write;
            ex_mem_mem_write   <= id_ex_mem_write;
            ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
        end
    end

    // ==================== MEM: Memory Access ====================
    // Unchanged from cpu_pipeline.v - data memory stays on-chip BRAM;
    // flash is read-mostly (writes need slow erase/program cycles),
    // so only instruction fetch moves to flash.

    wire [31:0] mem_dmem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .addr(ex_mem_alu_result),
        .write_data(ex_mem_rs2_data),
        .mem_write(ex_mem_mem_write),
        .funct3(ex_mem_funct3),
        .read_data(mem_dmem_read_data)
    );

    // ---- MEM/WB pipeline register ----
    reg [31:0] mem_wb_dmem_read_data, mem_wb_result;
    reg [4:0]  mem_wb_rd_r;
    reg        mem_wb_reg_write_r, mem_wb_mem_to_reg;

    always @(posedge clk) begin
        if (reset) begin
            mem_wb_reg_write_r <= 1'b0;
        end else begin
            mem_wb_dmem_read_data <= mem_dmem_read_data;
            mem_wb_result         <= ex_mem_result;
            mem_wb_rd_r           <= ex_mem_rd;
            mem_wb_reg_write_r    <= ex_mem_reg_write;
            mem_wb_mem_to_reg     <= ex_mem_mem_to_reg;
        end
    end

    // ==================== WB: Write-Back ====================

    assign wb_reg_write      = mem_wb_reg_write_r;
    assign wb_rd             = mem_wb_rd_r;
    assign wb_reg_write_data = mem_wb_mem_to_reg ? mem_wb_dmem_read_data
                                                  : mem_wb_result;

    // load_use_hazard needs id_rs1/id_rs2 (from ID) and id_ex_mem_to_reg/
    // id_ex_rd (from the ID/EX register) - declared up in the IF
    // section since it's needed there, defined here since Verilog
    // doesn't care about textual order for continuous assignments.
    assign load_use_hazard = id_ex_mem_to_reg && (id_ex_rd != 5'd0) &&
                              ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2));

endmodule
