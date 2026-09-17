#!/usr/bin/env python3
"""
iss.py
Reference RV32I instruction set simulator, written independently from
cpu.v to serve as a differential co-simulation target: run the same
program through both, compare state after every retired instruction,
and the first point of disagreement is a real bug in one of them.

Deliberately mirrors this core's actual architecture rather than an
idealized unified-memory RISC-V machine:
  - Separate imem/dmem, each its own byte array (this core is
    Harvard-style, not von Neumann - see PROJECT.md). Fetches only
    ever read imem; loads/stores only ever touch dmem.
  - Only the instructions actually implemented in control.v: R-type,
    I-type ALU ops, loads/stores, branches, JAL/JALR, LUI/AUIPC.
    Anything else (including FENCE) is a no-op, matching control.v's
    safe default for an unrecognized opcode.

Usage:
    py iss.py <hexfile> [--cycles N] [--trace out.trace]
"""

import sys
import argparse


def sign_extend(value, bits):
    """Interpret the low `bits` bits of value as a signed integer."""
    value &= (1 << bits) - 1
    if value & (1 << (bits - 1)):
        value -= (1 << bits)
    return value


def to_u32(value):
    return value & 0xFFFFFFFF


class RV32ISS:
    MEM_SIZE = 8192  # bytes, matches imem.v/dmem.v

    def __init__(self):
        self.regs = [0] * 32
        self.pc = 0
        self.imem = bytearray(self.MEM_SIZE)
        self.dmem = bytearray(self.MEM_SIZE)

    def load_hex(self, path):
        """Parses objcopy -O verilog output: '@addr' lines set the
        load address, subsequent lines are space-separated hex bytes."""
        addr = 0
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if line.startswith('@'):
                    addr = int(line[1:], 16)
                    continue
                for byte_str in line.split():
                    byte_val = int(byte_str, 16)
                    self.imem[addr] = byte_val
                    self.dmem[addr] = byte_val
                    addr += 1

    def read_reg(self, n):
        return 0 if n == 0 else self.regs[n]

    def write_reg(self, n, value):
        if n != 0:
            self.regs[n] = to_u32(value)

    def fetch(self):
        a = self.pc
        return (self.imem[a] | (self.imem[a + 1] << 8) |
                (self.imem[a + 2] << 16) | (self.imem[a + 3] << 24))

    # ---- dmem access, mirroring dmem.v's funct3-driven width/sign ----

    def dmem_read(self, addr, funct3):
        width = funct3 & 0b011
        unsigned = bool(funct3 & 0b100)
        if width == 0b00:  # byte
            v = self.dmem[addr]
            return v if unsigned else sign_extend(v, 8)
        elif width == 0b01:  # halfword
            v = self.dmem[addr] | (self.dmem[addr + 1] << 8)
            return v if unsigned else sign_extend(v, 16)
        elif width == 0b10:  # word
            return (self.dmem[addr] | (self.dmem[addr + 1] << 8) |
                    (self.dmem[addr + 2] << 16) | (self.dmem[addr + 3] << 24))
        return 0

    def dmem_write(self, addr, value, funct3):
        width = funct3 & 0b011
        value = to_u32(value)
        if width == 0b00:
            self.dmem[addr] = value & 0xFF
        elif width == 0b01:
            self.dmem[addr] = value & 0xFF
            self.dmem[addr + 1] = (value >> 8) & 0xFF
        elif width == 0b10:
            self.dmem[addr] = value & 0xFF
            self.dmem[addr + 1] = (value >> 8) & 0xFF
            self.dmem[addr + 2] = (value >> 16) & 0xFF
            self.dmem[addr + 3] = (value >> 24) & 0xFF

    # ---- one instruction, returning a dict describing what happened ----

    def step(self):
        instr = self.fetch()
        pc_before = self.pc

        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        funct7 = (instr >> 25) & 0x7F

        imm_i = sign_extend(instr >> 20, 12)
        imm_s = sign_extend(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_b = sign_extend(
            (((instr >> 31) & 1) << 12) | (((instr >> 7) & 1) << 11) |
            (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13)
        imm_u = instr & 0xFFFFF000
        imm_j = sign_extend(
            (((instr >> 31) & 1) << 20) | (((instr >> 12) & 0xFF) << 12) |
            (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21)

        rs1_v = self.read_reg(rs1)
        rs2_v = self.read_reg(rs2)

        result = {'pc': pc_before, 'instr': instr, 'reg_write': None,
                  'mem_write': None}
        next_pc = pc_before + 4

        if opcode == 0b0110011:  # R-type
            b = rs2_v
            result['reg_write'] = (rd, self._alu(funct3, funct7, rs1_v, b))
        elif opcode == 0b0010011:  # I-type ALU
            result['reg_write'] = (rd, self._alu(funct3, funct7, rs1_v, to_u32(imm_i), imm_op=True))
        elif opcode == 0b0000011:  # Load
            addr = to_u32(rs1_v + imm_i)
            result['reg_write'] = (rd, to_u32(self.dmem_read(addr, funct3)))
        elif opcode == 0b0100011:  # Store
            addr = to_u32(rs1_v + imm_s)
            self.dmem_write(addr, rs2_v, funct3)
            result['mem_write'] = (addr, funct3, to_u32(rs2_v))
        elif opcode == 0b1100011:  # Branch
            taken = self._branch_taken(funct3, rs1_v, rs2_v)
            if taken:
                next_pc = to_u32(pc_before + imm_b)
        elif opcode == 0b1101111:  # JAL
            result['reg_write'] = (rd, to_u32(pc_before + 4))
            next_pc = to_u32(pc_before + imm_j)
        elif opcode == 0b1100111:  # JALR
            result['reg_write'] = (rd, to_u32(pc_before + 4))
            next_pc = to_u32(rs1_v + imm_i) & ~1
        elif opcode == 0b0110111:  # LUI
            result['reg_write'] = (rd, to_u32(imm_u))
        elif opcode == 0b0010111:  # AUIPC
            result['reg_write'] = (rd, to_u32(pc_before + imm_u))
        # else: unrecognized opcode (including FENCE, 0b0001111) is a
        # no-op, matching control.v's default case

        if result['reg_write'] is not None:
            rd_num, rd_value = result['reg_write']
            self.write_reg(rd_num, rd_value)
            # Report the actual post-write value, not the raw computed
            # one - for rd=x0 these differ (the write is discarded),
            # and the real hardware's regfile always reads x0 as 0
            result['reg_write'] = (rd_num, self.read_reg(rd_num))

        self.pc = next_pc
        return result

    def _alu(self, funct3, funct7, a, b, imm_op=False):
        a = to_u32(a)
        b = to_u32(b)
        alt = (funct7 == 0b0100000)
        if funct3 == 0b000:
            return to_u32(a - b) if (alt and not imm_op) else to_u32(a + b)
        elif funct3 == 0b001:
            return to_u32(a << (b & 0x1F))
        elif funct3 == 0b010:
            return 1 if sign_extend(a, 32) < sign_extend(b, 32) else 0
        elif funct3 == 0b011:
            return 1 if a < b else 0
        elif funct3 == 0b100:
            return a ^ b
        elif funct3 == 0b101:
            if alt:
                return to_u32(sign_extend(a, 32) >> (b & 0x1F))
            return a >> (b & 0x1F)
        elif funct3 == 0b110:
            return a | b
        elif funct3 == 0b111:
            return a & b
        return 0

    def _branch_taken(self, funct3, a, b):
        a_s, b_s = sign_extend(a, 32), sign_extend(b, 32)
        au, bu = to_u32(a), to_u32(b)
        if funct3 == 0b000:  return a == b          # BEQ
        if funct3 == 0b001:  return a != b          # BNE
        if funct3 == 0b100:  return a_s < b_s       # BLT
        if funct3 == 0b101:  return a_s >= b_s      # BGE
        if funct3 == 0b110:  return au < bu         # BLTU
        if funct3 == 0b111:  return au >= bu        # BGEU
        return False


def main():
    parser = argparse.ArgumentParser(description="RV32I reference ISS")
    parser.add_argument("hexfile")
    parser.add_argument("--cycles", type=int, default=1000)
    parser.add_argument("--trace", default=None)
    args = parser.parse_args()

    iss = RV32ISS()
    iss.load_hex(args.hexfile)

    trace_lines = []
    for _ in range(args.cycles):
        r = iss.step()
        rw = f"{r['reg_write'][0]}:{r['reg_write'][1]:08x}" if r['reg_write'] else "-"
        mw = f"{r['mem_write'][0]:08x}:{r['mem_write'][2]:08x}" if r['mem_write'] else "-"
        trace_lines.append(f"PC={r['pc']:08x} INSTR={r['instr']:08x} REG={rw} MEM={mw}")

    if args.trace:
        with open(args.trace, "w") as f:
            f.write("\n".join(trace_lines) + "\n")
    else:
        print("\n".join(trace_lines))


if __name__ == "__main__":
    main()
