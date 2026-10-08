// tb_paula_obs.v - golden diff and Copylock timing check for the DSKBYTR
// observation surface in paula_floppy.v (Hardware Floppy; see
// doc/developers/hardware-floppy.md, the Copylock section).
//
//   Part G (golden diff): the current paula_floppy runs beside
//     paula_floppy_ref (the frozen pre-surface module) on identical stimulus.
//     Whenever the surface is disengaged - no physical drive (phys_mask=0),
//     physical unit not selected, or obs_legacy=1 - every output must equal
//     the reference every cycle. ADF reads, trackdisk, X-Copy and the A/B-off
//     arm therefore stay bit-identical to the module without the surface.
//
//   Part C (Copylock): with the physical unit selected, motor on and the
//     surface engaged, a CPU model polls DSKBYTR like the Rob Northen Copylock
//     timing loop (poll WORDEQUAL for the sync, then count poll iterations
//     while reading raw MFM bytes). The byte stream must reconstruct the fed
//     words (hi then lo), WORDEQUAL must fire only on a DSKSYNC match, and a
//     5 % slower sector must take at least 3 % more poll iterations than a
//     5 % faster one, which is the protection's own pass condition. With
//     obs_legacy=1 the difference collapses to 0, which is what makes a
//     Copylock loader hang.
//
//   Part M: properties a broken surface would violate - stuck BYTEREADY,
//     missing clear-on-read, a gate that ignores _sel.
//
// Run: CORE/sim/minimig/run_paula_obs.sh (a few seconds). The runner
// prepares an Icarus-compatible copy of rtl/paula_floppy.v first.

