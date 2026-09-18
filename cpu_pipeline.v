// cpu_pipeline.v
// 5-stage pipelined RV32I core (IF / ID / EX / MEM / WB)
//
// Same ISA coverage as cpu.v (the single-cycle core, kept unchanged
// as a working reference), reusing every submodule exactly as-is -
// only the top-level wiring changes, from one long combinational
// chain into 5 stages separated by clocked pipeline registers.
//
// Data hazards are handled by forwarding (EX/MEM and MEM/WB results
// bypassed straight into EX, instead of waiting for the normal
// write-then-read path through regfile) plus a one-cycle stall for
// the one case forwarding can't cover: a load's result isn't ready
// until MEM, one stage later than a normal ALU result, so its
// immediate next consumer has to wait one extra cycle before
// forwarding can supply it.
//
// Control hazard handling: every branch/jump is resolved in EX (same
// point single-cycle resolved it). Fetch always assumes sequential
// execution (pc+4) in the meantime. When EX discovers an actual
// jump, or a branch that's actually taken, it redirects pc_next to
// the correct target AND squashes (turns into a NOP) the two
// instructions that were wrongly fetched in the meantime - the one
// currently in IF/ID and the one currently in ID/EX. This is
// "predict not-taken" - a real branch predictor is a planned next
// step, replacing only the prediction itself, not this flush
// mechanism.
//
// NOP convention: a squashed instruction becomes 32'h00000013
// (addi x0, x0, 0) - RV32I's canonical NOP encoding. It decodes to a
// completely harmless instruction (reg_write ends up asserted, but
// rd=x0, so regfile's hardwired-zero write guard discards it) rather
// than needing a separate "valid" bit threaded through every stage.

