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
//
// ---- Quadrature encoder decoder (Phase 4) ----
// quad_decoder.v runs continuously off enc_a/enc_b regardless of CPU
// activity - see that file's header for why. Its position count is
// readable at 0xFFFFFF10 (store resets to 0); its diagnostic
// invalid-transition count at 0xFFFFFF14 (read-only - there's nothing
// meaningful to reset it to independent of position).
//
// ---- PWM output (Phase 4) ----
// pwm.v is the actuator-side counterpart - also runs continuously off
// clk once duty_cycle is set, without needing the CPU to service it
// every period. duty_cycle is read/write at 0xFFFFFF18 (write sets
// it, read returns the last value written).
//
// Neither peripheral is wired into the plain XIP/cache configs - those
// exist specifically for the cache-latency comparison experiment, not
// for building the real control system on top of.
//
// ---- Board-facing outputs (Phase 5) ----
// led: 16-bit register at 0xFFFFFF28 (read/write), for seeing the CPU
// run on real hardware without a debugger. motor_dir: bit 0 of
// 0xFFFFFF2C (read/write), the direction software is requesting - the
// board top (fpga/basys3_top.v) passes it through motor_dir_guard.v
// before it reaches the H-bridge, never directly. uart_tx: a UART
// transmitter (uart_tx.v) at 0xFFFFFF30, so programs can print their
// measurements to a PC over the Basys3's USB cable.
//
// FLASH_BASE offsets every instruction fetch in flash (see
// spi_flash_ctrl.v); 0 in simulation, set by the board top on hardware.

