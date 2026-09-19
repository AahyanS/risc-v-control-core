// cpu_pipeline_cache_locked.v
// Configuration 3 of the project's core experiment: XIP from flash,
// cache, AND cache-line locking - the actual thesis of this project.
// Byte-for-byte identical to cpu_pipeline_cache.v except for one
// addition: a memory-mapped control register that lets software lock
// (or unlock) a cache line, wired into icache_inst's new lock_cmd/
// lock_set/lock_addr ports.
//
// ---- The memory-mapped lock register ----
// A `sw` to address MMIO_LOCK_ADDR (0xFFFFFF00 - well outside dmem's
// real 8KB range, so it can never collide with an actual data access)
// is intercepted in the MEM stage before it reaches dmem_inst, and
// routed to the cache instead:
//   store value bit  31   -> lock_set  (1 = lock, 0 = unlock)
//   store value bits 23:0 -> lock_addr (any address inside the line
//                                        to lock/unlock)
// Software is expected to have already executed/fetched the target
// code at least once (warming its line) before issuing the lock -
// the command only sets a bit, it does not force a fill. See
// icache.v's header for the full design (why locking works this way,
// and the real tradeoff it buys: any other address aliasing to a
// locked line becomes permanently uncacheable while the lock holds).
//
// Everything else - IF's fetch state machine, ID/EX/MEM/WB, forwarding,
// load-use stall, the branch predictor - is unchanged from
// cpu_pipeline_cache.v / cpu_pipeline_xip.v / cpu_pipeline.v.