module cpu_pipeline (
    input clk,
    input reset
);

    // ==================== IF: Instruction Fetch ====================

    wire [31:0] pc_curr;
    wire [31:0] pc_next;
    wire [31:0] if_instr;

    pc pc_reg (
        .clk(clk),
        .reset(reset),
        .pc_next(pc_next),
        .pc(pc_curr)
    );

    imem imem_inst (
        .addr(pc_curr),
        .instr(if_instr)
    );

    // Flush/redirect signals, driven combinationally from EX further
    // down this file - declared here since they're consumed by the
    // pc_next mux and the IF/ID register below.
    wire        ex_flush;
    wire [31:0] ex_correct_target;

    // Load-use hazard: the instruction about to enter EX (currently
    // in id_ex) is a load, and the instruction about to enter ID
    // (currently in if_id, decoded combinationally into id_rs1/
    // id_rs2 below) needs the register it's about to produce. This
    // is the one case forwarding alone can't fix - the loaded value
    // doesn't exist yet even one stage later in EX/MEM, only the
    // address does - so fetch/decode of everything behind the
    // consumer has to wait one cycle while a bubble is inserted.
    // Checking both id_rs1 and id_rs2 unconditionally (rather than
    // only the one(s) the consuming instruction actually reads) is
    // conservative - it can very occasionally stall one cycle that
    // strictly wasn't needed, but never misses a real hazard.
    wire load_use_hazard = id_ex_mem_to_reg && (id_ex_rd != 5'd0) &&
                            ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2));

    // Fetch always assumes sequential execution; EX corrects it when
    // that assumption turns out wrong. A load-use hazard freezes
    // fetch at the current pc for one cycle instead of advancing.
    assign pc_next = ex_flush        ? ex_correct_target :
                      load_use_hazard ? pc_curr :
                                        (pc_curr + 32'd4);

    // ---- IF/ID pipeline register ----
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    always @(posedge clk) begin
        if (reset) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h00000013; // NOP
        end else if (ex_flush) begin
            if_id_pc    <= pc_curr;
            if_id_instr <= 32'h00000013; // squash: this fetch was wrong
        end else if (load_use_hazard) begin
            if_id_pc    <= if_id_pc;     // hold: re-decode the same
            if_id_instr <= if_id_instr;  // instruction next cycle too
        end else begin
            if_id_pc    <= pc_curr;
            if_id_instr <= if_instr;
        end
    end

    // ==================== ID: Instruction Decode ====================

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

    // Register file: read here in ID, written back in WB (see the
    // bottom of this file) - the same single instance spans both
    // ends of the pipeline, exactly like every other submodule here
    // is reused across stages rather than duplicated.
    wire [31:0] id_rs1_data;
    wire [31:0] id_rs2_data;
    wire [31:0] wb_reg_write_data; // driven by the WB stage below
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

    // Same-cycle write-through: regfile's own write (driven by WB,
    // using registered mem_wb_* state - not by anything computed this
    // cycle from id_rs1_data itself, so this creates no combinational
    // loop) and this cycle's ID-stage read can target the same
    // address. Plain non-blocking-assignment semantics mean the read
    // wouldn't see that write until the *next* cycle, which is one
    // cycle too late here specifically: it's the gap EX-stage
    // forwarding can't cover either, since by the time an instruction
    // reaches EX, an exactly-3-instructions-ago producer has already
    // fully retired out of both EX/MEM and MEM/WB. This bypass is
    // exactly what real register files do for this case - it just
    // has to live here (comparing against WB's registered signals)
    // rather than inside regfile.v itself, since regfile.v is shared
    // with the single-cycle core, where a single instruction's own
    // read and write can share an address (e.g. addi x1,x1,5) and the
    // write depends combinationally on that same read via the ALU -
    // a real loop that this module's pipeline structure doesn't have,
    // since wb_reg_write_data here comes from an already-registered,
    // much earlier stage.
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
               id_ex_auipc;

    always @(posedge clk) begin
        if (reset || ex_flush || load_use_hazard) begin
            // Squash (a control-flow flush, or a load-use bubble):
            // zero every control signal so this slot behaves as a
            // no-op regardless of whatever data fields hold
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
        end
    end

    // ==================== EX: Execute ====================

    // Forwarding: supply the freshest value for rs1/rs2, bypassing
    // regfile's normal write-then-read path when a very recent
    // instruction (still in EX/MEM or MEM/WB, not yet written back)
    // produced the value this instruction needs. EX/MEM is checked
    // first since it holds the more recently-issued instruction - if
    // both happen to target the same register, EX/MEM's is the
    // freshest write and must win.
    //
    // EX/MEM's rd is excluded when it's a load (mem_to_reg) as a
    // defensive guard: the load-use stall above should already
    // guarantee nothing ever needs EX/MEM's value while it's still
    // just an address rather than loaded data, but this costs
    // nothing and protects against that assumption being wrong.
    //
    // MEM/WB forwards wb_reg_write_data (the WB stage's own final
    // mux output, at the bottom of this file) rather than
    // mem_wb_result directly, since wb_reg_write_data already
    // resolves the mem_to_reg choice - correct whether that
    // instruction was a load or not.
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

    // Same branch-condition logic as the single-cycle core: reuse the
    // ALU's SUB/SLT/SLTU outputs, funct3[0] as the invert bit.
    wire ex_base_cond    = id_ex_funct3[2] ? ex_alu_result[0] : ex_alu_zero;
    wire ex_branch_taken = id_ex_branch & (ex_base_cond ^ id_ex_funct3[0]);

    wire ex_is_jalr = (id_ex_opcode == 7'b1100111);
    wire [31:0] ex_jump_target = ex_is_jalr ? (ex_alu_result & ~32'd1)
                                             : (id_ex_pc + id_ex_imm_j);

    // Flush fires whenever EX discovers fetch's sequential assumption
    // was wrong: any jump, or a branch that turned out taken.
    assign ex_flush = id_ex_jump | ex_branch_taken;
    assign ex_correct_target = id_ex_jump ? ex_jump_target
                                           : (id_ex_pc + id_ex_imm_b);

    // Resolves everything the write-back mux needs except a memory
    // read (which doesn't exist until MEM) - carrying one pre-combined
    // value forward instead of lui/auipc/jump separately keeps EX/MEM
    // and MEM/WB simpler.
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
            ex_mem_rs2_data    <= fwd_rs2_data; // forwarded: a store's data operand needs the same bypass as the ALU's
            ex_mem_result      <= ex_result;
            ex_mem_rd          <= id_ex_rd;
            ex_mem_funct3      <= id_ex_funct3;
            ex_mem_reg_write   <= id_ex_reg_write;
            ex_mem_mem_write   <= id_ex_mem_write;
            ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
        end
    end

    // ==================== MEM: Memory Access ====================

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

endmodule