module cpu_pipeline_cache_locked #(
    parameter [23:0] FLASH_BASE = 24'h000000,
    parameter        UART_CLKS_PER_BIT = 217     // 25 MHz / 115200 baud
) (
    input clk,
    input reset,

    // Physical SPI pins to the (real or simulated) flash chip
    output sck,
    output cs_n,
    output mosi,
    input  miso,

    // Quadrature encoder inputs (real or simulated)
    input enc_a,
    input enc_b,

    // PWM output (to a real or simulated motor driver)
    output pwm_out,

    // Board-facing outputs
    output reg [15:0] led,
    output reg        motor_dir,
    output            uart_tx
);

    localparam [31:0] MMIO_LOCK_ADDR    = 32'hFFFFFF00;
    localparam [31:0] MMIO_ENC_POS_ADDR = 32'hFFFFFF10;
    localparam [31:0] MMIO_ENC_ERR_ADDR = 32'hFFFFFF14;
    localparam [31:0] MMIO_PWM_ADDR     = 32'hFFFFFF18;

    wire signed [31:0] enc_position;
    wire        [31:0] enc_error_count;
    wire               enc_position_clear;   // driven from the MEM stage below
    reg                enc_single_channel;   // 0xFFFFFF38 bit 0, written from MEM below

    quad_decoder quad_decoder_inst (
        .clk(clk),
        .reset(reset),
        .a(enc_a),
        .b(enc_b),
        .clear_position(enc_position_clear),
        .single_channel(enc_single_channel),
        .dir(motor_dir),
        .position(enc_position),
        .error_count(enc_error_count)
    );

    reg [31:0] pwm_duty_cycle;   // written from the MEM stage below

    pwm pwm_inst (
        .clk(clk),
        .reset(reset),
        .duty_cycle(pwm_duty_cycle),
        .pwm_out(pwm_out)
    );

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
    wire        trap_taken;          // driven in the EX section

    // ---- Fetch state machine (unchanged) ----
    reg        fetch_issued;      // a fetch is currently outstanding
    reg        pending_redirect;  // EX flushed while mid-fetch - the
                                   // in-flight fetch's result must be
                                   // discarded once it arrives
    reg [31:0] pending_target;
    reg        pending_trap;      // ...and that flush was an interrupt:
                                   // the in-flight fetch is aborted
                                   // rather than waited out (see
                                   // icache.v, "Abort")

    wire [31:0] flash_rdata;
    wire        flash_ready;
    wire        flash_busy;

    wire load_use_hazard;

    // !ex_flush: never start a fetch in a cycle that redirects. The
    // request would be for the old pc_curr while pc moves to the
    // redirect target, so the returned instruction would be labeled
    // with the wrong PC. Under the original trap rule a flush always
    // coincided with a fetch already outstanding (the two-cycle fetch
    // cadence lined up that way), so this never arose; once interrupts
    // could be taken in any cycle it did - found by
    // tb_interrupt_stress.v as a trap storm: the handler's first
    // instruction was replaced by the interrupted code's, so the tick
    // was never acknowledged.
    wire flash_req = !fetch_issued && !load_use_hazard && !ex_flush;

    // Lock control, driven from the MEM stage below.
    wire        lock_cmd;
    wire        lock_set;
    wire [23:0] lock_addr;
    reg         cache_disable;   // 0xFFFFFF34 bit 0, written from MEM below

    // Instrumentation wiring, also driven from the MEM stage below.
    wire        stats_reset;
    wire [31:0] hit_count;
    wire [31:0] miss_count;

    icache #(.FLASH_BASE(FLASH_BASE)) icache_inst (
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
        .cache_disable(cache_disable),
        .abort(pending_redirect && pending_trap),
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
            pending_trap     <= 1'b0;
        end else begin
            if (ex_flush && fetch_issued) begin
                pending_redirect <= 1'b1;
                pending_target   <= ex_correct_target;
                pending_trap     <= trap_taken;
            end

            if (flash_req)
                fetch_issued <= 1'b1;
            else if (flash_ready) begin
                fetch_issued     <= 1'b0;
                pending_redirect <= 1'b0;
                pending_trap     <= 1'b0;
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
        // ex_flush before pending_redirect: an interrupt can now be
        // taken while an earlier redirect is still pending (see
        // trap_taken), and must win. Before that change the two could
        // never coincide - EX only holds bubbles while a redirect is
        // pending - so the order didn't matter.
        flash_ready  ? (ex_flush          ? ex_correct_target :
                        pending_redirect  ? pending_target :
                        if_redirect        ? if_predicted_target :
                                             (pc_curr + 32'd4)) :
        fetch_issued ? pc_curr :
        ex_flush ? ex_correct_target :
                   pc_curr;

    wire if_id_accept = flash_ready && !pending_redirect && !ex_flush &&
                         !load_use_hazard;

    // ---- IF/ID pipeline register ----
    // if_id_valid distinguishes a genuinely fetched instruction from a
    // pipeline-inserted bubble - needed because the NOP encoding used
    // for bubbles (32'h00000013) is bit-identical to a real `addi
    // x0,x0,0`, so opcode alone can't tell them apart. This matters
    // for interrupt injection (see trap_taken in the EX section
    // below): without it, a bubble inserted by MRET's own flush could
    // itself look like a "real" instruction with a stale PC, and get
    // mistaken for a valid trap point - found exactly this way, by
    // tracing a failing interrupt test rather than reasoning about it
    // abstractly (mepc ended up pointing into the middle of the
    // handler itself).
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_predicted_taken;
    reg        if_id_valid;

    always @(posedge clk) begin
        if (reset) begin
            if_id_pc              <= 32'd0;
            if_id_instr           <= 32'h00000013; // NOP
            if_id_predicted_taken <= 1'b0;
            if_id_valid           <= 1'b0;
        end else if (if_id_accept) begin
            if_id_pc              <= pc_curr;
            if_id_instr           <= if_instr;
            if_id_predicted_taken <= if_predict_taken;
            if_id_valid           <= 1'b1;
        end else if (load_use_hazard && !flash_ready && !ex_flush) begin
            // (!ex_flush: a trap taken while the load is in EX must also
            // squash the dependent instruction held here - holding it
            // would let it execute ahead of the handler with a stale
            // operand, then again after mret. Unreachable in this core
            // today: fetch delivers at most one instruction per two
            // cycles, so load-use stalls never actually occur - 0 in
            // 38,929 cycles of tb_interrupt_stress.v - but it would
            // become a live bug if fetch ever got faster.)
            if_id_pc              <= if_id_pc;
            if_id_instr           <= if_id_instr;
            if_id_predicted_taken <= if_id_predicted_taken;
            if_id_valid           <= if_id_valid;   // still holding a real instruction, just stalled
        end else begin
            if_id_pc              <= pc_curr;
            if_id_instr           <= 32'h00000013;
            if_id_predicted_taken <= 1'b0;
            if_id_valid           <= 1'b0;
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
    wire       id_is_csr;
    wire       id_csr_set_mode;
    wire       id_is_mac;

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
        .auipc(id_auipc),
        .is_csr(id_is_csr),
        .csr_set_mode(id_csr_set_mode),
        .is_mac(id_is_mac)
    );

    // MRET: decoded directly from the raw instruction bits rather than
    // in control.v (see control.v's header comment) - funct12 (the
    // rs2 field + funct7 combined) = 0x302, rs1=0, rd=0 distinguishes
    // it from ECALL/EBREAK/WFI, which all share funct3=000 too.
    wire id_is_mret = (id_opcode == 7'b1110011) && (id_funct3 == 3'b000) &&
                       (if_id_instr[31:20] == 12'h302);

    wire [31:0] id_imm = id_imm_sel ? id_imm_s : id_imm_i;

    wire [31:0] id_rs1_data;
    wire [31:0] id_rs2_data;
    wire [31:0] id_acc_data;   // MAC's implicit 3rd read: rd's current value
    wire [31:0] wb_reg_write_data;
    wire        wb_reg_write;
    wire [4:0]  wb_rd;

    regfile regfile_inst (
        .clk(clk),
        .we(wb_reg_write),
        .rs1_addr(id_rs1),
        .rs2_addr(id_rs2),
        .rs3_addr(id_rd),        // MAC reads rd as an accumulator input, same field as the write destination
        .rd_addr(wb_rd),
        .rd_data(wb_reg_write_data),
        .rs1_data(id_rs1_data),
        .rs2_data(id_rs2_data),
        .rs3_data(id_acc_data)
    );

    wire [31:0] id_rs1_fwd = (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == id_rs1)) ? wb_reg_write_data : id_rs1_data;
    wire [31:0] id_rs2_fwd = (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == id_rs2)) ? wb_reg_write_data : id_rs2_data;
    wire [31:0] id_acc_fwd = (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == id_rd))  ? wb_reg_write_data : id_acc_data;

    // ---- ID/EX pipeline register (unchanged) ----
    reg [31:0] id_ex_pc;
    reg [6:0]  id_ex_opcode;
    reg [4:0]  id_ex_rd, id_ex_rs1, id_ex_rs2;
    reg [2:0]  id_ex_funct3;
    reg [31:0] id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    reg [31:0] id_ex_imm_b, id_ex_imm_j, id_ex_imm_u;
    reg [31:0] id_ex_acc_data;
    reg [3:0]  id_ex_alu_ctrl;
    reg        id_ex_alu_src, id_ex_reg_write, id_ex_mem_write,
               id_ex_mem_to_reg, id_ex_branch, id_ex_jump, id_ex_lui,
               id_ex_auipc, id_ex_predicted_taken;
    reg        id_ex_is_csr, id_ex_csr_set_mode, id_ex_is_mret, id_ex_is_mac;
    reg        id_ex_valid;

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
            id_ex_is_csr     <= 1'b0;
            id_ex_is_mret    <= 1'b0;
            id_ex_is_mac     <= 1'b0;
            id_ex_valid      <= 1'b0;
        end else begin
            id_ex_pc         <= if_id_pc;
            id_ex_valid      <= if_id_valid;
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
            id_ex_is_csr       <= id_is_csr;
            id_ex_csr_set_mode <= id_csr_set_mode;
            id_ex_is_mret      <= id_is_mret;
            id_ex_is_mac       <= id_is_mac;
            id_ex_acc_data     <= id_acc_fwd;
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

    // MAC's accumulator read (rd, read as a source alongside rs1/rs2) -
    // same two-stage forwarding pattern as rs1/rs2, just comparing
    // against id_ex_rd (the SAME field MAC reads and writes) instead
    // of id_ex_rs1/id_ex_rs2. This matters in exactly the case MAC
    // exists for: three consecutive mac instructions accumulating
    // into the same rd (Kp*error, then Ki*integral, then
    // Kd*derivative) - each one depends on the immediately preceding
    // one's result, which hasn't reached WB yet.
    wire [31:0] fwd_acc_data =
        (ex_mem_reg_write && !ex_mem_mem_to_reg && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rd)) ? ex_mem_result :
        (mem_wb_reg_write_r && (mem_wb_rd_r != 5'd0) && (mem_wb_rd_r == id_ex_rd)) ? wb_reg_write_data :
        id_ex_acc_data;

    // ---- Custom MAC instruction (Phase 4): rd = rd + (rs1*rs2), Q16.16 ----
    // A genuine hardware multiplier - Verilog's * describes real
    // multiplier circuitry once it's inside an RTL module, even
    // though this CPU's own instruction set has no general multiply
    // (base RV32I) - that gap is exactly why the software PID needed
    // -lgcc's __mulsi3/__muldi3 earlier. This is the hardware-
    // accelerated alternative for the one operation a PID loop
    // actually repeats.
    //
    // Kept as its own dedicated combinational block, not folded into
    // the shared ALU - ordinary ALU operations (add/sub/compare/etc,
    // used by every instruction) don't pay any timing cost from the
    // multiplier's presence; only MAC's own path does. Real cost/
    // benefit reporting (does this lengthen the critical path enough
    // to reduce Fmax) needs FPGA synthesis timing analysis - a Phase 5
    // concern once that toolchain is actually in the loop, not
    // something simulation can answer.
    wire signed [63:0] mac_product = $signed(fwd_rs1_data) * $signed(fwd_rs2_data);
    wire        [31:0] mac_result  = fwd_acc_data + mac_product[47:16];

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

    // ---- CSR register file (Phase 4) ----
    // Minimal M-mode subset: mstatus (bit 3 = MIE, bit 7 = MPIE - only
    // these two fields implemented), mie (bit 7 = MTIE - only this
    // source implemented, since the timer is the only interrupt
    // source this core has), mtvec (direct mode only - no vectored
    // mode), mepc, mcause. mip is NOT a stored register - it's the
    // live, read-only reflection of timer_pending (bit 7 = MTIP),
    // matching how real hardware's mip.MTIP works: software can't
    // write it directly, only observe it and clear the underlying
    // condition (here, via the timer's own clear_pending MMIO
    // address - see the MEM section below).
    //
    // Reads and writes both happen in this same stage (unlike the
    // register file, which reads in ID but writes in WB), so no
    // forwarding path is needed for back-to-back CSR
    // write-then-read - the write lands on the clock edge, so the verу
    // next cycle's combinational read of the same register already
    // sees the new value with no special-casing required.
    reg [31:0] mstatus;
    reg [31:0] mie;
    reg [31:0] mtvec;
    reg [31:0] mepc;
    reg [31:0] mcause;

    wire mstatus_mie = mstatus[3];
    wire mie_mtie    = mie[7];

    wire        timer_pending;   // driven by timer_inst, wired in the MEM section below
    wire [31:0] mip_value = {24'd0, timer_pending, 7'd0};   // bit 7 = MTIP

    // The low 12 bits of the I-type immediate are the raw instruction
    // bits regardless of sign extension - reusing id_ex_imm avoids
    // needing a separately-propagated csr_addr field through ID/EX.
    wire [11:0] csr_addr = id_ex_imm[11:0];

    wire [31:0] csr_read_value =
        (csr_addr == 12'h300) ? mstatus :
        (csr_addr == 12'h304) ? mie :
        (csr_addr == 12'h305) ? mtvec :
        (csr_addr == 12'h341) ? mepc :
        (csr_addr == 12'h342) ? mcause :
        (csr_addr == 12'h344) ? mip_value :
                                 32'd0;

    wire [31:0] csr_new_value = id_ex_csr_set_mode ? (csr_read_value | fwd_rs1_data) : fwd_rs1_data;

    // Interrupt taken when globally enabled (mstatus.MIE), source
    // enabled (mie.MTIE), pending (the timer's own signal), AND EX
    // holds a real, non-bubble instruction - gated on id_ex_valid,
    // not on id_ex_opcode being nonzero. id_ex_opcode alone isn't
    // enough: the NOP encoding the pipeline inserts for bubbles
    // (32'h00000013) is bit-identical to a real `addi x0,x0,0`, so a
    // pipeline-inserted bubble decodes to a perfectly ordinary nonzero
    // opcode - opcode can't tell a real instruction from a bubble.
    // id_ex_valid can, since it's set only when if_id_accept actually
    // latched a genuine fetch (see the IF/ID register above). Found
    // this exact gap by tracing a failing test, not by inspection:
    // without id_ex_valid, a bubble inserted by MRET's own flush could
    // itself be mistaken for a valid trap point, with mepc left
    // pointing at a stale, meaningless PC.
    //
    // Taken in ANY cycle, not only when EX holds a real instruction.
    // The first version waited for id_ex_valid, which made interrupt
    // entry wait out whatever flash read was in flight: measured on the
    // control-loop benchmark (sw/hw_control_loop.s), entry took 4-180
    // cycles depending on where in the interrupted code's flash
    // transaction the tick landed - jitter the locked handler couldn't
    // remove. Now the trap is taken immediately and the in-flight fetch
    // is aborted (pending_trap, icache.v "Abort").
    //
    // The bubble problem described above is handled by computing mepc
    // from what the pipeline actually holds, instead of taking EX's PC:
    // the oldest instruction that hasn't executed yet is in EX if EX is
    // valid, else in ID if ID is valid, else it's the one being (or
    // about to be) fetched - pending_target if an earlier redirect
    // is waiting on the in-flight fetch, pc_curr otherwise. Everything
    // younger is flushed, so after mret execution resumes exactly there.
    wire [31:0] next_exec_pc = id_ex_valid                       ? id_ex_pc :
                               if_id_valid                       ? if_id_pc :
                               (fetch_issued && pending_redirect) ? pending_target :
                                                                    pc_curr;
    //
    // Forward progress: taking traps in any cycle and aborting the fetch
    // in flight means code whose fetch takes longer than the gap between
    // interrupts would never execute at all - found as a livelock in
    // tb_interrupt_stress.v: every return from the handler re-missed on
    // the main loop's line, the next tick aborted that fill, and so on
    // forever. (The original rule could livelock too: a trap squashes
    // the instruction in EX, so a tick right after every return also
    // blocks all progress.) progress_hold closes this: after an mret,
    // no trap is taken until one instruction of the interrupted code has
    // executed. Its fetch is never aborted, since no trap can occur
    // during it. When the period leaves room for the handler plus one
    // flash transaction this costs nothing - the next tick arrives after
    // that first instruction anyway.
    reg progress_hold;
    always @(posedge clk) begin
        if (reset)
            progress_hold <= 1'b0;
        else if (id_ex_is_mret && !trap_taken)
            progress_hold <= 1'b1;                      // mret executes
        else if (id_ex_valid)
            progress_hold <= 1'b0;                      // first resumed
                                                          // instruction ran
    end

    assign trap_taken = mstatus_mie && mie_mtie && timer_pending && !progress_hold;

    always @(posedge clk) begin
        if (reset) begin
            mstatus <= 32'd0;
            mie     <= 32'd0;
            mtvec   <= 32'd0;
            mepc    <= 32'd0;
            mcause  <= 32'd0;
        end else if (trap_taken) begin
            // Takes priority over whatever's in EX this cycle -
            // including if it happens to be MRET or a CSR write
            // itself (see the EX/MEM register below for why that
            // instruction's OTHER effects are also suppressed this
            // cycle, not just here): from the interrupted program's
            // perspective, that instruction hasn't executed yet: it
            // will run again, from scratch, once MRET returns to
            // mepc.
            mepc       <= next_exec_pc;
            mcause     <= 32'h8000_0007;   // machine timer interrupt
            mstatus[7] <= mstatus[3];       // MPIE = old MIE
            mstatus[3] <= 1'b0;             // disable interrupts in the handler
        end else if (id_ex_is_mret) begin
            mstatus[3] <= mstatus[7];   // MIE = old MPIE
            mstatus[7] <= 1'b1;          // MPIE = 1, per spec
        end else if (id_ex_is_csr) begin
            case (csr_addr)
                12'h300: begin
                    mstatus[3] <= csr_new_value[3];
                    mstatus[7] <= csr_new_value[7];
                end
                12'h304: mie[7] <= csr_new_value[7];
                12'h305: mtvec  <= csr_new_value;
                12'h341: mepc   <= csr_new_value;
                12'h342: mcause <= csr_new_value;
                default: ; // mip is read-only from software;
                           // unrecognized addresses are ignored
            endcase
        end
    end

    assign ex_flush = ex_is_jalr | ex_branch_mispredicted | id_ex_is_mret | trap_taken;
    assign ex_correct_target = trap_taken       ? mtvec :
                                id_ex_is_mret    ? mepc :
                                ex_is_jalr       ? (ex_alu_result & ~32'd1) :
                                ex_branch_taken  ? (id_ex_pc + id_ex_imm_b) :
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

    wire [31:0] ex_result = id_ex_lui    ? id_ex_imm_u :
                             id_ex_auipc  ? (id_ex_pc + id_ex_imm_u) :
                             id_ex_jump   ? (id_ex_pc + 32'd4) :
                             id_ex_is_csr ? csr_read_value :
                             id_ex_is_mac ? mac_result :
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
            // Gated by !trap_taken - if this instruction is being
            // interrupted rather than allowed to complete, neither
            // its register write nor its memory write should commit;
            // it'll re-execute from scratch after MRET returns to
            // mepc. Everything else in the pipeline that resolves
            // this cycle (JALR/branch) is allowed to complete
            // normally even when flushed for OTHER reasons (younger
            // instructions get squashed, not this one) - interrupts
            // are the one case where the CURRENT EX instruction
            // itself must not commit.
            ex_mem_reg_write   <= id_ex_reg_write && !trap_taken;
            ex_mem_mem_write   <= id_ex_mem_write && !trap_taken;
            ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
        end
    end

    // ==================== MEM: Memory Access ====================
    // Data memory stays on-chip BRAM, as before - EXCEPT loads/stores
    // to six reserved memory-mapped addresses are diverted away from
    // dmem entirely, so they can't be misread as - or overwrite - real
    // data at whatever address the array happened to alias to:
    //   0xFFFFFF00 - cache lock control (write-only; see icache.v)
    //   0xFFFFFF04 - cycle counter (free-running; store resets to 0)
    //   0xFFFFFF08 - cache hit count
    //   0xFFFFFF0C - cache miss count (fills AND locked-line bypasses
    //                both count as a miss - both left the 1-cycle hit
    //                path)
    //   0xFFFFFF10 - encoder position (store resets to 0 - see
    //                quad_decoder.v for why this only clears the
    //                count, not the decoder's tracked a/b state)
    //   0xFFFFFF14 - encoder invalid-transition count (read-only
    //                diagnostic - nothing meaningful to reset it to
    //                independent of position)
    //   0xFFFFFF18 - PWM duty cycle (read/write - read returns the
    //                last value written)
    //   0xFFFFFF1C - timer compare value (read/write - interrupt
    //                fires, periodically, when the timer's free-
    //                running count reaches this)
    //   0xFFFFFF20 - timer pending/acknowledge (bit 0 readable; any
    //                store clears it - see timer.v for why this is a
    //                dedicated register rather than matching real
    //                CLINT's "rewrite the compare value" convention)
    //   0xFFFFFF24 - timer count (read-only diagnostic)
    //   0xFFFFFF28 - board LEDs, low 16 bits (read/write)
    //   0xFFFFFF2C - motor direction request, bit 0 (read/write)
    //   0xFFFFFF30 - UART transmit: a store sends the low 8 bits;
    //                a load returns busy in bit 0 (poll until 0
    //                before storing - a store while busy is dropped)
    //   0xFFFFFF34 - cache control, bit 0 = disable (read/write). 1
    //                sends every fetch straight to flash: Configuration
    //                1 (no cache) at runtime, for the three-way
    //                comparison. Resets to 0 (cache on).
    //   0xFFFFFF38 - encoder mode, bit 0 = single-channel (read/write):
    //                count B edges only, sign from the motor-direction
    //                register (see quad_decoder.v). Resets to 0
    //                (quadrature).
    // A store to either counter address resets BOTH hit and miss
    // together, since they're only meaningful as a pair.

    localparam [31:0] MMIO_CYCLE_ADDR        = 32'hFFFFFF04;
    localparam [31:0] MMIO_HIT_ADDR          = 32'hFFFFFF08;
    localparam [31:0] MMIO_MISS_ADDR         = 32'hFFFFFF0C;
    localparam [31:0] MMIO_TIMER_CMP_ADDR    = 32'hFFFFFF1C;
    localparam [31:0] MMIO_TIMER_ACK_ADDR    = 32'hFFFFFF20;
    localparam [31:0] MMIO_TIMER_COUNT_ADDR  = 32'hFFFFFF24;
    localparam [31:0] MMIO_LED_ADDR          = 32'hFFFFFF28;
    localparam [31:0] MMIO_MOTOR_DIR_ADDR    = 32'hFFFFFF2C;
    localparam [31:0] MMIO_UART_ADDR         = 32'hFFFFFF30;
    localparam [31:0] MMIO_CACHE_CTRL_ADDR   = 32'hFFFFFF34;
    localparam [31:0] MMIO_ENC_MODE_ADDR     = 32'hFFFFFF38;

    wire is_mmio_lock_write    = ex_mem_mem_write && (ex_mem_alu_result == MMIO_LOCK_ADDR);
    wire is_mmio_cycle_addr    = (ex_mem_alu_result == MMIO_CYCLE_ADDR);
    wire is_mmio_hit_addr      = (ex_mem_alu_result == MMIO_HIT_ADDR);
    wire is_mmio_miss_addr     = (ex_mem_alu_result == MMIO_MISS_ADDR);
    wire is_mmio_enc_pos_addr  = (ex_mem_alu_result == MMIO_ENC_POS_ADDR);
    wire is_mmio_enc_err_addr  = (ex_mem_alu_result == MMIO_ENC_ERR_ADDR);
    wire is_mmio_pwm_addr      = (ex_mem_alu_result == MMIO_PWM_ADDR);
    wire is_mmio_timer_cmp     = (ex_mem_alu_result == MMIO_TIMER_CMP_ADDR);
    wire is_mmio_timer_ack     = (ex_mem_alu_result == MMIO_TIMER_ACK_ADDR);
    wire is_mmio_timer_count   = (ex_mem_alu_result == MMIO_TIMER_COUNT_ADDR);
    wire is_mmio_led           = (ex_mem_alu_result == MMIO_LED_ADDR);
    wire is_mmio_motor_dir     = (ex_mem_alu_result == MMIO_MOTOR_DIR_ADDR);
    wire is_mmio_uart          = (ex_mem_alu_result == MMIO_UART_ADDR);
    wire is_mmio_cache_ctrl    = (ex_mem_alu_result == MMIO_CACHE_CTRL_ADDR);
    wire is_mmio_enc_mode      = (ex_mem_alu_result == MMIO_ENC_MODE_ADDR);
    wire is_mmio_addr          = is_mmio_lock_write || is_mmio_cycle_addr ||
                                  is_mmio_hit_addr || is_mmio_miss_addr ||
                                  is_mmio_enc_pos_addr || is_mmio_enc_err_addr ||
                                  is_mmio_pwm_addr || is_mmio_timer_cmp ||
                                  is_mmio_timer_ack || is_mmio_timer_count ||
                                  is_mmio_led || is_mmio_motor_dir ||
                                  is_mmio_uart || is_mmio_cache_ctrl ||
                                  is_mmio_enc_mode;

    wire dmem_write_en = ex_mem_mem_write && !is_mmio_addr;

    assign lock_cmd          = is_mmio_lock_write;
    assign lock_set          = ex_mem_rs2_data[31];
    assign lock_addr         = ex_mem_rs2_data[23:0];
    assign stats_reset       = ex_mem_mem_write && (is_mmio_hit_addr || is_mmio_miss_addr);
    assign enc_position_clear = ex_mem_mem_write && is_mmio_enc_pos_addr;

    reg [31:0] cycle_count;
    always @(posedge clk) begin
        if (reset || (ex_mem_mem_write && is_mmio_cycle_addr))
            cycle_count <= 32'd0;
        else
            cycle_count <= cycle_count + 32'd1;
    end

    always @(posedge clk) begin
        if (reset)
            pwm_duty_cycle <= 32'd0;
        else if (ex_mem_mem_write && is_mmio_pwm_addr)
            pwm_duty_cycle <= ex_mem_rs2_data;
    end

    reg [31:0] timer_compare;
    always @(posedge clk) begin
        if (reset)
            timer_compare <= 32'd0;
        else if (ex_mem_mem_write && is_mmio_timer_cmp)
            timer_compare <= ex_mem_rs2_data;
    end

    always @(posedge clk) begin
        if (reset) begin
            led           <= 16'd0;
            motor_dir     <= 1'b0;
            cache_disable <= 1'b0;
            enc_single_channel <= 1'b0;
        end else if (ex_mem_mem_write) begin
            if (is_mmio_led)        led           <= ex_mem_rs2_data[15:0];
            if (is_mmio_motor_dir)  motor_dir     <= ex_mem_rs2_data[0];
            if (is_mmio_cache_ctrl) cache_disable <= ex_mem_rs2_data[0];
            if (is_mmio_enc_mode)   enc_single_channel <= ex_mem_rs2_data[0];
        end
    end

    wire [31:0] timer_count;

    timer timer_inst (
        .clk(clk),
        .reset(reset),
        .compare(timer_compare),
        .clear_pending(ex_mem_mem_write && is_mmio_timer_ack),
        .restart(ex_mem_mem_write && is_mmio_timer_cmp),
        .count(timer_count),
        .pending(timer_pending)
    );

    wire uart_busy;

    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) uart_tx_inst (
        .clk(clk),
        .reset(reset),
        .data(ex_mem_rs2_data[7:0]),
        .start(ex_mem_mem_write && is_mmio_uart),
        .tx(uart_tx),
        .busy(uart_busy)
    );

    wire [31:0] mem_dmem_read_data;
    wire [31:0] mem_read_data_muxed =
        is_mmio_cycle_addr    ? cycle_count :
        is_mmio_hit_addr      ? hit_count :
        is_mmio_miss_addr     ? miss_count :
        is_mmio_enc_pos_addr  ? enc_position :
        is_mmio_enc_err_addr  ? enc_error_count :
        is_mmio_pwm_addr      ? pwm_duty_cycle :
        is_mmio_timer_cmp     ? timer_compare :
        is_mmio_timer_ack     ? {31'd0, timer_pending} :
        is_mmio_timer_count   ? timer_count :
        is_mmio_led           ? {16'd0, led} :
        is_mmio_motor_dir     ? {31'd0, motor_dir} :
        is_mmio_uart          ? {31'd0, uart_busy} :
        is_mmio_cache_ctrl    ? {31'd0, cache_disable} :
        is_mmio_enc_mode      ? {31'd0, enc_single_channel} :
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

    // MAC reads id_rd as an implicit third source (the accumulator) -
    // a preceding load's destination landing there is just as real a
    // hazard as it landing in rs1/rs2, so it needs the same stall,
    // gated on id_is_mac so ordinary instructions (which never read
    // their own rd) aren't affected.
    assign load_use_hazard = id_ex_mem_to_reg && (id_ex_rd != 5'd0) &&
                              ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2) ||
                               (id_is_mac && id_ex_rd == id_rd));

endmodule
