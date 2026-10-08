#!/usr/bin/env python3
"""Static invariant checks for CORE/m2m-rom/m2m-rom.asm.

Companion to check_osm_menu.py. Two checks:

1. Carry pairing.  On QNICE only ADD / ADDC / SUB / SUBC and SHL / SHR write the
   Carry flag; MOVE does not (M2M/QNICE/vhdl/qnice_cpu.vhd: var_C defaults to
   SR(2) and is only overwritten for those opcodes).  A 32-bit addition is
   therefore written as

       ADD   <lo>, @low_word
       ADDC  0,    @high_word

   and a MOVE may sit between the two.  Per-drive indexing between the two
   instructions is easily written as an ADD (address arithmetic), and that ADD
   silently overwrites the carry, so the high word stops incrementing.  In the
   ADF write-back every chunk past a 64 KB boundary would then land 64 KB too
   low in the image file: silent image corruption.

   The check: for every ADDC / SUBC, walk back to the nearest instruction that
   writes Carry and require that it addresses the same storage class as the
   consumer - memory with memory, register with register.  Address arithmetic
   always lands in a register while the 32-bit idiom works on memory (or the
   other way round for a register-only 32-bit value), so a mismatch is exactly
   the "a stray ADD ate the carry" signature.

2. Per-drive table width.  The tables that map a drive to its device, file
   handle, menu group and menu lines must each have exactly ADF_DRIVES entries,
   because every loop over them is bounded by that constant.

Run it after any change to m2m-rom.asm; the repository root is found from the
location of this file. The last line is "all checks passed", or the failures
with a non-zero exit status.

Usage: python3 tools/check_firmware.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM = os.path.join(ROOT, "CORE", "m2m-rom", "m2m-rom.asm")

FAILED = []


def fail(msg):
    FAILED.append(msg)
    print("FAIL: %s" % msg)


# opcodes that write the Carry flag
C_WRITERS = {"ADD", "ADDC", "SUB", "SUBC", "SHL", "SHR"}
# opcodes that consume the Carry flag as an input operand
C_READERS = {"ADDC", "SUBC"}
# a branch or a label ends the straight-line region we may reason about
BRANCH = {"RBRA", "RSUB", "ABRA", "ASUB", "RET", "SYSCALL"}


def parse(path):
    """Return [(lineno, label, opcode, operands, raw)] for executable lines."""
    out = []
    with open(path, encoding="utf-8") as handle:
        for no, raw in enumerate(handle, 1):
            line = raw.rstrip("\n")
            code = line.split(";", 1)[0].rstrip()
            if not code.strip():
                continue
            label = ""
            body = code
            if code[:1] not in (" ", "\t"):
                parts = code.split(None, 1)
                label = parts[0]
                body = parts[1] if len(parts) > 1 else ""
            body = body.strip()
            if not body:
                out.append((no, label, "", "", line))
                continue
            parts = body.split(None, 1)
            opcode = parts[0].upper()
            operands = parts[1].strip() if len(parts) > 1 else ""
            out.append((no, label, opcode, operands, line))
    return out


def storage_class(operand):
    """'mem' for an @-reference, 'reg' for a bare register, None otherwise."""
    operand = operand.strip()
    if operand.startswith("@"):
        return "mem"
    if re.fullmatch(r"R\d+|SP|SR|PC", operand, re.IGNORECASE):
        return "reg"
    return None


def destination(operands):
    """The destination operand of a two-operand instruction."""
    if "," not in operands:
        return ""
    return operands.split(",", 1)[1].strip()


def check_carry(prog):
    checked = 0
    for index, (no, _label, opcode, operands, raw) in enumerate(prog):
        if opcode not in C_READERS:
            continue
        dst_class = storage_class(destination(operands))
        if dst_class is None:
            continue
        # walk back to the nearest Carry writer, stopping at a label or a branch
        producer = None
        for back in range(index - 1, -1, -1):
            b_no, b_label, b_op, b_ops, b_raw = prog[back]
            if b_op in BRANCH or b_op.startswith("SYSCALL"):
                break
            # a direct write to SR sets the flags by hand and is deliberate
            if destination(b_ops).upper() == "SR":
                producer = ("SR", b_no, b_raw)
                break
            if b_op in C_WRITERS:
                producer = (b_op, b_no, b_raw)
                break
            # a label means control can also enter here, so nothing before it
            # is guaranteed to have run - but the labelled instruction itself
            # is, which is why it is examined above before we stop.
            if b_label:
                break
        checked += 1
        if producer is None:
            fail("line %d: %s consumes a carry with no producer in its "
                 "straight-line region\n      %s" % (no, opcode, raw.strip()))
            continue
        p_op, p_no, p_raw = producer
        if p_op == "SR":
            continue
        src_class = storage_class(destination(p_ops_of(prog, p_no)))
        if src_class is None:
            continue
        if src_class != dst_class:
            fail("line %d: %s writes %s but its carry comes from line %d which "
                 "writes %s - a stray address ADD very likely ate the carry\n"
                 "      producer: %s\n      consumer: %s"
                 % (no, opcode, dst_class, p_no, src_class,
                    p_raw.strip(), raw.strip()))
    print("carry pairing: %d ADDC/SUBC sites checked" % checked)


def p_ops_of(prog, lineno):
    for no, _label, _op, ops, _raw in prog:
        if no == lineno:
            return ops
    return ""


def check_tables(text):
    match = re.search(r"^ADF_DRIVES\s+\.EQU\s+(\d+)", text, re.M)
    if not match:
        fail("m2m-rom.asm has no ADF_DRIVES constant")
        return
    drives = int(match.group(1))
    tables = ["ADF_DEV_TAB", "ADF_FDH_TAB", "ADF_GRP_TAB",
              "ADF_MNT_LN_TAB", "ADF_HW_LN_TAB"]
    for name in tables:
        row = re.search(r"^%s\s+\.DW\s+(.*)$" % name, text, re.M)
        if not row:
            fail("m2m-rom.asm has no table %s" % name)
            continue
        entries = [e for e in row.group(1).split(",") if e.strip()]
        if len(entries) != drives:
            fail("%s has %d entries, ADF_DRIVES is %d"
                 % (name, len(entries), drives))
    # the per-drive scalar arrays must be ADF_DRIVES words wide
    for name in ["ADF_FDH_VALID", "ADF_SD_SLOT", "ADF_MOUNT_SEEN",
                 "ADF_FL_STATE", "ADF_FL_REMAIN", "ADF_FL_BADDR_LO",
                 "ADF_FL_BADDR_HI"]:
        row = re.search(r"^%s\s+\.BLOCK\s+(\S+)" % name, text, re.M)
        if not row:
            fail("m2m-rom.asm has no per-drive variable %s" % name)
        elif row.group(1) != "ADF_DRIVES":
            fail("%s is .BLOCK %s, expected .BLOCK ADF_DRIVES"
                 % (name, row.group(1)))
    print("per-drive tables and arrays: %d tables + 7 arrays, ADF_DRIVES = %d"
          % (len(tables), drives))


def main():
    if not os.path.exists(ASM):
        print("cannot find %s" % ASM)
        return 2
    with open(ASM, encoding="utf-8") as handle:
        text = handle.read()
    prog = parse(ASM)
    check_carry(prog)
    check_tables(text)
    if FAILED:
        print("\n%d check(s) failed" % len(FAILED))
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
