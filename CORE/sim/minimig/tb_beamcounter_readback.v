// tb_beamcounter_readback.v - golden diff of rtl/agnus_beamcounter.v
//
// OLD = the beam counter at fa40334, the Minimig fork's baseline before the
//       upstream ports (module agnus_beamcounter_old)
// NEW = the beam counter in the working tree (upstream 06f30af VHPOSR readback +
//       upstream d16cd84 field1 gate, both on top of the AExp hpos split).
// Both copies are prepared by run_tb_beamcounter_readback.sh, which hoists the
// declarations that rtl/ uses before declaring them (iverilog cannot bind those)
// with one identical mechanical transformation and proves that nothing else
// moved.
//
// Both instances get identical stimulus: the real amiga_clk.v clock-enable
// generator (clk7_en / cck exactly as in the core), ntsc = ecs = aga = a1k = 0
// (AExp: userio 0xF3 payload 0x0000 = OCS, A500, PAL), and a bus model that
// presents one register address per 7 MHz slot, like agnus.v's reg_address
// (8'hFF = idle).
//
// Checks, evaluated on every falling clk28 edge once the counters are known:
//   (i)   every output except data_out and field1 is identical OLD vs NEW
//   (ii)  data_out differs from OLD only while VHPOSR/VHPOSW is addressed, and
//         there it equals {OLD[15:8], h ? h-1 : (ersy ? 0 : htotal[8:1])}
//         with h = OLD[7:0] (= hpos[8:1]), ersy from the TB's own bus shadow
//         and htotal[8:1] = 8'hE2 (PAL, OCS: BEAMCON0 not writable)
//   (iii) NEW field1 == OLD field1 & lace (so equal whenever lace = 1)
//   (iv)  stimulus coverage (frames, every readback value, ERSY freeze, the
//         FFE2 wrap row, the VHPOSW alias, field1-differing cycles)
//   (v)   no X on any output, htotal_out == 0x1C4, TB ersy shadow == DUT ersy
//
// Red controls (run_tb_beamcounter_readback.sh --red): the defines below break
// one expectation each; DUT mutants are produced by the run script.
//   RED_EXPECT_WRAP0     expect 0 at the wrap instead of htotal[8:1]
//   RED_EXPECT_FIELD1_EQ expect NEW field1 == OLD field1 unconditionally
//
// Run: CORE/sim/minimig/run_tb_beamcounter_readback.sh (about ten minutes).
`timescale 1ns/1ps

module tb_beamcounter_readback;

   // register addresses (byte offsets, decoded on [8:1] like the DUT)
   localparam [8:0] DMACONR  = 9'h002;
   localparam [8:0] VPOSR    = 9'h004;
   localparam [8:0] VHPOSR   = 9'h006;
   localparam [8:0] JOY0DAT  = 9'h00A;
   localparam [8:0] INTREQR  = 9'h01E;
   localparam [8:0] VPOSW    = 9'h02A;
   localparam [8:0] VHPOSW   = 9'h02C;
   localparam [8:0] BPLCON0  = 9'h100;
   localparam [8:0] HTOTAL   = 9'h1C0;
   localparam [8:0] BEAMCON0 = 9'h1DC;
   localparam [7:0] IDLE     = 8'hFF;

`ifdef RED_EXPECT_WRAP0
   localparam [7:0] WRAP     = 8'h00;
