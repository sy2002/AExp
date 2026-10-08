// tb_blitter_freeze.v - verification of upstream Minimig PR 236 (MiSTer commit
// 5578afd, AExp cherry-pick eea9d74): the blitter freezes when BLTCON1 is
// written while busy, the OLD mode is a fill (IFE or EFE, line mode off) with
// bltcon0[9:8] = 01 (USEC off, USED on) and the NEW data clears LINE, IFE and
// EFE; a BLTSIZE write (BLTSIZH only with ecs) or reset releases it.
//
// Two blitters run side by side on identical stimulus:
//   OLD = fa40334:rtl/agnus_blitter.v, module renamed agnus_blitter_old
//   NEW = rtl/agnus_blitter.v (or a mutant of it, see run_tb_blitter_freeze.sh)
// The submodules (adrgen, barrelshifter, fill, minterm) are shared.
//
// Bus model, faithful to rtl/agnus.v + rtl/gary.v + rtl/amiga_clk.v:
//   - clk7_en = 1 of 4 clk; cck toggles every clk7 cycle; blitter clkena = cck
//   - Agnus grants the blitter combinationally in the same cycle (ack_blt =
//     req_blt when no higher channel; the higher channels are modelled by
//     enadma stalls driven from an LFSR)
//   - reg_address_in = blitter reg_address_out while it owns the bus, the CPU
//     register address on a CPU access, 8'hFF when idle
//   - data_in = RAM data during DMA, CPU data on CPU writes, 16'hFFFF on CPU
//     reads (gary.v custom_data_in)
//   - CPU accesses strobe exactly one clk7 cycle with cck = 0
//     (minimig_m68k_bridge: enable = ~l_as & ~l_dtack & ~cck); copper writes
//     use a cck = 1 slot in which the blitter has no DMA enable
//
// Every scenario prints one PASS/FAIL line per sub-case and a summary line
// per scenario; the last line is RESULT: PASS or RESULT: FAIL.
//
// OLD is fa40334, the Minimig fork's baseline before the upstream ports. The
// S2 "FREEZE OLD" line is a red control: the pre-port blitter must not freeze.
//
// Run: CORE/sim/minimig/run_tb_blitter_freeze.sh (MUTANTS=0 for the bench
// alone, a few seconds; the default also runs the 19-mutant matrix).
`timescale 1ns/1ps

module blit_harness #(parameter OLD = 0) (
  input  wire        clk,
  input  wire        clk7_en,
  input  wire        reset,
  input  wire        ecs,
  input  wire        cck,
  input  wire        enadma,
  input  wire        bus_stb,
  input  wire [8:1]  bus_reg,
  input  wire [15:0] bus_dat,
  input  wire [31:0] cyc,
  output wire        reqdma,
  output wire        ackdma,
  output wire        we,
  output wire        zero,
  output wire        busy,
  output wire        int3,
  output wire [15:0] data_out,
  output wire [20:1] address_out,
  output wire [8:1]  reg_address_out,
  output wire [4:0]  state,
  output wire [15:0] con0,
  output wire [15:0] con1
);
  reg [15:0] mem [0:65535];

  assign ackdma = reqdma;
  wire [8:1]  reg_address_in = ackdma ? reg_address_out : (bus_stb ? bus_reg : 8'hFF);
  wire [15:0] data_in        = ackdma ? mem[address_out[16:1]] : (bus_stb ? bus_dat : 16'hFFFF);

  generate
    if (OLD) begin : g
      agnus_blitter_old u (
        .clk(clk), .clk7_en(clk7_en), .reset(reset), .ecs(ecs), .clkena(cck), .enadma(enadma),
        .reqdma(reqdma), .ackdma(ackdma), .we(we), .zero(zero), .busy(busy), .int3(int3),
        .data_in(data_in), .data_out(data_out), .reg_address_in(reg_address_in),
        .address_out(address_out), .reg_address_out(reg_address_out));
    end else begin : g
      agnus_blitter u (
        .clk(clk), .clk7_en(clk7_en), .reset(reset), .ecs(ecs), .clkena(cck), .enadma(enadma),
        .reqdma(reqdma), .ackdma(ackdma), .we(we), .zero(zero), .busy(busy), .int3(int3),
        .data_in(data_in), .data_out(data_out), .reg_address_in(reg_address_in),
        .address_out(address_out), .reg_address_out(reg_address_out));
    end
  endgenerate
  assign state = g.u.blt_state;
  assign con0  = g.u.bltcon0;
  assign con1  = g.u.bltcon1;

  // RAM image: words $3000..$37FF are a sparse "outline" region for fills
  function [15:0] pat(input integer i);
    begin
      if (i >= 32'h3000 && i < 32'h3800)
        pat = ((i % 5) == 0) ? (16'h0001 << (i % 16)) : 16'h0000;
      else
        pat = (i * 40503) ^ (i >> 3) ^ 16'h5A5A;
    end
  endfunction

  integer k;
  initial for (k = 0; k < 65536; k = k + 1) mem[k] = pat(k);

  // D-channel write log + DMA / interrupt counters
  integer dcount = 0;
  integer acount = 0;
  integer icount = 0;
  reg [20:1] dl_addr [0:8191];
  reg [15:0] dl_data [0:8191];
  reg [31:0] dl_cyc  [0:8191];
  always @(posedge clk) if (clk7_en) begin
    if (we) begin
      dl_addr[dcount % 8192] <= address_out;
      dl_data[dcount % 8192] <= data_out;
      dl_cyc[dcount % 8192]  <= cyc;
      mem[address_out[16:1]] <= data_out;
      dcount <= dcount + 1;
    end
    if (ackdma) acount <= acount + 1;
    if (int3)   icount <= icount + 1;
  end
endmodule

module tb_blitter_freeze;
  // register byte addresses
  localparam [8:0] BLTCON0 = 9'h040, BLTCON1 = 9'h042, BLTAFWM = 9'h044, BLTALWM = 9'h046,
                   BLTCPTH = 9'h048, BLTBPTH = 9'h04C, BLTAPTH = 9'h050, BLTAPTL = 9'h052,
                   BLTDPTH = 9'h054, BLTDPTL = 9'h056, BLTSIZE = 9'h058, BLTSIZV = 9'h05C,
                   BLTSIZH = 9'h05E, BLTCMOD = 9'h060, BLTBMOD = 9'h062, BLTAMOD = 9'h064,
                   BLTDMOD = 9'h066, BLTCDAT = 9'h070, BLTBDAT = 9'h072, BLTADAT = 9'h074;
  localparam [4:0] ST_IDLE = 5'b00000, ST_INIT = 5'b00001, ST_FROZEN = 5'b11111;
  localparam integer TMO = 40000;

  // ---------------------------------------------------------------- clocks
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg [1:0]  ph  = 2'd0;
  wire       clk7_en = (ph == 2'd3);
  reg        cck = 1'b1;
  reg [31:0] cyc = 0;
  always @(posedge clk) begin
    ph <= ph + 2'd1;
    if (clk7_en) begin
      cck <= ~cck;
      cyc <= cyc + 1;
    end
  end

  // ------------------------------------------------------------- stimulus
  reg        reset_r   = 1'b1;
  reg        ecs_r     = 1'b0;
  reg        blten     = 1'b1;
  reg        stall_en  = 1'b0;
  reg        stall     = 1'b0;
  reg        cop_cycle = 1'b0;
  reg        stb       = 1'b0;
  reg [1:0]  stb_sel   = 2'b11;   // bit0 = OLD, bit1 = NEW
  reg [8:1]  bus_reg   = 8'hFF;
  reg [15:0] bus_dat   = 16'hFFFF;
  reg [15:0] lfsr      = 16'hACE1;
  wire       enadma    = blten & ~stall & ~cop_cycle;

  always @(negedge clk) if (ph == 2'd3) begin
    lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    stall <= stall_en & ((lfsr[2:0] == 3'd0) | (lfsr[2:0] == 3'd5));
  end

  // ------------------------------------------------------------ the DUTs
  wire        o_req, o_ack, o_we, o_zero, o_busy, o_int3;
  wire [15:0] o_dout, o_con0, o_con1;
  wire [20:1] o_addr;
  wire [8:1]  o_rego;
  wire [4:0]  o_st;
  wire        n_req, n_ack, n_we, n_zero, n_busy, n_int3;
  wire [15:0] n_dout, n_con0, n_con1;
  wire [20:1] n_addr;
  wire [8:1]  n_rego;
  wire [4:0]  n_st;

  blit_harness #(.OLD(1)) h_old (
    .clk(clk), .clk7_en(clk7_en), .reset(reset_r), .ecs(ecs_r), .cck(cck), .enadma(enadma),
    .bus_stb(stb & stb_sel[0]), .bus_reg(bus_reg), .bus_dat(bus_dat), .cyc(cyc),
    .reqdma(o_req), .ackdma(o_ack), .we(o_we), .zero(o_zero), .busy(o_busy), .int3(o_int3),
    .data_out(o_dout), .address_out(o_addr), .reg_address_out(o_rego), .state(o_st),
    .con0(o_con0), .con1(o_con1));

  blit_harness #(.OLD(0)) h_new (
    .clk(clk), .clk7_en(clk7_en), .reset(reset_r), .ecs(ecs_r), .cck(cck), .enadma(enadma),
    .bus_stb(stb & stb_sel[1]), .bus_reg(bus_reg), .bus_dat(bus_dat), .cyc(cyc),
    .reqdma(n_req), .ackdma(n_ack), .we(n_we), .zero(n_zero), .busy(n_busy), .int3(n_int3),
    .data_out(n_dout), .address_out(n_addr), .reg_address_out(n_rego), .state(n_st),
    .con0(n_con0), .con1(n_con1));

  // ------------------------------------------------------ identity monitor
  reg     cmp_en = 1'b0;
  reg     zs_o = 1'b0, zs_n = 1'b0;   // zero flag comparable once both passed INIT
  integer cmp_cycles = 0;
  integer mism = 0;
  always @(posedge clk) if (clk7_en) begin
    if (o_st == ST_INIT && cck && enadma) zs_o <= 1'b1;
    if (n_st == ST_INIT && cck && enadma) zs_n <= 1'b1;
    if (cmp_en) begin
      cmp_cycles <= cmp_cycles + 1;
      if ({o_req, o_ack, o_we, o_busy, o_int3} !== {n_req, n_ack, n_we, n_busy, n_int3} ||
          o_st !== n_st || o_dout !== n_dout ||
          (o_ack && (o_addr !== n_addr || o_rego !== n_rego)) ||
          (zs_o && zs_n && o_zero !== n_zero)) begin
        mism <= mism + 1;
        if (mism < 6)
          $display("    MISMATCH cyc=%0d OLD{req%b ack%b we%b busy%b int%b st%b a%h d%h z%b} NEW{req%b ack%b we%b busy%b int%b st%b a%h d%h z%b}",
                   cyc, o_req, o_ack, o_we, o_busy, o_int3, o_st, o_addr, o_dout, o_zero,
                   n_req, n_ack, n_we, n_busy, n_int3, n_st, n_addr, n_dout, n_zero);
      end
    end
  end

  // white-box: clk7 cycles spent in BLT_FROZEN (5'b11111)
  integer frz_o = 0, frz_n = 0;
  always @(posedge clk) if (clk7_en) begin
    if (o_st === ST_FROZEN) frz_o <= frz_o + 1;
    if (n_st === ST_FROZEN) frz_n <= frz_n + 1;
  end

  // freeze window monitor
  reg     win_en = 1'b0;
  integer w_req_o, w_req_n, w_nb_n, w_nf_n, w_int_n, w_cyc;
  always @(posedge clk) if (clk7_en && win_en) begin
    w_cyc <= w_cyc + 1;
    if (o_req) w_req_o <= w_req_o + 1;
    if (n_req) w_req_n <= w_req_n + 1;
    if (n_busy !== 1'b1) w_nb_n <= w_nb_n + 1;
    if (n_st !== ST_FROZEN) w_nf_n <= w_nf_n + 1;
    if (n_int3) w_int_n <= w_int_n + 1;
  end
  task win_clear;
    begin w_req_o = 0; w_req_n = 0; w_nb_n = 0; w_nf_n = 0; w_int_n = 0; w_cyc = 0; end
  endtask

  // ------------------------------------------------------- bookkeeping
  integer fails [0:7];   // 1 S1, 2 S2-NEW, 3 S2-RED, 4 S3, 5 S4, 6 informational
  integer scen = 0;
  integer sub_fail = 0;
  reg [8*8:1]  sub_tag;
  reg [8*96:1] sub_desc;
  integer verbose = 0;

  task chk(input cond, input [8*96:1] msg);
    begin
      if (cond !== 1'b1) begin
        sub_fail = sub_fail + 1;
        fails[scen] = fails[scen] + 1;
        $display("    FAIL: %0s", msg);
      end else if (verbose)
        $display("    ok:   %0s", msg);
    end
  endtask

  // red control: cond is a freeze assertion evaluated on OLD; it must be false
  task red(input cond, input [8*96:1] msg);
    begin
      if (cond === 1'b1) begin
        sub_fail = sub_fail + 1;
        fails[3] = fails[3] + 1;
        $display("    FAIL: RED control broken, OLD satisfies: %0s", msg);
      end else
        $display("    RED control: OLD fails '%0s' as expected", msg);
    end
  endtask

  task sub_begin(input [8*8:1] tag, input [8*96:1] desc);
    begin sub_tag = tag; sub_desc = desc; sub_fail = 0; end
  endtask
  task sub_end;
    begin $display("  [%0s] %0s : %0s", sub_tag, sub_desc, (sub_fail == 0) ? "PASS" : "FAIL"); end
  endtask

  // ------------------------------------------------------- bus helpers
  reg [31:0] acc_cyc;
  reg        acc_busy_o, acc_busy_n;
  reg [15:0] acc_con0_n, acc_con1_n;
  reg [4:0]  acc_st_n;

  task tick;   // to the negedge before the next clk7_en edge
    begin
      @(negedge clk);
      while (ph != 2'd3) @(negedge clk);
    end
  endtask
  task ticks(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) tick; end
  endtask

  // one register access, strobed for exactly one clk7 cycle
  task bus_access(input [8:0] a, input [15:0] d, input cop, input [1:0] sel);
    begin
      tick;
      while (cck !== cop) tick;
      acc_cyc = cyc; acc_busy_o = o_busy; acc_busy_n = n_busy;
      acc_con0_n = n_con0; acc_con1_n = n_con1; acc_st_n = n_st;
      bus_reg = a[8:1]; bus_dat = d; stb_sel = sel; stb = 1'b1; cop_cycle = cop;
      @(negedge clk);
      stb = 1'b0; cop_cycle = 1'b0; bus_reg = 8'hFF; bus_dat = 16'hFFFF; stb_sel = 2'b11;
    end
  endtask
  task wr(input [8:0] a, input [15:0] d);          // 68000 move.w: 4 clk7 spacing
    begin bus_access(a, d, 1'b0, 2'b11); ticks(2); end
  endtask
  task wr_sel(input [8:0] a, input [15:0] d, input [1:0] sel);
    begin bus_access(a, d, 1'b0, sel); ticks(2); end
  endtask
  task rd(input [8:0] a);                          // 68000 read: data bus = $FFFF
    begin bus_access(a, 16'hFFFF, 1'b0, 2'b11); ticks(2); end
  endtask
  task cop(input [8:0] a, input [15:0] d);         // copper MOVE (cck = 1 slot)
    begin bus_access(a, d, 1'b1, 2'b11); ticks(2); end
  endtask

  task setptr(input [8:0] pth, input [20:0] b, input [1:0] sel);
    begin
      wr_sel(pth, {11'd0, b[20:16]}, sel);
      wr_sel(pth + 9'd2, b[15:0], sel);
    end
  endtask

  task prog(input [15:0] c0, input [15:0] c1, input [15:0] fwm, input [15:0] lwm,
            input [20:0] pa, input [20:0] pb, input [20:0] pc, input [20:0] pd,
            input [15:0] ma, input [15:0] mb, input [15:0] mc, input [15:0] md,
            input [15:0] da, input [15:0] db, input [15:0] dc);
    begin
      wr(BLTCON0, c0); wr(BLTCON1, c1); wr(BLTAFWM, fwm); wr(BLTALWM, lwm);
      setptr(BLTAPTH, pa, 2'b11); setptr(BLTBPTH, pb, 2'b11);
      setptr(BLTCPTH, pc, 2'b11); setptr(BLTDPTH, pd, 2'b11);
      wr(BLTAMOD, ma); wr(BLTBMOD, mb); wr(BLTCMOD, mc); wr(BLTDMOD, md);
      wr(BLTADAT, da); wr(BLTBDAT, db); wr(BLTCDAT, dc);
    end
  endtask

  // Bresenham line set-up (HRM recipe); c0base supplies USE + LF bits
  task prog_line(input [15:0] c0base, input [15:0] c1oct, input integer x1, input integer y1,
                 input integer dx, input integer dy, input [20:0] base);
    reg [20:0] pt;
    integer acc;
    begin
      acc = 4 * dy - 2 * dx;
      pt  = base + y1 * 40 + (x1 / 16) * 2;
      wr(BLTCON0, {x1[3:0], c0base[11:0]});
      wr(BLTCON1, c1oct | ((acc < 0) ? 16'h0040 : 16'h0000));
      wr(BLTAFWM, 16'hFFFF); wr(BLTALWM, 16'hFFFF);
      wr(BLTAPTH, 16'h0000); wr(BLTAPTL, acc[15:0]);
      setptr(BLTCPTH, pt, 2'b11); setptr(BLTDPTH, pt, 2'b11);
      wr(BLTBMOD, 4 * dy); wr(BLTAMOD, 4 * (dy - dx)); wr(BLTCMOD, 40); wr(BLTDMOD, 40);
      wr(BLTADAT, 16'h8000); wr(BLTBDAT, 16'hFFFF);
    end
  endtask

  task do_reset;
    begin
      tick; reset_r = 1'b1; ticks(4);
      reset_r = 1'b0; zs_o = 1'b0; zs_n = 1'b0; tick;
    end
  endtask

  task wait_done(input [1:0] sel, output reg ok);
    integer t;
    begin
      ok = 1'b0; t = 0;
      while (!ok && t < TMO) begin
        tick; t = t + 1;
        if ((!sel[0] || (o_busy === 1'b0 && o_st === ST_IDLE)) &&
            (!sel[1] || (n_busy === 1'b0 && n_st === ST_IDLE))) ok = 1'b1;
      end
    end
  endtask

  task wait_acks_new(input integer base, input integer n, output reg ok);
    integer t;
    begin
      ok = 1'b0; t = 0;
      while (!ok && t < TMO) begin
        tick; t = t + 1;
        if (h_new.acount - base >= n) ok = 1'b1;
      end
    end
  endtask

  // reference fill of one word (HRM rule, LSB first): returns {carry_out, data}
  function [16:0] fillw(input [15:0] in, input cin, input exclusive);
    integer b;
    reg c;
    reg [15:0] o;
    begin
      c = cin;
      for (b = 0; b < 16; b = b + 1) begin
        c = c ^ in[b];
        o[b] = exclusive ? c : (c | in[b]);
      end
      fillw = {c, o};
    end
  endfunction

  function [15:0] pat(input integer i);
    begin
      if (i >= 32'h3000 && i < 32'h3800)
        pat = ((i % 5) == 0) ? (16'h0001 << (i % 16)) : 16'h0000;
      else
        pat = (i * 40503) ^ (i >> 3) ^ 16'h5A5A;
    end
  endfunction

  // compare n D-log entries of OLD (from ob) and NEW (from nb)
  function integer dlog_diff(input integer ob, input integer nb, input integer n);
    integer i, d;
    begin
      d = 0;
      for (i = 0; i < n; i = i + 1)
        if (h_old.dl_addr[(ob + i) % 8192] !== h_new.dl_addr[(nb + i) % 8192] ||
            h_old.dl_data[(ob + i) % 8192] !== h_new.dl_data[(nb + i) % 8192]) d = d + 1;
      dlog_diff = d;
    end
  endfunction

  // ------------------------------------------------------- scenario state
  reg     ok;
  integer od0, nd0, oa0, na0, oi0, ni0, fz0, mm0, k, i, e, nd1, od1, oi1, ni1;
  integer t_rel, lat_n, lat_o;
  reg [20:1] P;
  reg [16:0] fr;
  reg        carry;
  integer    r, c, W, H, src, dst;

  // a mid-blit BLTCON1 access on a running blit that must not freeze NEW and
  // must leave NEW cycle-identical to OLD
  task s3_mid(input [8*8:1] tag, input [8*96:1] desc,
              input [15:0] c0, input [15:0] c1, input [15:0] size, input integer after,
              input [1:0] kind /* 0 wr, 1 rd, 2 clr.w (rd then wr) */, input [15:0] d,
              input [15:0] pre_mask, input [15:0] pre_val);
    begin
      sub_begin(tag, desc);
      do_reset;
      mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount;
      oi0 = h_old.icount; ni0 = h_new.icount;
      cmp_en = 1'b1;
      prog(c0, c1, 16'hFFFF, 16'hFFFF, 21'h06000, 21'h06400, 21'h06800, 21'h17000,
           16'h0000, 16'h0000, 16'h0000, 16'h0004, 16'hA55A, 16'h3C3C, 16'h0810);
      na0 = h_new.acount;
      wr(BLTSIZE, size);
      if (after > 0) begin
        wait_acks_new(na0, after, ok);
        chk(ok, "blit reached the trigger point (DMA count)");
      end else
        ticks(-after);
      if (kind == 2'd1 || kind == 2'd2) begin
        bus_access(BLTCON1, 16'hFFFF, 1'b0, 2'b11);
        chk(acc_busy_n === 1'b1, "trigger (CPU read) landed while NEW busy");
        chk((acc_con1_n & pre_mask) === pre_val, "old BLTCON1/BLTCON0 precondition at trigger");
        ticks(2);
      end
      if (kind == 2'd0 || kind == 2'd2) begin
        bus_access(BLTCON1, d, 1'b0, 2'b11);
        chk(acc_busy_n === 1'b1, "trigger (write) landed while NEW busy");
        if (kind == 2'd0)
          chk((acc_con1_n & pre_mask) === pre_val, "old BLTCON1 precondition at trigger");
        ticks(2);
      end
      wait_done(2'b11, ok);
      chk(ok, "both blits complete (busy low, FSM idle)");
      ticks(8);
      cmp_en = 1'b0;
      chk(frz_n == fz0, "NEW never entered BLT_FROZEN");
      chk(mism == mm0, "NEW cycle-identical to OLD");
      chk(h_new.icount - ni0 == 1 && h_old.icount - oi0 == 1, "exactly one int3 pulse each");
      chk(h_new.dcount - nd0 == h_old.dcount - od0, "same number of D writes");
      chk(dlog_diff(od0, nd0, h_new.dcount - nd0) == 0, "D write logs identical");
      sub_end;
    end
  endtask

  // common freeze trigger check (NEW freezes, OLD keeps running)
  task freeze_checks(input integer exp_total_old);
    begin
      chk(acc_busy_n === 1'b1, "trigger landed while NEW busy");
      chk(n_st === ST_FROZEN, "NEW enters BLT_FROZEN on the BLTCON1 write");
      red(o_st === ST_FROZEN, "enters BLT_FROZEN");
      k = h_new.dcount - nd0;
      win_clear; win_en = 1'b1;
      wait_done(2'b01, ok);
      ticks(300);
      chk(w_req_n == 0, "NEW: no DMA request while frozen");
      chk(w_nb_n == 0, "NEW: busy stays asserted while frozen");
      chk(w_nf_n == 0, "NEW: FSM holds BLT_FROZEN");
      chk(w_int_n == 0, "NEW: no int3 while frozen");
      chk(h_new.dcount - nd0 == k, "NEW: D write log stops growing");
      red(w_req_o == 0, "no DMA request after the write");
      red(!ok, "busy stays asserted (blit never completes)");
      red(h_old.dcount - od0 != exp_total_old, "D log stops growing (OLD wrote all D words)");
      $display("    info: NEW froze after %0d D writes; OLD made %0d more DMA cycles and wrote %0d of %0d D words",
               k, w_req_o, h_old.dcount - od0, exp_total_old);
    end
  endtask

  // ====================================================================
  initial begin
    for (i = 0; i < 8; i = i + 1) fails[i] = 0;
    if ($test$plusargs("VERBOSE")) verbose = 1;
    if ($test$plusargs("VCD")) begin $dumpfile("tb_blitter_freeze.vcd"); $dumpvars(0, tb_blitter_freeze); end
    $display("tb_blitter_freeze: OLD = fa40334 agnus_blitter, NEW = agnus_blitter under test");

    // ================================================================ S1
    scen = 1;
    do_reset;
    mm0 = mism; fz0 = frz_n;
    cmp_en = 1'b1;

    // S1a: copy A->D, ASH 0, ascending, modulos
    sub_begin("S1a", "copy A->D 5x8 (BLTCON0 $09F0), content vs reference");
    od0 = h_old.dcount; nd0 = h_new.dcount;
    prog(16'h09F0, 16'h0000, 16'hFFFF, 16'hFFFF, 21'h01000, 21'h0, 21'h0, 21'h10000,
         16'h0002, 16'h0000, 16'h0000, 16'h0004, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (8 << 6) | 5);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 40, "40 D writes");
    e = 0;
    for (r = 0; r < 8; r = r + 1) for (c = 0; c < 5; c = c + 1) begin
      i = nd0 + r * 5 + c;
      if (h_new.dl_addr[i % 8192] !== 20'h08000 + r * 7 + c ||
          h_new.dl_data[i % 8192] !== pat(32'h800 + r * 6 + c)) e = e + 1;
    end
    chk(e == 0, "D addresses/data equal the A source (harness sanity)");
    sub_end;

    // S1b: shifted, masked, descending copy
    sub_begin("S1b", "copy A->D ASH 3, masks, DESC, 4x6");
    nd0 = h_new.dcount;
    prog(16'h39F0, 16'h0002, 16'h0FFF, 16'hFFF0, 21'h01200, 21'h0, 21'h0, 21'h10400,
         16'h0002, 16'h0000, 16'h0000, 16'h0002, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (6 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 24, "24 D writes");
    sub_end;

    // S1c: A/B/C->D cookie cut with stalls
    sub_begin("S1c", "A/B/C->D minterm $CA, ASH 4/BSH 4, 6x7, DMA stalls");
    stall_en = 1'b1;
    nd0 = h_new.dcount;
    prog(16'h4FCA, 16'h4000, 16'hFFFF, 16'hFF00, 21'h01400, 21'h02000, 21'h03000, 21'h11000,
         16'h0002, 16'h0002, 16'h0002, 16'h0002, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (7 << 6) | 6);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 42, "42 D writes");
    stall_en = 1'b0;
    sub_end;

    // S1d: A+D inclusive fill, descending, sparse source, stalls
    sub_begin("S1d", "A+D IFE|DESC fill 4x10 completes normally, content vs reference");
    stall_en = 1'b1;
    W = 4; H = 10;
    nd0 = h_new.dcount;
    prog(16'h09F0, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h06000 + (W * H - 1) * 2, 21'h0, 21'h0,
         21'h12000 + (W * H - 1) * 2, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (H << 6) | W);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == W * H, "40 D writes");
    e = 0;
    for (r = 0; r < H; r = r + 1) begin
      carry = 1'b0;
      for (c = 0; c < W; c = c + 1) begin
        i = r * W + c;
        fr = fillw(pat(32'h3000 + (W * H - 1) - i), carry, 1'b0);
        carry = fr[16];
        if (h_new.dl_addr[(nd0 + i) % 8192] !== 20'h09000 + (W * H - 1) - i ||
            h_new.dl_data[(nd0 + i) % 8192] !== fr[15:0]) e = e + 1;
      end
    end
    chk(e == 0, "D data equals reference inclusive fill (harness sanity)");
    stall_en = 1'b0;
    sub_end;

    // S1e: D-only exclusive fill with FCI, completes normally
    sub_begin("S1e", "D-only EFE|FCI|DESC fill 3x5 (BLTCON0 $01AA) completes, content vs reference");
    W = 3; H = 5;
    nd0 = h_new.dcount;
    prog(16'h01AA, 16'h0016, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h13000 + (W * H - 1) * 2,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0810);
    wr(BLTSIZE, (H << 6) | W);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == W * H, "15 D writes");
    e = 0;
    for (r = 0; r < H; r = r + 1) begin
      carry = 1'b1;
      for (c = 0; c < W; c = c + 1) begin
        i = r * W + c;
        fr = fillw(16'h0810, carry, 1'b1);
        carry = fr[16];
        if (h_new.dl_addr[(nd0 + i) % 8192] !== 20'h09800 + (W * H - 1) - i ||
            h_new.dl_data[(nd0 + i) % 8192] !== fr[15:0]) e = e + 1;
      end
    end
    chk(e == 0, "D data equals reference exclusive fill (harness sanity)");
    sub_end;

    // S1f: C+D fill (USEC on, no extra cycle)
    sub_begin("S1f", "C+D IFE|DESC fill 4x6 (BLTCON0 $03AA)");
    nd0 = h_new.dcount;
    prog(16'h03AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h06400 + 46, 21'h13800 + 46,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (6 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 24, "24 D writes");
    sub_end;

    // S1g: line mode, octant code 110 (bits 4 and 3 set), stalls
    sub_begin("S1g", "line mode dx 30 dy 12 (BLTCON0 $xBCA, BLTCON1 $0019|SIGN), DMA stalls");
    stall_en = 1'b1;
    nd0 = h_new.dcount;
    prog_line(16'h0BCA, 16'h0019, 10, 5, 30, 12, 21'h14000);
    wr(BLTSIZE, (31 << 6) | 2);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 31, "31 D writes (one per pixel)");
    stall_en = 1'b0;
    sub_end;

    // S1h: one-dot line mode
    sub_begin("S1h", "line mode one-dot (SING), dx 30 dy 12");
    nd0 = h_new.dcount;
    prog_line(16'h0BCA, 16'h001B, 3, 40, 30, 12, 21'h14000);
    wr(BLTSIZE, (31 << 6) | 2);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 > 0 && h_new.dcount - nd0 <= 31, "1..31 D writes");
    sub_end;

    // S1i: zero result, BZERO stays set
    sub_begin("S1i", "A->D with LF $00 (all-zero result), BZERO set");
    nd0 = h_new.dcount;
    prog(16'h0900, 16'h0000, 16'hFFFF, 16'hFFFF, 21'h01000, 21'h0, 21'h0, 21'h15000,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (3 << 6) | 2);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 6, "6 D writes");
    chk(n_zero === 1'b1 && o_zero === 1'b1, "BZERO set on both");
    sub_end;

    // S1j: A/B/C->D with mid-blit writes to registers other than BLTCON1
    sub_begin("S1j", "A/B/C->D with mid-blit BLTCDAT/BLTAFWM/BLTCON0 writes, DMA stalls");
    stall_en = 1'b1;
    nd0 = h_new.dcount; na0 = h_new.acount;
    prog(16'h0FE2, 16'h0000, 16'hFFFF, 16'hFFFF, 21'h01800, 21'h02400, 21'h03400, 21'h15400,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (8 << 6) | 8);
    wait_acks_new(na0, 20, ok); chk(ok, "blit reached the mid point");
    wr(BLTCDAT, 16'h1234); wr(BLTAFWM, 16'h7FFE); wr(BLTCON0, 16'h0FE2);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    stall_en = 1'b0;
    sub_end;

    // S1k: BLTCON1 write between blits that keeps a fill, then a D-only fill run
    sub_begin("S1k", "D-only IFE fill 4x8, copper-written BLTSIZE");
    nd0 = h_new.dcount;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h16000,
         16'h0000, 16'h0000, 16'h0000, 16'h0004, 16'h0, 16'h0, 16'h0810);
    cop(BLTSIZE, (8 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "blit completes");
    chk(h_new.dcount - nd0 == 32, "32 D writes");
    sub_end;

    ticks(8);
    cmp_en = 1'b0;
    sub_begin("S1", "whole-sequence golden diff");
    chk(mism == mm0, "OLD and NEW cycle-identical over all S1 blits");
    chk(frz_n == fz0 && frz_o == 0, "no BLT_FROZEN state on either engine");
    chk(h_new.dcount == h_old.dcount, "same total D writes");
    chk(dlog_diff(0, 0, h_new.dcount) == 0, "complete D logs identical");
    $display("    info: %0d clk7 cycles compared, %0d D writes, %0d DMA cycles", cmp_cycles, h_new.dcount, h_new.acount);
    sub_end;

    // ================================================================ S3
    scen = 4;
    // S3a: idle write
    sub_begin("S3a", "BLTCON1 <= $0000 while idle (old mode D-only IFE), then a normal blit");
    do_reset;
    mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount;
    cmp_en = 1'b1;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h17000,
         16'h0000, 16'h0000, 16'h0000, 16'h0004, 16'h0, 16'h0, 16'h0810);
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(acc_busy_n === 1'b0 && (acc_con1_n & 16'h0019) == 16'h0008 && acc_con0_n[9:8] == 2'b01,
        "precondition: idle, old mode IFE, bltcon0[9:8] = 01");
    ticks(2);
    chk(n_st === ST_IDLE, "NEW stays idle");
    wr(BLTCON1, 16'h000A);
    wr(BLTSIZE, (8 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "both blits complete");
    // S3a2: write in the flush cycles right after busy fell
    wr(BLTSIZE, (2 << 6) | 4);
    i = 0;
    while (n_busy !== 1'b0 && i < TMO) begin tick; i = i + 1; end
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(acc_busy_n === 1'b0 && acc_st_n !== ST_IDLE, "second write landed after busy fell, FSM still flushing");
    wait_done(2'b11, ok); chk(ok, "flush completes");
    ticks(8);
    cmp_en = 1'b0;
    chk(frz_n == fz0, "NEW never entered BLT_FROZEN");
    chk(mism == mm0, "NEW cycle-identical to OLD");
    chk(dlog_diff(od0, nd0, h_new.dcount - nd0) == 0 && h_new.dcount - nd0 == 40, "D logs identical (32 + 8 words)");
    sub_end;

    // fill kept / line set
    s3_mid("S3b1", "D-only IFE fill, mid-blit BLTCON1 <= $0012 (EFE kept)",
           16'h01AA, 16'h000A, (8 << 6) | 4, 6, 2'd0, 16'h0012, 16'h0019, 16'h0008);
    s3_mid("S3b2", "D-only IFE fill, mid-blit BLTCON1 <= $000E (IFE kept, FCI)",
           16'h01AA, 16'h000A, (8 << 6) | 4, 6, 2'd0, 16'h000E, 16'h0019, 16'h0008);
    s3_mid("S3b3", "D-only IFE fill, mid-blit BLTCON1 <= $0001 (LINE set, fill bits clear)",
           16'h01AA, 16'h000A, (8 << 6) | 4, 6, 2'd0, 16'h0001, 16'h0019, 16'h0008);
    s3_mid("S3b4", "D-only EFE fill, mid-blit BLTCON1 <= $0008 (switch to IFE)",
           16'h01AA, 16'h0012, (8 << 6) | 4, 6, 2'd0, 16'h0008, 16'h0019, 16'h0010);
    // non-fill blits
    s3_mid("S3c1", "D-only non-fill blit (BLTCON1 $0002), mid-blit BLTCON1 <= $0000",
           16'h01AA, 16'h0002, (8 << 6) | 4, 6, 2'd0, 16'h0000, 16'h0019, 16'h0000);
    s3_mid("S3c2", "A->D copy, mid-blit BLTCON1 <= $0000",
           16'h09F0, 16'h0002, (8 << 6) | 4, 8, 2'd0, 16'h0000, 16'h0019, 16'h0000);
    // USEC on / D off
    s3_mid("S3d1", "C+D IFE fill (bltcon0[9:8] = 11), mid-blit BLTCON1 <= $0000",
           16'h03AA, 16'h000A, (8 << 6) | 4, 8, 2'd0, 16'h0000, 16'h0019, 16'h0008);
    s3_mid("S3d2", "C-only IFE fill (bltcon0[9:8] = 10), mid-blit BLTCON1 <= $0000",
           16'h02AA, 16'h000A, (8 << 6) | 4, 6, 2'd0, 16'h0000, 16'h0019, 16'h0008);
    s3_mid("S3d3", "A-only IFE fill (bltcon0[9:8] = 00), mid-blit BLTCON1 <= $0000",
           16'h08F0, 16'h000A, (8 << 6) | 4, 6, 2'd0, 16'h0000, 16'h0019, 16'h0008);
    // line mode
    sub_begin("S3e1", "line mode (BLTCON0 $xBCA, BLTCON1 $0059), mid-blit BLTCON1 <= $0000");
    do_reset;
    mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount; oi0 = h_old.icount; ni0 = h_new.icount;
    cmp_en = 1'b1;
    prog_line(16'h0BCA, 16'h0019, 10, 5, 30, 12, 21'h14000);
    na0 = h_new.acount;
    wr(BLTSIZE, (31 << 6) | 2);
    wait_acks_new(na0, 10, ok); chk(ok, "blit reached the trigger point");
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(acc_busy_n === 1'b1 && acc_con1_n[0] === 1'b1 && (acc_con1_n & 16'h0018) == 16'h0018,
        "precondition: busy, LINE set, octant bits 4 and 3 set");
    wait_done(2'b11, ok); chk(ok, "both blits complete");
    ticks(8); cmp_en = 1'b0;
    chk(frz_n == fz0, "NEW never entered BLT_FROZEN");
    chk(mism == mm0, "NEW cycle-identical to OLD");
    chk(dlog_diff(od0, nd0, h_new.dcount - nd0) == 0 && h_new.dcount - nd0 == h_old.dcount - od0, "D logs identical");
    sub_end;

    sub_begin("S3e2", "line mode with bltcon0[9:8] = 01 ($x9CA) and bits 4/3 set, BLTCON1 <= $0000");
    do_reset;
    mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount;
    cmp_en = 1'b1;
    prog_line(16'h09CA, 16'h0019, 10, 5, 30, 12, 21'h14000);
    wr(BLTSIZE, (31 << 6) | 2);
    ticks(20);
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(acc_busy_n === 1'b1 && acc_con1_n[0] === 1'b1 && (acc_con1_n & 16'h0018) == 16'h0018 &&
        acc_con0_n[9:8] == 2'b01, "precondition: busy, LINE set, bits 4/3 set, bltcon0[9:8] = 01");
    wait_done(2'b11, ok); chk(ok, "both blits complete");
    ticks(8); cmp_en = 1'b0;
    chk(frz_n == fz0, "NEW never entered BLT_FROZEN");
    chk(mism == mm0, "NEW cycle-identical to OLD");
    sub_end;

    // CPU read of BLTCON1 (gary.v presents $FFFF)
    s3_mid("S3f1", "D-only IFE fill, mid-blit CPU READ of BLTCON1 (data bus $FFFF)",
           16'h01AA, 16'h000A, (8 << 6) | 4, 6, 2'd1, 16'h0000, 16'h0019, 16'h0008);
    s3_mid("S3f2", "D-only IFE fill, clr.w BLTCON1 (read $FFFF then write $0000)",
           16'h01AA, 16'h000A, (8 << 6) | 4, 6, 2'd2, 16'h0000, 16'h0019, 16'h0008);

    // S3g: positive control inside S3 - EFE old mode must freeze (then S4a)
    sub_begin("S3g", "D-only EFE|DESC fill, mid-blit BLTCON1 <= $0000 MUST freeze");
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount;
    prog(16'h01AA, 16'h0012, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h18000,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0810);
    na0 = h_new.acount;
    wr(BLTSIZE, (8 << 6) | 4);
    wait_acks_new(na0, 5, ok); chk(ok, "blit reached the trigger point");
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk((acc_con1_n & 16'h0019) == 16'h0010, "precondition: old mode EFE only");
    freeze_checks(32);
    sub_end;

    // ================================================================ S4
    scen = 5;
    sub_begin("S4a", "reset while frozen (after S3g) releases; post-reset golden diff");
    chk(n_st === ST_FROZEN && n_busy === 1'b1, "NEW still frozen before reset");
    do_reset;
    chk(n_st === ST_IDLE && n_busy === 1'b0, "NEW idle, busy low right after reset");
    mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount;
    cmp_en = 1'b1;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h18000,
         16'h0000, 16'h0000, 16'h0000, 16'h0004, 16'h0, 16'h0, 16'h0810);
    wr(BLTSIZE, (8 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "post-reset fill blit completes on both");
    stall_en = 1'b1;
    prog(16'h4FCA, 16'h4000, 16'hFFFF, 16'hFF00, 21'h01400, 21'h02000, 21'h03000, 21'h18800,
         16'h0002, 16'h0002, 16'h0002, 16'h0002, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (7 << 6) | 6);
    wait_done(2'b11, ok); chk(ok, "post-reset A/B/C->D blit completes on both");
    stall_en = 1'b0;
    ticks(8); cmp_en = 1'b0;
    chk(mism == mm0, "post-reset OLD and NEW cycle-identical");
    chk(frz_n == fz0, "no re-freeze");
    chk(h_new.dcount - nd0 == 74 && dlog_diff(od0, nd0, 74) == 0, "D logs identical (32 + 42 words)");
    sub_end;

    // ================================================================ S2
    scen = 2;
    sub_begin("S2a", "D-only IFE|DESC fill 4x8, BLTCON1 <= $0000 mid-blit: freeze, then BLTSIZE releases");
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount; oi0 = h_old.icount; ni0 = h_new.icount;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h1A000,
         16'h0000, 16'h0000, 16'h0000, 16'h0004, 16'h0, 16'h0, 16'h0810);
    na0 = h_new.acount;
    wr(BLTSIZE, (8 << 6) | 4);
    wait_acks_new(na0, 6, ok); chk(ok, "blit reached the trigger point (6 D writes)");
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk((acc_con1_n & 16'h0019) == 16'h0008 && acc_con0_n[9:8] == 2'b01, "precondition: IFE, bltcon0[9:8] = 01");
    freeze_checks(32);
    chk(dlog_diff(od0, nd0, k) == 0, "pre-freeze D writes identical on both");
    // writes that must not release the freeze (OLD is idle by now)
    wr(BLTSIZV, 16'h0004);
    wr(BLTSIZH, 16'h0004);           // ECS-only register, ecs = 0
    wr(BLTCON0, 16'h01AA);
    wr(BLTCON1, 16'h000A);           // fill back on - still frozen
    cop(BLTCON1, 16'h0000);          // copper write while frozen
    wr(BLTCON1, 16'h000A);
    wr(BLTADAT, 16'h1234);
    wr(BLTCDAT, 16'h0810);
    blten = 1'b0; ticks(20); blten = 1'b1; ticks(50);
    chk(w_req_n == 0 && w_nf_n == 0 && w_nb_n == 0, "NEW stays frozen through BLTSIZV/BLTSIZH(ecs=0)/BLTCON0/BLTCON1/copper/BLTEN writes");
    chk(h_new.dcount - nd0 == k, "NEW D log still frozen");
    win_en = 1'b0;
    // OLD-only: point its D pointer where NEW's frozen pointer must be
    P = h_old.dl_addr[(od0 + k) % 8192];
    setptr(BLTDPTH, {P, 1'b0}, 2'b01);
    chk(n_st === ST_FROZEN, "NEW still frozen before BLTSIZE");
    nd1 = h_new.dcount; od1 = h_old.dcount; ni1 = h_new.icount; oi1 = h_old.icount;
    bus_access(BLTSIZE, (4 << 6) | 4, 1'b0, 2'b11);
    t_rel = acc_cyc; fz0 = frz_n;
    chk(n_st === ST_INIT, "BLTSIZE write moves NEW from BLT_FROZEN to BLT_INIT");
    ticks(2);
    wait_done(2'b11, ok); chk(ok, "released blit completes (busy falls) on NEW, reference blit on OLD");
    chk(h_new.dcount - nd1 == 16 && h_old.dcount - od1 == 16, "16 D writes each");
    chk(h_new.dl_addr[nd1 % 8192] === P, "NEW resumes at the frozen D pointer (no pointer/modulo update while frozen)");
    chk(dlog_diff(od1, nd1, 16) == 0, "released NEW blit equals OLD reference blit (addresses + data)");
    chk(h_new.icount - ni1 == 1 && h_old.icount - oi1 == 1, "exactly one int3 each for the released blit");
    chk(frz_n == fz0, "no re-freeze after release");
    lat_n = h_new.dl_cyc[nd1 % 8192] - t_rel; lat_o = h_old.dl_cyc[od1 % 8192] - t_rel;
    $display("    info: BLTSIZE -> first D write: NEW (from FROZEN) %0d clk7, OLD (from IDLE) %0d clk7", lat_n, lat_o);
    sub_end;

    sub_begin("S2b", "A+D IFE|DESC fill, BLTCON1 <= $F006 (BSH/FCI/DESC set, 0/3/4 clear): freeze, reprogram, release");
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount;
    W = 4; H = 10;
    prog(16'h09F0, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h06000 + (W * H - 1) * 2, 21'h0, 21'h0,
         21'h1B000 + (W * H - 1) * 2, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    na0 = h_new.acount;
    wr(BLTSIZE, (H << 6) | W);
    wait_acks_new(na0, 9, ok); chk(ok, "blit reached the trigger point");
    bus_access(BLTCON1, 16'hF006, 1'b0, 2'b11);
    chk((acc_con1_n & 16'h0019) == 16'h0008 && acc_con0_n[11:8] == 4'b1001, "precondition: IFE, USE = A+D");
    freeze_checks(40);
    win_en = 1'b0;
    prog(16'h09F0, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h06000 + (W * H - 1) * 2, 21'h0, 21'h0,
         21'h1C000 + (W * H - 1) * 2, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    chk(n_st === ST_FROZEN, "NEW still frozen after a complete register reprogram");
    nd1 = h_new.dcount; od1 = h_old.dcount;
    wr(BLTSIZE, (H << 6) | W);
    wait_done(2'b11, ok); chk(ok, "released blit completes");
    chk(h_new.dcount - nd1 == 40 && dlog_diff(od1, nd1, 40) == 0, "released NEW blit equals OLD reference (40 words)");
    sub_end;

    sub_begin("S2c", "B+D IFE|DESC fill, copper MOVE to BLTCON1 freezes, copper MOVE to BLTSIZE releases");
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount;
    prog(16'h05CC, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h06000 + 62, 21'h0, 21'h1D000 + 62,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    na0 = h_new.acount;
    wr(BLTSIZE, (8 << 6) | 4);
    wait_acks_new(na0, 9, ok); chk(ok, "blit reached the trigger point");
    bus_access(BLTCON1, 16'h0000, 1'b1, 2'b11);
    chk((acc_con1_n & 16'h0019) == 16'h0008 && acc_con0_n[11:8] == 4'b0101, "precondition: IFE, USE = B+D");
    freeze_checks(32);
    win_en = 1'b0;
    prog(16'h05CC, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h06000 + 62, 21'h0, 21'h1E000 + 62,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    nd1 = h_new.dcount; od1 = h_old.dcount;
    cop(BLTSIZE, (8 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "released blit completes");
    chk(h_new.dcount - nd1 == 32 && dlog_diff(od1, nd1, 32) == 0, "released NEW blit equals OLD reference (32 words)");
    sub_end;

    // ================================================================ S2 informational
    scen = 6;
    sub_begin("S2d", "informational: BLTCON1 <= $0000 after BLTSIZE but before the first blit cycle (busy, FSM idle)");
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h1F000,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0810);
    blten = 1'b0;                      // other DMA owns every slot: blitter cannot start
    wr(BLTSIZE, (8 << 6) | 4);
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(acc_busy_n === 1'b1 && acc_st_n === ST_IDLE, "precondition: busy set, FSM still in BLT_IDLE");
    chk(n_st === ST_FROZEN, "NEW freezes from BLT_IDLE (condition is gated by busy, not by FSM progress)");
    ticks(2);
    blten = 1'b1;
    wait_done(2'b01, ok);
    ticks(50);
    chk(ok && h_old.dcount - od0 == 32, "OLD runs the blit to completion");
    chk(n_st === ST_FROZEN && h_new.dcount == nd0, "NEW stays frozen with zero D writes");
    sub_end;

    scen = 5;
    sub_begin("S4b", "reset releases a freeze that never ran a cycle (after S2d); post-reset golden diff");
    do_reset;
    chk(n_st === ST_IDLE && n_busy === 1'b0, "NEW idle, busy low right after reset");
    mm0 = mism; fz0 = frz_n; od0 = h_old.dcount; nd0 = h_new.dcount;
    cmp_en = 1'b1;
    prog(16'h09F0, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h06000 + 78, 21'h0, 21'h0, 21'h1F800 + 78,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0);
    wr(BLTSIZE, (10 << 6) | 4);
    wait_done(2'b11, ok); chk(ok, "post-reset blit completes on both");
    ticks(8); cmp_en = 1'b0;
    chk(mism == mm0 && frz_n == fz0, "post-reset OLD and NEW cycle-identical, no freeze");
    chk(h_new.dcount - nd0 == 40 && dlog_diff(od0, nd0, 40) == 0, "D logs identical");
    sub_end;

    scen = 6;
    sub_begin("S2e", "informational: with ecs = 1 a BLTSIZH write releases the freeze");
    ecs_r = 1'b1;
    do_reset;
    od0 = h_old.dcount; nd0 = h_new.dcount;
    prog(16'h01AA, 16'h000A, 16'hFFFF, 16'hFFFF, 21'h0, 21'h0, 21'h0, 21'h1A800,
         16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0, 16'h0, 16'h0810);
    na0 = h_new.acount;
    wr(BLTSIZE, (8 << 6) | 4);
    wait_acks_new(na0, 6, ok);
    bus_access(BLTCON1, 16'h0000, 1'b0, 2'b11);
    chk(n_st === ST_FROZEN, "NEW freezes with ecs = 1 as well");
    wait_done(2'b01, ok);
    wr(BLTSIZV, 16'h0004);
    chk(n_st === ST_FROZEN, "BLTSIZV alone does not release");
    nd1 = h_new.dcount; od1 = h_old.dcount;
    bus_access(BLTSIZH, 16'h0004, 1'b0, 2'b11);
    chk(n_st === ST_INIT, "BLTSIZH (ecs = 1) releases to BLT_INIT");
    ticks(2);
    wait_done(2'b11, ok); chk(ok, "released blit completes");
    chk(h_new.dcount - nd1 == 16 && h_old.dcount - od1 == 16, "16 D writes each (4x4 via BLTSIZV/BLTSIZH)");
    ecs_r = 1'b0;
    do_reset;
    sub_end;

    // ================================================================ summary
    $display("SUMMARY");
    $display("S1 IDENTITY (OLD vs NEW, ordinary blits)            : %0s", fails[1] == 0 ? "PASS" : "FAIL");
    $display("S2 FREEZE NEW (freeze + BLTSIZE release)            : %0s", fails[2] == 0 ? "PASS" : "FAIL");
    $display("S2 FREEZE OLD (RED control: must not freeze)        : %0s", fails[3] == 0 ? "PASS (OLD does not freeze, as expected)" : "FAIL (red control broken)");
    $display("S3 NEGATIVE CONTROLS (NEW must not freeze, equals OLD; S3g must freeze): %0s", fails[4] == 0 ? "PASS" : "FAIL");
    $display("S4 RESET RELEASES FREEZE (+ post-reset identity)    : %0s", fails[5] == 0 ? "PASS" : "FAIL");
    $display("INFO characterisation (S2d pre-start, S2e ecs BLTSIZH): %0s", fails[6] == 0 ? "PASS" : "FAIL");
    if (fails[1] + fails[2] + fails[3] + fails[4] + fails[5] + fails[6] == 0)
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL");
    $finish;
  end

  initial begin
    #400000000;
    $display("RESULT: FAIL (global timeout)");
    $finish;
  end
endmodule