module cpu_pipeline_cache_locked (
    input clk,
    input reset,

    // Physical SPI pins to the (real or simulated) flash chip
    output sck,
    output cs_n,
    output mosi,
    input  miso
);

    localparam [31:0] MMIO_LOCK_ADDR = 32'hFFFFFF00;

    // ==================== IF: Instruction Fetch (XIP + cache) ====================

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

    // ---- Fetch state machine (unchanged) ----
    reg        fetch_issued;      // a fetch is currently outstanding
    reg        pending_redirect;  // EX flushed while mid-fetch - the
                                   // in-flight fetch's result must be
                                   // discarded once it arrives
    reg [31:0] pending_target;

    wire [31:0] flash_rdata;
    wire        flash_ready;
    wire        flash_busy;

    wire load_use_hazard;

    wire flash_req = !fetch_issued && !load_use_hazard;

    // Lock control, driven from the MEM stage below.
    wire        lock_cmd;
    wire        lock_set;
    wire [23:0] lock_addr;

    // Instrumentation wiring, also driven from the MEM stage below.
    wire        stats_reset;
    wire [31:0] hit_count;
    wire [31:0] miss_count;

    icache icache_inst (
        .clk(clk),
        .reset(reset),
        .addr(pc_curr[23:0]),
        .req(flash_req),
        .ready(flash_ready),
        .rdata(flash_rdata),
        .busy(flash_busy),
        .lock_cmd(lock_cmd),
        .lock_set(lock_set),
        .lock_addr(lock_addr),
        .hit_count(hit_count),
        .miss_count(miss_count),
        .stats_reset(stats_reset),
        .sck(sck),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso)
    );

    assign if_instr = flash_rdata;

    always @(posedge clk) begin
        if (reset) begin
            fetch_issued     <= 1'b0;
            pending_redirect <= 1'b0;
        end else begin
            if (ex_flush && fetch_issued) begin
                pending_redirect <= 1'b1;
                pending_target   <= ex_correct_target;
            end

            if (flash_req)
                fetch_issued <= 1'b1;
            else if (flash_ready) begin
                fetch_issued     <= 1'b0;
                pending_redirect <= 1'b0;
            end
        end
    end

    // ---- Lightweight IF-stage pre-decode (unchanged) ----
    wire [6:0]  if_opcode = if_instr[6:0];
    wire [31:0] if_imm_b  = {{20{if_instr[31]}}, if_instr[7], if_instr[30:25], if_instr[11:8], 1'b0};
    wire [31:0] if_imm_j  = {{12{if_instr[31]}}, if_instr[19:12], if_instr[20], if_instr[30:21], 1'b0};
    wire        if_is_branch = (if_opcode == 7'b1100011);
    wire        if_is_jal    = (if_opcode == 7'b1101111);

    // ---- Branch predictor: 2-bit saturating counter, PC-indexed
    // (unchanged) ----
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

    assign pc_next =
        flash_ready  ? (pending_redirect ? pending_target :
                        ex_flush          ? ex_correct_target :
                        if_redirect        ? if_predicted_target :
                                             (pc_curr + 32'd4)) :
        fetch_issued ? pc_curr :
        ex_flush ? ex_correct_target :
                   pc_curr;

    wire if_id_accept = flash_ready && !pending_redirect && !ex_flush &&
                         !load_use_hazard;

    // ---- IF/ID pipeline register (unchanged) ----
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
            if_id_pc              <= if_id_pc;
            if_id_instr           <= if_id_instr;
            if_id_predicted_taken <= if_id_predicted_taken;
        end else begin
            if_id_pc              <= pc_curr;
            if_id_instr           <= 32'h00000013;
            if_id_predicted_taken <= 1'b0;
        end
    end

    // ==================== ID: Instruction Decode ====================
    // Unchanged.

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

    // ---- ID/EX pipeline register (unchanged) ----
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
    // Unchanged.

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
    // Data memory stays on-chip BRAM, as before - EXCEPT loads/stores
    // to four reserved memory-mapped addresses are diverted away from
    // dmem entirely, so they can't be misread as - or overwrite - real
    // data at whatever address the array happened to alias to:
    //   0xFFFFFF00 - cache lock control (write-only; see icache.v)
    //   0xFFFFFF04 - cycle counter (free-running; store resets to 0)
    //   0xFFFFFF08 - cache hit count
    //   0xFFFFFF0C - cache miss count (fills AND locked-line bypasses
    //                both count as a miss - both left the 1-cycle hit
    //                path)
    // A store to either counter address resets BOTH hit and miss
    // together, since they're only meaningful as a pair.

    localparam [31:0] MMIO_CYCLE_ADDR = 32'hFFFFFF04;
    localparam [31:0] MMIO_HIT_ADDR   = 32'hFFFFFF08;
    localparam [31:0] MMIO_MISS_ADDR  = 32'hFFFFFF0C;

    wire is_mmio_lock_write = ex_mem_mem_write && (ex_mem_alu_result == MMIO_LOCK_ADDR);
    wire is_mmio_cycle_addr = (ex_mem_alu_result == MMIO_CYCLE_ADDR);
    wire is_mmio_hit_addr   = (ex_mem_alu_result == MMIO_HIT_ADDR);
    wire is_mmio_miss_addr  = (ex_mem_alu_result == MMIO_MISS_ADDR);
    wire is_mmio_addr       = is_mmio_lock_write || is_mmio_cycle_addr ||
                               is_mmio_hit_addr || is_mmio_miss_addr;

    wire dmem_write_en = ex_mem_mem_write && !is_mmio_addr;

    assign lock_cmd    = is_mmio_lock_write;
    assign lock_set    = ex_mem_rs2_data[31];
    assign lock_addr   = ex_mem_rs2_data[23:0];
    assign stats_reset = ex_mem_mem_write && (is_mmio_hit_addr || is_mmio_miss_addr);

    reg [31:0] cycle_count;
    always @(posedge clk) begin
        if (reset || (ex_mem_mem_write && is_mmio_cycle_addr))
            cycle_count <= 32'd0;
        else
            cycle_count <= cycle_count + 32'd1;
    end

    wire [31:0] mem_dmem_read_data;
    wire [31:0] mem_read_data_muxed =
        is_mmio_cycle_addr ? cycle_count :
        is_mmio_hit_addr   ? hit_count :
        is_mmio_miss_addr  ? miss_count :
                             mem_dmem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .addr(ex_mem_alu_result),
        .write_data(ex_mem_rs2_data),
        .mem_write(dmem_write_en),
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
            mem_wb_dmem_read_data <= mem_read_data_muxed;
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

    assign load_use_hazard = id_ex_mem_to_reg && (id_ex_rd != 5'd0) &&
                              ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2));

endmodule