`timescale 1ns/1ps
module tb_paula_obs;

  // register addresses (paula_floppy parameters)
  localparam [8:1] A_DSKBYTR = 9'h01a >> 1;
  localparam [8:1] A_DSKSYNC = 9'h07e >> 1;
  localparam [8:1] A_DSKLEN  = 9'h024 >> 1;
  localparam [8:1] A_DSKDAT  = 9'h026 >> 1;
  localparam [8:1] A_NONE    = 9'h000 >> 1;

  reg clk = 0, clk7_en = 0, clk7n_en = 0, reset = 1;
  reg [1:0] clk7cnt = 0;
  always #5 clk = ~clk;                 // 100 MHz sim clock (ratio only matters)
  always @(posedge clk) begin
    clk7cnt <= clk7cnt + 2'd1;
    clk7_en  <= (clk7cnt == 2'd2);
    clk7n_en <= (clk7cnt == 2'd0);
  end

  // shared inputs
  reg  [8:1] rga = A_NONE;
  reg [15:0] data_in = 0;
  reg        wordsync = 0, ntsc = 0, sof = 0, enable = 1;
  reg  [3:0] _sel = 4'b1111;
  reg        side = 1, _motor = 1;
  reg        io_ena = 0, io_strobe = 0;
  reg [15:0] io_din = 0;
  reg  [3:0] phys_mask = 4'b0000;
  reg        phys_change_n = 1, phys_wprot_n = 1, phys_track0_n = 1;
  reg        phys_ready_n = 1, phys_index = 0;
  reg  [1:0] floppy_drives = 2'b01;

  // observation stimulus (DUT only)
  reg [15:0] obs_word = 0;
  reg        obs_stb = 0;
  reg        obs_legacy = 0;

  // DUT and REF outputs
  wire [15:0] d_out, r_out;
  wire d_dmal,d_dmas,d_t0,d_chg,d_rdy,d_wp,d_idx,d_bi,d_si,d_wait,d_dout_bit,d_led,d_fwr,d_frd;
  wire r_dmal,r_dmas,r_t0,r_chg,r_rdy,r_wp,r_idx,r_bi,r_si,r_wait,r_led,r_fwr,r_frd;
  wire [15:0] d_iodout, r_iodout;
  wire [3:0] d_mot, r_mot;
  wire [7:0] d_trk, r_trk;
  wire [13:0] d_sec, r_sec;

  // ---- DUT: the current paula_floppy ----
  paula_floppy dut (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(reset),
    .ntsc(ntsc), .sof(sof), .enable(enable),
    .reg_address_in(rga), .data_in(data_in), .data_out(d_out),
    .dmal(d_dmal), .dmas(d_dmas),
    ._step(), .direc(1'b0), ._sel(_sel), .side(side), ._motor(_motor),
    ._track0(d_t0), ._change(d_chg), ._ready(d_rdy), ._wprot(d_wp), .index(d_idx),
    .blckint(d_bi), .syncint(d_si), .wordsync(wordsync),
    .IO_ENA(io_ena), .IO_STROBE(io_strobe), .IO_WAIT(d_wait),
    .IO_DIN(io_din), .IO_DOUT(d_iodout),
    .fdd_led(d_led), .floppy_drives(floppy_drives),
    .phys_mask(phys_mask), .phys_change_n(phys_change_n), .phys_wprot_n(phys_wprot_n),
    .phys_track0_n(phys_track0_n), .phys_ready_n(phys_ready_n), .phys_index(phys_index),
    .motor_on_o(d_mot), .fdd_dsig(), .fdd_datt(), .fdd_dc64(), .fdd_dc256(),
    .fdd_dtap(), .fdd_dws(),
    .obs_word(obs_word), .obs_stb(obs_stb), .obs_legacy(obs_legacy),
    .trackdisp(d_trk), .secdisp(d_sec), .floppy_fwr(d_fwr), .floppy_frd(d_frd)
  );

  // ---- REF: the frozen paula_floppy without the surface (no obs ports) ----
  paula_floppy_ref refm (
    .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(reset),
    .ntsc(ntsc), .sof(sof), .enable(enable),
    .reg_address_in(rga), .data_in(data_in), .data_out(r_out),
    .dmal(r_dmal), .dmas(r_dmas),
    ._step(), .direc(1'b0), ._sel(_sel), .side(side), ._motor(_motor),
    ._track0(r_t0), ._change(r_chg), ._ready(r_rdy), ._wprot(r_wp), .index(r_idx),
    .blckint(r_bi), .syncint(r_si), .wordsync(wordsync),
    .IO_ENA(io_ena), .IO_STROBE(io_strobe), .IO_WAIT(r_wait),
    .IO_DIN(io_din), .IO_DOUT(r_iodout),
    .fdd_led(r_led), .floppy_drives(floppy_drives),
    .phys_mask(phys_mask), .phys_change_n(phys_change_n), .phys_wprot_n(phys_wprot_n),
    .phys_track0_n(phys_track0_n), .phys_ready_n(phys_ready_n), .phys_index(phys_index),
    .motor_on_o(r_mot), .fdd_dsig(), .fdd_datt(), .fdd_dc64(), .fdd_dc256(),
    .fdd_dtap(), .fdd_dws(),
    .trackdisp(r_trk), .secdisp(r_sec), .floppy_fwr(r_fwr), .floppy_frd(r_frd)
  );

  integer errors = 0;
  reg golden = 0;   // when 1, assert DUT==REF every cycle (gate-off regimes)

  wire diff = (d_out!==r_out)|(d_dmal!==r_dmal)|(d_dmas!==r_dmas)|(d_t0!==r_t0)|
              (d_chg!==r_chg)|(d_rdy!==r_rdy)|(d_wp!==r_wp)|(d_idx!==r_idx)|
              (d_bi!==r_bi)|(d_si!==r_si)|(d_wait!==r_wait)|(d_iodout!==r_iodout)|
              (d_mot!==r_mot)|(d_led!==r_led)|(d_trk!==r_trk)|(d_sec!==r_sec)|
              (d_fwr!==r_fwr)|(d_frd!==r_frd);
  always @(posedge clk) begin
    if (golden && !reset && diff) begin
      $display("  GOLDEN DIFF at %0t: d_out=%h r_out=%h si(d/r)=%b/%b bi=%b/%b iodout=%h/%h",
               $time, d_out, r_out, d_si, r_si, d_bi, r_bi, d_iodout, r_iodout);
      errors = errors + 1;
    end
  end

  // ---- helpers ----
  task wr; input [8:1] a; input [15:0] v; begin
    // present the register address+data and HOLD it across a clk7_en tick so
    // the (clk7_en-gated) write actually captures it, then release.
    rga=a; data_in=v;
    @(posedge clk); while(!clk7_en) @(posedge clk); @(posedge clk);
    rga=A_NONE; end
  endtask
  // one DSKBYTR read: present the address for a CCK, sample, then release
  // (release edge is what advances the observation byte). returns d_out sample.
  reg [15:0] rdsample;
  // drive the register address cleanly on the NEGEDGE (real reg_address_in is
  // synchronous logic; driving it at a posedge would race the DUT's own
  // posedge sampling - a pure testbench artifact). One access = one posedge
  // with the address present (sample there), then release; the DUT advances
  // its observation byte on the address falling edge.
  task rd_dskbytr; begin
    @(negedge clk); rga=A_DSKBYTR;
    @(posedge clk); rdsample = d_out;      // address present, data stable
    @(negedge clk); rga=A_NONE;
    @(posedge clk);                        // clean 1->0: obs_rd_end advances the byte
  end endtask

  // select physical unit 1 (motor on): _motor low, pulse _sel[1] to latch
  task select_unit1_motoron; begin
    _motor = 0; _sel = 4'b1111;
    @(posedge clk); wait(clk7_en); @(posedge clk);
    _sel = 4'b1101;                       // falling edge on _sel[1] latches motor_on_1
    repeat(8) @(posedge clk);
  end endtask
  task deselect; begin _sel = 4'b1111; repeat(8) @(posedge clk); end endtask

  // random register-traffic driver for the golden phase
  integer gi; reg [15:0] rnd;
  task random_traffic; input integer n; begin
    for (gi=0; gi<n; gi=gi+1) begin
      rnd = $random;
      case (rnd[2:0])
        0: wr(A_DSKLEN, {2'b10, rnd[13:0]});   // dsklen with dmaen path
        1: wr(A_DSKSYNC, rnd);
        2: wr(A_DSKDAT, rnd);
        3: rd_dskbytr;
        4: begin @(posedge clk); wait(clk7_en); rga=A_DSKLEN; @(posedge clk); rga=A_NONE; end
        5: begin wordsync = rnd[3]; @(posedge clk); end
        default: begin @(posedge clk); wait(clk7_en); @(posedge clk); end
      endcase
      // occasionally pulse an obs word (DUT-only; must not affect gate-off outputs)
      if (rnd[7:5]==3'b101) begin obs_word = rnd; obs_stb = 1; @(posedge clk); #1 obs_stb = 0; end
    end
  end endtask

  // ---- Copylock CPU model (deterministic, single loop) ----
  // Models the real Rob Northen loop: each iteration is one DSKBYTR poll; a
  // fresh word from the disk becomes available every `cadence` polls (a
  // 5%-slower sector => larger cadence => more poll iterations = the "time").
  // Faithful to the DUT: the observation byte FSM advances on reads, so poll
  // iterations vs word arrivals is exactly what silicon would experience.
  // Returns the total poll count and captures the raw MFM byte stream.
  integer polls; integer bytesread;
  reg [7:0] capbytes [0:2047];
  reg wordeq_seen;
  task feed_word; input [15:0] w; begin
    obs_word = w; obs_stb = 1; @(posedge clk); #1 obs_stb = 0; end
  endtask
  task run_sector; input [15:0] baseword; input integer nwords; input integer cadence;
                   input integer readbytes;
    integer wi, since, pc; begin
    polls = 0; bytesread = 0; wordeq_seen = 0; wi = 0; since = cadence;
    // WORDEQUAL wait: poll until the sync word passes under the head
    pc = 0;
    while (!wordeq_seen && pc < 200000) begin
      if (since >= cadence && wi < nwords) begin feed_word(baseword + wi[15:0]); wi=wi+1; since=0; end
      rd_dskbytr; pc = pc + 1; since = since + 1;
      if (rdsample[12]) wordeq_seen = 1;
    end
    // count poll iterations while reading `readbytes` raw bytes
    while (bytesread < readbytes && polls < 500000) begin
      if (since >= cadence && wi < nwords) begin feed_word(baseword + wi[15:0]); wi=wi+1; since=0; end
      rd_dskbytr; polls = polls + 1; since = since + 1;
      if (rdsample[15]) begin capbytes[bytesread] = rdsample[7:0]; bytesread = bytesread + 1; end
    end
  end endtask

  integer k; integer cnt_short, cnt_long, cnt_short_off, cnt_long_off;
  real ratio_on, ratio_off;
  reg [15:0] SYNCW = 16'h8911;

  initial begin
    // reset
    repeat(20) @(posedge clk); reset = 0; repeat(8) @(posedge clk);
    wr(A_DSKSYNC, SYNCW);

    // ================= PART G: golden diff (no regression) =================
    // G0: no physical drive -> everything identical
    golden = 1; phys_mask = 4'b0000; obs_legacy = 0;
    random_traffic(150);
    // G1: physical unit present but not selected -> identical
    phys_mask = 4'b0010; deselect; random_traffic(100);
    // G2: physical unit selected+motor, but obs_legacy=1 (surface off) -> identical
    select_unit1_motoron; obs_legacy = 1;
    // pump obs words too; must not perturb outputs while legacy=1
    for (k=0;k<200;k=k+1) begin obs_word=$random; obs_stb=1; @(posedge clk); obs_stb=0; rd_dskbytr; end
    random_traffic(80);
    golden = 0; obs_legacy = 0; deselect;
    if (errors==0) $display("PASS  PART G golden diff: DUT equals the reference in all gate-off regimes");
    else           $display("FAIL  PART G golden diff: %0d cycle mismatches", errors);

    // ================= PART C: Copylock timing =================
    // engage the surface: physical unit 1 selected + motor on, surface on.
    // (re-write DSKSYNC: PART G's random traffic left it at a random value)
    wr(A_DSKSYNC, SYNCW);
    select_unit1_motoron; obs_legacy = 0; wordsync = 1;

    // SHORT sector: words arrive fast. Fed words: 8911(sync),8912,8913,...
    run_sector(16'h8911, 300, 20, 200); cnt_short = polls;
    // WORDSYNC=1: the sync word 8911 is swallowed (real-Paula reframe), so the
    // first delivered word is the post-sync word 8912. Verify the stream from
    // there, and assert that buffer[0..1] is the post-sync word (the Copylock
    // sector index), not the sync word: a loader that finds the sync word there
    // loops forever in its index check.
    check_bytes(16'h8912);
    if (capbytes[0]==8'h89 && capbytes[1]==8'h11) begin
      $display("FAIL  PART C: buffer[0..1]=8911 (sync word), Copylock index check would loop forever"); errors=errors+1;
    end else if (capbytes[0]==8'h89 && capbytes[1]==8'h12) begin
      $display("PASS  PART C: WORDSYNC swallow - buffer[0..1]=8912 = the first post-sync word (Copylock index check passes)");
    end else begin
      $display("FAIL  PART C: unexpected buffer start %h %h", capbytes[0], capbytes[1]); errors=errors+1;
    end
    // check WORDEQUAL fired on the sync word
    if (!wordeq_seen) begin $display("FAIL  PART C: WORDEQUAL never seen on DSKSYNC"); errors=errors+1; end

    // LONG sector: same words, 5% slower cadence (period 63).
    run_sector(16'h8911, 300, 21, 200); cnt_long = polls;

    ratio_on = (cnt_long - cnt_short) * 100.0 / cnt_short;
    $display("  Copylock surface on : short=%0d long=%0d  ratio=%0.2f%% (need >=3%%)",
             cnt_short, cnt_long, ratio_on);
    if (ratio_on >= 3.0) $display("PASS  PART C: surface on reproduces the >=3%% short/long timing ratio -> Copylock passes");
    else begin $display("FAIL  PART C: surface on ratio %0.2f%% < 3%%", ratio_on); errors=errors+1; end

    // surface off (constant stub): BYTEREADY stuck 1 -> byte count equals iteration count -> ratio ~0
    obs_legacy = 1;
    run_sector(16'h8911, 300, 20, 200); cnt_short_off = polls;
    run_sector(16'h8911, 300, 21, 200); cnt_long_off = polls;
    ratio_off = (cnt_long_off - cnt_short_off) * 100.0 / cnt_short_off;
    $display("  Copylock surface off: short=%0d long=%0d  ratio=%0.2f%% (the hang)",
             cnt_short_off, cnt_long_off, ratio_off);
    if (ratio_off < 1.0) $display("PASS  PART C: surface off collapses the ratio (<1%%) -> reproduces the hang");
    else begin $display("FAIL  PART C: surface off ratio %0.2f%% not collapsed", ratio_off); errors=errors+1; end
    obs_legacy = 0;

    // ================= PART M: properties of a correct surface =================
    // M1: clear-on-read - after reading both bytes of one word with no new word,
    //     BYTEREADY must go 0 (a stuck-1 surface fails this).
    wordsync = 0;
    obs_word = 16'h1234; obs_stb = 1; @(posedge clk); #1 obs_stb = 0; repeat(4) @(posedge clk);
    rd_dskbytr; if (!rdsample[15]) begin $display("FAIL  M1a: first byte not ready"); errors=errors+1; end
    if (rdsample[7:0]!==8'h12) begin $display("FAIL  M1b: high byte %h != 12", rdsample[7:0]); errors=errors+1; end
    rd_dskbytr; if (rdsample[7:0]!==8'h34) begin $display("FAIL  M1c: low byte %h != 34", rdsample[7:0]); errors=errors+1; end
    rd_dskbytr; if (rdsample[15]) begin $display("FAIL  M1d: BYTEREADY stuck 1 after both bytes (no clear-on-read)"); errors=errors+1; end
    else $display("PASS  PART M1: clear-on-read + 2-byte order (hi,lo) correct");
    // M2: WORDEQUAL must reflect the actual DSKSYNC match, not stuck 1
    wr(A_DSKSYNC, 16'h4489);
    obs_word = 16'hAAAA; obs_stb = 1; @(posedge clk); #1 obs_stb = 0; repeat(4) @(posedge clk);
    rd_dskbytr; if (rdsample[12]) begin $display("FAIL  M2: WORDEQUAL=1 on non-matching word (stuck)"); errors=errors+1; end
    else $display("PASS  PART M2: WORDEQUAL low when obs_word != DSKSYNC");
    // M3: gate must require SELECT - deselect and confirm the stub returns (bit15=1,bit12=1,data=0)
    deselect;
    rd_dskbytr;
    if (rdsample[15]==1'b1 && rdsample[12]==1'b1 && rdsample[7:0]==8'h00)
      $display("PASS  PART M3: deselected physical unit falls back to the stub (no gate leak)");
    else begin $display("FAIL  M3: deselected gate leak, dskbytr=%h", rdsample); errors=errors+1; end

    if (errors==0) $display("\nTB_PAULA_OBS: ALL CHECKS PASS");
    else           $display("\nTB_PAULA_OBS: %0d FAILURE(S)", errors);
    $finish;
  end

  // verify the captured bytes are the exact consecutive hi,lo,hi,lo... MFM
  // byte stream of consecutive words from `first`. With the WORDSYNC swallow
  // the delivered stream starts deterministically at the first post-sync word,
  // byte offset 0 - no auto-detect needed.
  integer bad;
  task check_bytes; input [15:0] first; integer i; reg [15:0] w; reg [7:0] exp; begin
    bad = 0;
    for (i=0; i<bytesread-2; i=i+1) begin
      w = first + (i/2);
      exp = (i & 1)==0 ? w[15:8] : w[7:0];
      if (capbytes[i] !== exp) bad = bad + 1;
    end
    if (bad==0) $display("PASS  PART C: %0d observed bytes reconstruct the post-sync words (hi,lo order)", bytesread);
    else begin $display("FAIL  PART C: byte stream mismatch (%0d bad, bytesread=%0d, capbytes[0..3]=%h %h %h %h)",
                        bad, bytesread, capbytes[0], capbytes[1], capbytes[2], capbytes[3]); errors=errors+1; end
  end endtask

endmodule