`else
   localparam [7:0] WRAP     = 8'hE2;   // htotal[8:1] for PAL (227 CCK - 1)
`endif

   // ------------------------------------------------------------------ clocks
   reg clk = 1'b0;
   always #17.621 clk = ~clk;            // 28.375 MHz

   reg  reset_n = 1'b0;
   wire clk7_en, clk7n_en, c1, c3, cck;
   wire [9:0] eclk;

   amiga_clk u_clk (
      .clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
      .c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .reset_n(reset_n)
   );

   // --------------------------------------------------------------------- bus
   reg        bc_reset = 1'b1;
   reg  [8:1] reg_addr = IDLE;
   reg [15:0] data_in  = 16'hFFFF;

   // ------------------------------------------------------------------- DUTs
   wire [15:0] o_data,  n_data;
   wire  [8:0] o_hpos,  n_hpos;
   wire [10:0] o_vpos,  n_vpos;
   wire        o_hs, n_hs, o_vs, n_vs, o_f1, n_f1, o_lace, n_lace, o_cs, n_cs;
   wire        o_hbl, n_hbl, o_vblk, n_vblk, o_vbl, n_vbl, o_vbe, n_vbe;
   wire        o_eol, n_eol, o_eof, n_eof, o_vint, n_vint;
   wire  [8:0] o_htot, n_htot;
   wire        o_hdis, n_hdis, o_vben, n_vben;

   agnus_beamcounter_old u_old (
      .clk(clk), .clk7_en(clk7_en), .reset(bc_reset), .cck(cck),
      .ntsc(1'b0), .aga(1'b0), .ecs(1'b0), .a1k(1'b0),
      .data_in(data_in), .data_out(o_data), .reg_address_in(reg_addr),
      .hpos(o_hpos), .vpos(o_vpos), ._hsync(o_hs), ._vsync(o_vs),
      .field1(o_f1), .lace(o_lace), ._csync(o_cs),
      .hblank(o_hbl), .vblank(o_vblk), .vbl(o_vbl), .vblend(o_vbe),
      .eol(o_eol), .eof(o_eof), .vbl_int(o_vint),
      .htotal_out(o_htot), .harddis_out(o_hdis), .varbeamen_out(o_vben)
   );

   agnus_beamcounter u_new (
      .clk(clk), .clk7_en(clk7_en), .reset(bc_reset), .cck(cck),
      .ntsc(1'b0), .aga(1'b0), .ecs(1'b0), .a1k(1'b0),
      .data_in(data_in), .data_out(n_data), .reg_address_in(reg_addr),
      .hpos(n_hpos), .vpos(n_vpos), ._hsync(n_hs), ._vsync(n_vs),
      .field1(n_f1), .lace(n_lace), ._csync(n_cs),
      .hblank(n_hbl), .vblank(n_vblk), .vbl(n_vbl), .vblend(n_vbe),
      .eol(n_eol), .eof(n_eof), .vbl_int(n_vint),
      .htotal_out(n_htot), .harddis_out(n_hdis), .varbeamen_out(n_vben)
   );

   // all outputs except data_out and field1, concatenated
   wire [57:0] o_rest = {o_hpos, o_vpos, o_hs, o_vs, o_lace, o_cs, o_hbl, o_vblk,
                         o_vbl, o_vbe, o_eol, o_eof, o_vint, o_htot, o_hdis, o_vben};
   wire [57:0] n_rest = {n_hpos, n_vpos, n_hs, n_vs, n_lace, n_cs, n_hbl, n_vblk,
                         n_vbl, n_vbe, n_eol, n_eof, n_vint, n_htot, n_hdis, n_vben};

   // ---------------------------------------------- TB shadow of BPLCON0 ERSY
   reg tb_ersy = 1'b0;
   always @(posedge clk) if (clk7_en) begin
      if (bc_reset)                      tb_ersy <= 1'b0;
      else if (reg_addr == BPLCON0[8:1]) tb_ersy <= data_in[1];
   end

   // ------------------------------------------------------------ bookkeeping
   reg     checking = 1'b0;
   integer cycles = 0;
   integer err1 = 0, err2 = 0, err3 = 0, err4 = 0, err5 = 0;
   integer rb_cycles = 0, rb_diff = 0, other_cycles = 0;
   integer f1_lace1 = 0, f1_lace0_lf0 = 0, f1_lace0_lf1 = 0, f1_diff = 0;
   integer cov_ersy_freeze = 0, cov_ersy_run = 0, cov_vhposw = 0, cov_ffe2 = 0;
   integer frames_lace = 0, frames_nolace = 0, f1_edges_lace = 0;
   integer i, missing;
   reg [255:0] cov_h;                    // readback hpos values seen with ersy = 0
   reg [15:0]  exp_data;
   reg         exp_f1, prev_nf1;

   initial begin cov_h = 256'd0; prev_nf1 = 1'b0; end

   always @(posedge clk) if (checking && clk7_en && o_eof) begin
      if (o_lace) frames_lace   = frames_lace + 1;
      else        frames_nolace = frames_nolace + 1;
   end

   always @(negedge clk) if (checking) begin
      cycles = cycles + 1;

      // (v) no X anywhere, PAL OCS line length, shadow consistent with the DUT
      if (^{o_rest, n_rest, o_data, n_data, o_f1, n_f1} === 1'bx) begin
         err5 = err5 + 1;
         if (err5 <= 5) $display("[%0t] (v) X on an output", $time);
      end
      if (o_htot !== 9'h1C4 || n_htot !== 9'h1C4) begin
         err5 = err5 + 1;
         if (err5 <= 5) $display("[%0t] (v) htotal_out old=%h new=%h", $time, o_htot, n_htot);
      end
      if (tb_ersy !== u_new.ersy || tb_ersy !== u_old.ersy) begin
         err5 = err5 + 1;
         if (err5 <= 5) $display("[%0t] (v) ersy shadow %b vs dut %b/%b", $time,
                                 tb_ersy, u_old.ersy, u_new.ersy);
      end

      // (i) everything but data_out and field1 identical
      if (o_rest !== n_rest) begin
         err1 = err1 + 1;
         if (err1 <= 5) $display("[%0t] (i) old=%h new=%h", $time, o_rest, n_rest);
      end

      // (ii) data_out
      if (reg_addr == VHPOSR[8:1] || reg_addr == VHPOSW[8:1]) begin
         rb_cycles = rb_cycles + 1;
         exp_data = {o_data[15:8],
                     (o_data[7:0] != 8'h00) ? o_data[7:0] - 8'd1
                                            : (tb_ersy ? 8'h00 : WRAP)};
         if (n_data !== exp_data) begin
            err2 = err2 + 1;
            if (err2 <= 5) $display("[%0t] (ii) addr=%h old=%h new=%h exp=%h ersy=%b",
                                    $time, {reg_addr,1'b0}, o_data, n_data, exp_data, tb_ersy);
         end
         if (n_data !== o_data) rb_diff = rb_diff + 1;
         if (!tb_ersy) cov_h[o_data[7:0]] = 1'b1;
         else if (o_data[7:0] == 8'h00) cov_ersy_freeze = cov_ersy_freeze + 1;
         else cov_ersy_run = cov_ersy_run + 1;
         if (reg_addr == VHPOSW[8:1]) cov_vhposw = cov_vhposw + 1;
         if (n_data == 16'hFFE2) cov_ffe2 = cov_ffe2 + 1;
      end else begin
         other_cycles = other_cycles + 1;
         if (n_data !== o_data) begin
            err2 = err2 + 1;
            if (err2 <= 5) $display("[%0t] (ii) non-readback addr=%h old=%h new=%h",
                                    $time, {reg_addr,1'b0}, o_data, n_data);
         end
      end

      // (iii) field1
`ifdef RED_EXPECT_FIELD1_EQ
      exp_f1 = o_f1;
`else
      exp_f1 = o_f1 & o_lace;
`endif
      if (n_f1 !== exp_f1 || (o_lace && n_f1 !== o_f1)) begin
         err3 = err3 + 1;
         if (err3 <= 5) $display("[%0t] (iii) old=%b new=%b lace=%b", $time, o_f1, n_f1, o_lace);
      end
      if (n_f1 !== o_f1) f1_diff = f1_diff + 1;
      if (o_lace)            f1_lace1     = f1_lace1 + 1;
      else if (o_f1)         f1_lace0_lf0 = f1_lace0_lf0 + 1;   // OLD field1 = ~LOF = 1
      else                   f1_lace0_lf1 = f1_lace0_lf1 + 1;
      if (o_lace && n_f1 !== prev_nf1) f1_edges_lace = f1_edges_lace + 1;
      prev_nf1 = n_f1;
   end

   // --------------------------------------------------------------- bus tasks
   integer slot = 0;

   // wait for the next clk7_en edge (the edge that samples the current bus)
   task en_edge;
      begin
         @(posedge clk);
         while (!clk7_en) @(posedge clk);
      end
   endtask

   // one background slot: a read-only address pattern, VHPOSR most of the time
   task bg_slot;
      reg [5:0] p;
      begin
         en_edge;
         slot = slot + 1;
         p = slot[5:0];
         data_in  <= 16'hFFFF;                       // custom_data_in on a CPU read
         if      (p < 6'd44) reg_addr <= VHPOSR[8:1];
         else if (p < 6'd50) reg_addr <= VPOSR[8:1];
         else if (p < 6'd52) reg_addr <= DMACONR[8:1];
         else if (p < 6'd54) reg_addr <= JOY0DAT[8:1];
         else if (p < 6'd56) reg_addr <= INTREQR[8:1];
         else begin
            reg_addr <= IDLE;
            data_in  <= 16'hA5A5;
         end
      end
   endtask

   // one access slot (a write, or the CPU-read model of a write-only register)
   task access(input [8:0] a, input [15:0] d);
      begin
         en_edge;
         reg_addr <= a[8:1];
         data_in  <= d;
      end
   endtask

   task bg_slots(input integer n);
      integer k;
      begin for (k = 0; k < n; k = k + 1) bg_slot; end
   endtask

   task bg_frames(input integer n);
      integer k;
      begin
         k = 0;
         while (k < n) begin
            bg_slot;
            if (o_eof) k = k + 1;   // eof is one clk7 slot wide
         end
      end
   endtask

   task bg_until_vpos(input [10:0] v);
      begin
         bg_slot;
         while (o_vpos != v) bg_slot;
      end
   endtask

   task bg_until_lf_vpos(input lf, input [10:0] v);
      begin
         bg_slot;
         while (!(u_old.long_frame == lf && o_vpos == v)) bg_slot;
      end
   endtask

   // --------------------------------------------------------------- scenario
   integer k;
   initial begin
      // amiga_clk reset, then the beam counter's synchronous reset
      repeat (20) @(posedge clk);
      reset_n = 1'b1;
      repeat (8) en_edge;
      bc_reset <= 1'b0;
      // hpos_hi and vpos have no reset (FPGA init = 0); make them known
      access(VPOSW,  16'h8000);
      access(VHPOSW, 16'h0000);
      // two frames of warm-up: _vsync and friends have no reset either
      bg_frames(2);
      checking = 1'b1;

      $display("P1 progressive, LOF=1 (power-on state), 10 frames");
      bg_frames(10);

      $display("P2 LACE on, 12 frames");
      bg_until_vpos(11'd100);
      access(BPLCON0, 16'h9204);
      bg_frames(12);

      $display("P3 LACE off during a short field (LOF stays 0), 10 frames");
      bg_until_lf_vpos(1'b0, 11'd150);
      access(BPLCON0, 16'h9200);
      bg_frames(10);

      $display("P4 VPOSW LOF=1 / LOF=0 without LACE, then LOF toggled by hand for 10 frames");
      bg_until_vpos(11'd40);  access(VPOSW, 16'h8000);  bg_frames(3);
      bg_until_vpos(11'd40);  access(VPOSW, 16'h0000);  bg_frames(3);
      for (k = 0; k < 10; k = k + 1) begin
         bg_until_vpos(11'd20);
         access(VPOSW, (k % 2) ? 16'h0000 : 16'h8000);
         bg_frames(1);
      end

      $display("P5 LACE on while LOF=0 (10 frames), LACE off during a long field");
      bg_until_vpos(11'd30);  access(VPOSW, 16'h0000);
      bg_until_vpos(11'd200); access(BPLCON0, 16'h0004);
      bg_frames(10);
      bg_until_lf_vpos(1'b1, 11'd120);
      access(BPLCON0, 16'h0000);
      bg_frames(2);

      $display("P6 ERSY: set mid-line, freeze, VHPOSW while frozen, ERSY+LACE, release");
      bg_until_vpos(11'd60); bg_slots(123);
      access(BPLCON0, 16'h0002);
      bg_slots(3000);
      access(VHPOSW, 16'h3C50);
      bg_slots(1000);
      access(BPLCON0, 16'h0006);
      bg_slots(500);
      access(BPLCON0, 16'h0000);
      bg_frames(2);

      $display("P7 ECS-only registers with ecs=0 (must not change htotal)");
      access(BEAMCON0, 16'h0080);
      access(HTOTAL,   16'h0010);
      access(BEAMCON0, 16'h00A0);
      bg_frames(1);

      $display("P8 VHPOSW alias accesses (CPU-read model writes FFFF) and beam jumps");
      bg_until_vpos(11'd70); bg_slots(77);
      access(VHPOSW, 16'hFFFF);
      bg_slots(700);
      access(VHPOSW, 16'h0000);
      bg_slots(300);
      access(VPOSW,  16'h8000);
      bg_until_vpos(11'd250);
      access(VHPOSW, 16'hFED0);
      bg_frames(2);

      $display("P9 beam counter reset during an interlaced short field");
      access(BPLCON0, 16'h0004);
      bg_until_lf_vpos(1'b0, 11'd100);
      bg_slots(51);
      en_edge; bc_reset <= 1'b1;
      en_edge; bc_reset <= 1'b0;
      bg_frames(2);

      checking = 1'b0;
      en_edge;

      // ------------------------------------------------------------ verdicts
      missing = 0;
      for (i = 0; i <= 226; i = i + 1) if (!cov_h[i]) missing = missing + 1;

      $display("");
      $display("cycles checked: %0d  (readback-addressed %0d, other %0d)", cycles, rb_cycles, other_cycles);
      $display("frames: progressive %0d, interlaced %0d", frames_nolace, frames_lace);
      $display("readback: %0d cycles differ OLD vs NEW; ERSY freeze %0d, ERSY run %0d; VHPOSW alias %0d; FFE2 seen %0d; values 0..226 missing %0d",
               rb_diff, cov_ersy_freeze, cov_ersy_run, cov_vhposw, cov_ffe2, missing);
      $display("field1: lace=1 %0d cycles (%0d NEW edges), lace=0&LOF=0 %0d, lace=0&LOF=1 %0d; differ %0d",
               f1_lace1, f1_edges_lace, f1_lace0_lf0, f1_lace0_lf1, f1_diff);

      $display("%s (i)   non-readback outputs identical OLD vs NEW (%0d mismatches)",
               err1 == 0 ? "PASS" : "FAIL", err1);
      $display("%s (ii)  data_out = rule on VHPOSR/VHPOSW, identical elsewhere (%0d mismatches)",
               err2 == 0 ? "PASS" : "FAIL", err2);
      $display("%s (iii) NEW field1 == OLD field1 & lace (%0d mismatches)",
               err3 == 0 ? "PASS" : "FAIL", err3);
      if (frames_nolace >= 10 && frames_lace >= 10 && missing == 0 &&
          cov_ersy_freeze > 0 && cov_ersy_run > 0 && cov_vhposw > 0 && cov_ffe2 > 0 &&
          rb_diff > 0 && f1_diff > 0 && f1_lace0_lf0 > 0 && f1_lace0_lf1 > 0 &&
          f1_edges_lace >= 10)
         $display("PASS (iv)  stimulus coverage");
      else begin
         $display("FAIL (iv)  stimulus coverage");
         err4 = 1;
      end
      $display("%s (v)   no X, htotal_out == 0x1C4, ersy shadow == DUT (%0d errors)",
               err5 == 0 ? "PASS" : "FAIL", err5);

      if (err1 == 0 && err2 == 0 && err3 == 0 && err4 == 0 && err5 == 0) begin
         $display("RESULT: PASS");
         $finish;
      end else begin
         $display("RESULT: FAIL");
         $fatal(1, "golden diff failed");
      end
   end

endmodule
