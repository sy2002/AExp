// tb_cia_inmode.v - golden-diff testbench for the upstream PR-230 CIA timer change
// (Minimig submodule commit 62f880c = upstream b013ce3: CNT pin + Timer A/B INMODE).
//
// Instantiates the pre-port timers (fa40334, the Minimig fork's baseline before the upstream
// ports, renamed cia_timera_old/cia_timerb_old by run_tb_cia_inmode.sh) next to the current
// ones and drives both with identical random stimulus. CNT is held at the constant 1'b1 that
// minimig.v ties both CIAs to, except in the liveness phase.
//
// Phases (each split into a realistic-timing half and a random-timing half; every phase
// starts with a reset so old and new begin from the same state):
//   1  INMODE bits clear (CRA b5 = 0, CRB b5 = 0, CRB b6 random = modes 00/10):
//      old and new must agree on data_out/irq/tmra_ovf/spmode and on the counter and
//      control register state at every clock edge.
//   2  Timer A INMODE = 1, Timer B mode 01, CNT idle-high: the new timers must never
//      count (no underflow, no irq, counter frozen except for latch reloads); the old
//      timers, which counted eclk, must underflow on the same stimulus (teeth).
//   3  Timer B mode 11 (90 %) / 10 (10 %), CNT idle-high, Timer A INMODE = 0: new B must
//      equal the pre-port B (which ignored CRB b5) and a new-B twin that is written mode 10
//      instead of 11 (control-register reads compared with b5 masked).
//   4  Liveness, CNT toggling: Timer A INMODE = 1 and Timer B mode 01 decrement exactly on
//      a synchronised CNT rising edge, mode 11 exactly on a Timer A underflow while the
//      synchronised CNT level is high (TB-side reference model), and they do underflow.
//      Proves phase 2 is not passing because the CNT path is dead.
// Throughout phases 1..3 the CNT synchroniser must sit at 3'b111 and never emit an edge.
//
// Run: CORE/sim/minimig/run_tb_cia_inmode.sh (about 1.5 minutes).
`timescale 1ns/1ps

module tb_cia_inmode;

  localparam integer HALF = 500000;  // clk cycles per phase half (two halves per phase)

  reg clk = 1'b0;
  always #17.62 clk = ~clk;          // ~28.375 MHz

  reg        clk7_en = 1'b0;
  reg        reset   = 1'b1;
  reg        wr      = 1'b0;
  reg        a_tlo = 1'b0, a_thi = 1'b0, a_tcr = 1'b0;
  reg        b_tlo = 1'b0, b_thi = 1'b0, b_tcr = 1'b0;
  reg  [7:0] data_in = 8'h00;
  reg        eclk    = 1'b0;
  reg        cnt     = 1'b1;
  reg        rnd_ovf = 1'b0;
  reg        ovf_from_a = 1'b1;

  integer    phase       = 0;
  reg        rand_timing = 1'b0;
  reg        phase_ready = 1'b0;
  integer    reset_hold  = 16;
  integer    errors      = 0;

  // twin of the new Timer B: CRB writes carry b5 cleared (mode 10 instead of 11)
  wire [7:0] data_in_b10 = b_tcr ? (data_in & 8'hDF) : data_in;

  // ---------------------------------------------------------------- DUTs
  wire [7:0] ao_do, an_do;
  wire       ao_ovf, an_ovf, ao_sp, an_sp, ao_irq, an_irq;

  cia_timera_old u_old_a (.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(a_tlo), .thi(a_thi), .tcr(a_tcr), .data_in(data_in), .data_out(ao_do),
    .eclk(eclk), .tmra_ovf(ao_ovf), .spmode(ao_sp), .irq(ao_irq));

  cia_timera     u_new_a (.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(a_tlo), .thi(a_thi), .tcr(a_tcr), .data_in(data_in), .data_out(an_do),
    .eclk(eclk), .cnt(cnt), .tmra_ovf(an_ovf), .spmode(an_sp), .irq(an_irq));

  wire       b_ovf_in = ovf_from_a ? an_ovf : rnd_ovf;
  wire [7:0] bo_do, bn_do, bt_do;
  wire       bo_irq, bn_irq, bt_irq;

  cia_timerb_old u_old_b (.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(b_tlo), .thi(b_thi), .tcr(b_tcr), .data_in(data_in), .data_out(bo_do),
    .eclk(eclk), .tmra_ovf(b_ovf_in), .irq(bo_irq));

  cia_timerb     u_new_b (.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(b_tlo), .thi(b_thi), .tcr(b_tcr), .data_in(data_in), .data_out(bn_do),
    .eclk(eclk), .cnt(cnt), .tmra_ovf(b_ovf_in), .irq(bn_irq));

  cia_timerb     u_twin_b (.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(b_tlo), .thi(b_thi), .tcr(b_tcr), .data_in(data_in_b10), .data_out(bt_do),
    .eclk(eclk), .cnt(cnt), .tmra_ovf(b_ovf_in), .irq(bt_irq));

`define CHK(cond, msg) \
  begin \
    if (!(cond)) begin \
      errors = errors + 1; \
      if (errors <= 25) $display("FAIL t=%0t phase=%0d: %s", $time, phase, msg); \
    end \
  end

  // ---------------------------------------------------------------- stimulus
  integer c_cnt = 0, e_cnt = 0, cnt_timer = 0, ovf_timer = 0;
  integer r, sel;
  reg [7:0] d;

  always @(negedge clk) begin
    // E clock: realistic = one full clk7 period high every ten (minimig eclk[8])
    if (rand_timing)
      eclk <= ($urandom % 6) == 0;
    else if (clk7_en) begin
      e_cnt = (e_cnt + 1) % 10;
      eclk <= (e_cnt == 8);
    end
    // 7 MHz enable: realistic = 1 of 4 clk, random = ~1 of 3
    if (rand_timing)
      clk7_en <= ($urandom % 3) == 0;
    else begin
      c_cnt = (c_cnt + 1) % 4;
      clk7_en <= (c_cnt == 0);
    end

    // reset: initial/phase-boundary hold, plus rare random resets
    if (reset_hold > 0) begin
      reset_hold = reset_hold - 1;
      reset <= 1'b1;
    end else begin
      reset <= 1'b0;
      if (($urandom % 200000) == 0) reset_hold = 8 + ($urandom % 16);
    end

    // Timer B cascade source: Timer A underflow or random pulses, switched now and then
    ovf_timer = ovf_timer + 1;
    if (ovf_timer >= 50000) begin
      ovf_timer = 0;
      ovf_from_a <= ($urandom % 2) != 0;
    end
    rnd_ovf <= ($urandom % 8) == 0;

    // CNT: idle-high except in the liveness phase
    if (phase == 4) begin
      if (cnt_timer > 0) cnt_timer = cnt_timer - 1;
      else begin
        cnt <= ~cnt;
        cnt_timer = 8 + ($urandom % 120);
      end
    end else
      cnt <= 1'b1;

    // bus: one register selected at a time, reads frequent, writes rare
    {a_tlo, a_thi, a_tcr, b_tlo, b_thi, b_tcr} <= 6'b0;
    wr      <= 1'b0;
    data_in <= $urandom;
    r = $urandom % 1000;
    if (r < 40) begin
      sel = $urandom % 6;
      if (($urandom % 16) == 0) begin
        wr <= 1'b1;
        case (sel)
          0:    d = (($urandom % 4) != 0) ? ($urandom % 48) : $urandom;     // TALO
          3:    d = (($urandom % 2) != 0) ? ($urandom % 8)               // TBLO: short
                  : (($urandom % 2) != 0) ? ($urandom % 48) : $urandom;  // cascade periods
          1, 4: d = (($urandom % 4) != 0) ? 8'h00 : $urandom;               // TxHI
          2: begin                                                           // CRA
               d = $urandom;
               d[0] = ($urandom % 4) != 0;                                   // START mostly on
               d[4] = ($urandom % 4) == 0;                                   // LOAD strobe
               d[5] = (phase == 2 || phase == 4);                            // INMODE
             end
          default: begin                                                     // CRB
               d = $urandom;
               d[0] = ($urandom % 4) != 0;
               d[4] = ($urandom % 4) == 0;
               case (phase)
                 1:       begin d[6] = $urandom % 2; d[5] = 1'b0; end         // 00 / 10
                 2:       d[6:5] = 2'b01;
                 3:       d[6:5] = (($urandom % 10) != 0) ? 2'b11 : 2'b10;
                 default: d[6:5] = (($urandom % 2) != 0) ? 2'b11 : 2'b01;
               endcase
             end
        endcase
        data_in <= d;
      end
      case (sel)
        0: a_tlo <= 1'b1;
        1: a_thi <= 1'b1;
        2: a_tcr <= 1'b1;
        3: b_tlo <= 1'b1;
        4: b_thi <= 1'b1;
        default: b_tcr <= 1'b1;
      endcase
    end
  end

  // ---------------------------------------------------------------- reference CNT model
  // independent restatement of a 2-FF synchroniser + edge detect, idle-high on reset
  reg [2:0] m_cnt = 3'b111;
  always @(posedge clk)
    if (reset) m_cnt <= 3'b111;
    else if (clk7_en) m_cnt <= {m_cnt[1:0], cnt};
  wire m_rise  = m_cnt[1] & ~m_cnt[2];
  wire m_level = m_cnt[1];

  // ---------------------------------------------------------------- per-edge comparisons
  integer half_cycles [0:4];
  initial begin : init_hc
    integer k;
    for (k = 0; k < 5; k = k + 1) half_cycles[k] = 0;
  end

  always @(clk) begin
    #1;
    if (phase_ready) begin
      half_cycles[phase] = half_cycles[phase] + 1;
      if (phase != 4) begin
        `CHK(u_new_a.cnt_rise === 1'b0,     "Timer A cnt_rise with CNT idle-high")
        `CHK(u_new_b.cnt_rise === 1'b0,     "Timer B cnt_rise with CNT idle-high")
        `CHK(u_twin_b.cnt_rise === 1'b0,    "Timer B twin cnt_rise with CNT idle-high")
        `CHK(u_new_a.cnt_sync === 3'b111,   "Timer A cnt_sync left 111")
        `CHK(u_new_b.cnt_sync === 3'b111,   "Timer B cnt_sync left 111")
      end
      if (phase == 1 || phase == 3) begin
        `CHK(u_new_a.tmcr[5] === 1'b0,       "precondition: CRA INMODE set")
        `CHK(an_do  === ao_do,               "A data_out differs")
        `CHK(an_irq === ao_irq,              "A irq differs")
        `CHK(an_ovf === ao_ovf,              "A tmra_ovf differs")
        `CHK(an_sp  === ao_sp,               "A spmode differs")
        `CHK(u_new_a.tmr  === u_old_a.tmr,   "A counter differs")
        `CHK(u_new_a.tmcr === u_old_a.tmcr,  "A CRA differs")
        `CHK(bn_do  === bo_do,               "B data_out differs from pre-port")
        `CHK(bn_irq === bo_irq,              "B irq differs from pre-port")
        `CHK(u_new_b.tmr  === u_old_b.tmr,   "B counter differs from pre-port")
        `CHK(u_new_b.tmcr === u_old_b.tmcr,  "B CRB differs from pre-port")
      end
      if (phase == 1)
        `CHK(u_new_b.tmcr[5] === 1'b0,       "precondition: CRB b5 set")
      if (phase == 3) begin
        `CHK(bn_irq === bt_irq,              "B mode 11 irq differs from mode-10 twin")
        `CHK(u_new_b.tmr === u_twin_b.tmr,   "B mode 11 counter differs from mode-10 twin")
        if (b_tcr && !wr)
          `CHK((bn_do & 8'hDF) === (bt_do & 8'hDF), "B CRB read differs from twin (b5 masked)")
        else
          `CHK(bn_do === bt_do,              "B data_out differs from twin")
      end
      if (phase == 2) begin
        if (u_new_a.tmcr[5] === 1'b1)
          `CHK(an_irq === 1'b0 && an_ovf === 1'b0, "A underflowed in CNT mode, CNT idle")
        if (u_new_b.tmcr[6:5] === 2'b01)
          `CHK(bn_irq === 1'b0,              "B underflowed in mode 01, CNT idle")
        // START (bit 0) legitimately differs: the old one-shot timers underflow on eclk
        // and clear it, the new ones never underflow
        `CHK(u_new_a.tmcr[6:1] === u_old_a.tmcr[6:1], "A CRA differs")
        `CHK(u_new_b.tmcr[6:1] === u_old_b.tmcr[6:1], "B CRB differs")
        `CHK(an_sp === ao_sp,                "A spmode differs")
        if ((a_tcr || b_tcr) && !wr)
          `CHK((an_do & 8'hFE) === (ao_do & 8'hFE) && (bn_do & 8'hFE) === (bo_do & 8'hFE),
               "control register read differs")
      end
    end
  end

  // ---------------------------------------------------------------- per-clk7 checks + counters
  integer n_ao_unf [0:4], n_bo_unf [0:4], n_bo_cas [0:4], n_an_unf [0:4], n_bn_unf [0:4];
  integer n_old_a_cntmode = 0, n_old_b_mode01 = 0, n_new_a_cntmode = 0, n_new_b_mode01 = 0;
  integer n_b_mode11 = 0, n_live_a = 0, n_live_b01 = 0, n_live_b11 = 0;
  integer n_live_a_dec = 0, n_live_b01_dec = 0, n_live_b11_dec = 0;
  integer n_frozen_a = 0, n_frozen_b = 0, n_clk7 = 0, n_wr = 0, n_rd = 0;
  initial begin : init_cnt
    integer k;
    for (k = 0; k < 5; k = k + 1) begin
      n_ao_unf[k] = 0; n_bo_unf[k] = 0; n_bo_cas[k] = 0; n_an_unf[k] = 0; n_bn_unf[k] = 0;
    end
  end

  reg        a_hold, b_hold, a_live, b_live01, b_live11;
  reg        a_rise_pre, b_rise_pre, b_gate_pre;
  reg [15:0] a_tmr_pre, b_tmr_pre;

  always @(posedge clk) begin
    // sample pre-edge state (active region, before the DUT nonblocking updates)
    a_hold = 1'b0; b_hold = 1'b0; a_live = 1'b0; b_live01 = 1'b0; b_live11 = 1'b0;
    a_tmr_pre = u_new_a.tmr;
    b_tmr_pre = u_new_b.tmr;
    a_rise_pre = m_rise;
    b_rise_pre = m_rise;
    b_gate_pre = b_ovf_in & m_level;
    if (phase_ready && clk7_en && !reset) begin
      n_clk7 = n_clk7 + 1;
      if (a_tlo | a_thi | a_tcr | b_tlo | b_thi | b_tcr) begin
        if (wr) n_wr = n_wr + 1; else n_rd = n_rd + 1;
      end
      if (ao_irq) n_ao_unf[phase] = n_ao_unf[phase] + 1;
      if (an_irq) n_an_unf[phase] = n_an_unf[phase] + 1;
      if (bo_irq) n_bo_unf[phase] = n_bo_unf[phase] + 1;
      if (bn_irq) n_bn_unf[phase] = n_bn_unf[phase] + 1;
      if (bo_irq && u_old_b.tmcr[6]) n_bo_cas[phase] = n_bo_cas[phase] + 1;
      if (phase == 2) begin
        if (ao_irq && u_old_a.tmcr[5])               n_old_a_cntmode = n_old_a_cntmode + 1;
        if (bo_irq && u_old_b.tmcr[6:5] == 2'b01)    n_old_b_mode01  = n_old_b_mode01 + 1;
        if (an_irq && u_new_a.tmcr[5])               n_new_a_cntmode = n_new_a_cntmode + 1;
        if (bn_irq && u_new_b.tmcr[6:5] == 2'b01)    n_new_b_mode01  = n_new_b_mode01 + 1;
        a_hold = (u_new_a.tmcr[5] === 1'b1) && (u_new_a.reload === 1'b0);
        b_hold = (u_new_b.tmcr[6:5] === 2'b01) && (u_new_b.reload === 1'b0);
      end
      if (phase == 3 && bn_irq && u_new_b.tmcr[6:5] == 2'b11) n_b_mode11 = n_b_mode11 + 1;
      if (phase == 4) begin
        a_live   = (u_new_a.tmcr[5] === 1'b1) && u_new_a.start && (u_new_a.reload === 1'b0);
        b_live01 = (u_new_b.tmcr[6:5] === 2'b01) && u_new_b.start && (u_new_b.reload === 1'b0);
        b_live11 = (u_new_b.tmcr[6:5] === 2'b11) && u_new_b.start && (u_new_b.reload === 1'b0);
        if (an_irq && u_new_a.tmcr[5])            n_live_a   = n_live_a + 1;
        if (bn_irq && u_new_b.tmcr[6:5] == 2'b01) n_live_b01 = n_live_b01 + 1;
        if (bn_irq && u_new_b.tmcr[6:5] == 2'b11) n_live_b11 = n_live_b11 + 1;
      end
    end
    #1;
    if (a_hold) begin
      n_frozen_a = n_frozen_a + 1;
      `CHK(u_new_a.tmr === a_tmr_pre, "A counter moved in CNT mode with CNT idle")
    end
    if (b_hold) begin
      n_frozen_b = n_frozen_b + 1;
      `CHK(u_new_b.tmr === b_tmr_pre, "B counter moved in mode 01 with CNT idle")
    end
    if (a_live) begin
      `CHK(u_new_a.tmr === (a_rise_pre ? a_tmr_pre - 16'd1 : a_tmr_pre),
           "A (INMODE=1) decrement not equal to a CNT rising edge")
      if (a_rise_pre) n_live_a_dec = n_live_a_dec + 1;
    end
    if (b_live01) begin
      `CHK(u_new_b.tmr === (b_rise_pre ? b_tmr_pre - 16'd1 : b_tmr_pre),
           "B (mode 01) decrement not equal to a CNT rising edge")
      if (b_rise_pre) n_live_b01_dec = n_live_b01_dec + 1;
    end
    if (b_live11) begin
      `CHK(u_new_b.tmr === (b_gate_pre ? b_tmr_pre - 16'd1 : b_tmr_pre),
           "B (mode 11) decrement not equal to TA underflow while CNT high")
      if (b_gate_pre) n_live_b11_dec = n_live_b11_dec + 1;
    end
  end

  // ---------------------------------------------------------------- sequencer
  task run_phase(input integer p);
    begin
      phase_ready = 1'b0;
      phase       = p;
      rand_timing = 1'b0;
      reset_hold  = 64;                // >= 16 clk7 cycles, so an eclk passes inside it
      wait (reset_hold == 0);
      @(posedge clk); @(posedge clk);
      phase_ready = 1'b1;
      repeat (HALF) @(posedge clk);
      rand_timing = 1'b1;
      repeat (HALF) @(posedge clk);
    end
  endtask

  task need(input integer v, input [8*64-1:0] what);
    begin
      if (v <= 0) begin
        errors = errors + 1;
        $display("FAIL (vacuous): %0s = %0d", what, v);
      end
    end
  endtask

  initial begin
    run_phase(1);
    run_phase(2);
    run_phase(3);
    run_phase(4);
    phase_ready = 1'b0;

    $display("--- tb_cia_inmode summary ---");
    $display("clk7 cycles checked: %0d   bus reads: %0d   bus writes: %0d", n_clk7, n_rd, n_wr);
    $display("phase 1 (INMODE=0 golden diff): %0d clk cycles (%0d half-cycle compares), A underflows %0d, B underflows %0d (cascade %0d)",
             half_cycles[1] / 2, half_cycles[1], n_ao_unf[1], n_bo_unf[1], n_bo_cas[1]);
    $display("phase 2 (A INMODE=1 / B mode 01, CNT=1): %0d clk cycles; NEW underflows A %0d B %0d; OLD (eclk) underflows on same stimulus A %0d B %0d; frozen-counter checks A %0d B %0d",
             half_cycles[2] / 2, n_new_a_cntmode, n_new_b_mode01, n_old_a_cntmode, n_old_b_mode01, n_frozen_a, n_frozen_b);
    $display("phase 3 (B mode 11 vs pre-port and vs mode-10 twin, CNT=1): %0d clk cycles; B mode-11 underflows %0d, A underflows %0d",
             half_cycles[3] / 2, n_b_mode11, n_an_unf[3]);
    $display("phase 4 (liveness, CNT toggling): %0d clk cycles; A INMODE=1 decrements %0d underflows %0d; B mode 01 decrements %0d underflows %0d; B mode 11 decrements %0d underflows %0d",
             half_cycles[4] / 2, n_live_a_dec, n_live_a, n_live_b01_dec, n_live_b01, n_live_b11_dec, n_live_b11);

    need(n_ao_unf[1],      "phase1 A underflows");
    need(n_bo_unf[1],      "phase1 B underflows");
    need(n_bo_cas[1],      "phase1 B cascade underflows");
    need(n_old_a_cntmode,  "phase2 old A underflows (teeth)");
    need(n_old_b_mode01,   "phase2 old B underflows (teeth)");
    need(n_frozen_a,       "phase2 frozen checks A");
    need(n_frozen_b,       "phase2 frozen checks B");
    need(n_b_mode11,       "phase3 B mode-11 underflows");
    need(n_live_a,         "phase4 A CNT-mode underflows");
    need(n_live_b01,       "phase4 B mode-01 underflows");
    need(n_live_b11,       "phase4 B mode-11 underflows");
    need(n_live_b11_dec,   "phase4 B mode-11 decrements");

    if (errors == 0) begin
      $display("TB RESULT: PASS");
      $finish;
    end else begin
      $display("TB RESULT: FAIL (%0d errors)", errors);
      $fatal(1, "tb_cia_inmode failed");
    end
  end

endmodule
