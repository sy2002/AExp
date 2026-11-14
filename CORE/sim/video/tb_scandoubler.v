`timescale 1ns/1ps
// M2M video_mixer with the scandoubler on (Standard VGA), fed by a modelled
// raster. Run by run_scandoubler.sh, judged by check_scandoubler.py.
//
// GEN = 0: Amiga raster, 1816 clocks per line (one main_clk line), raster
//          events every 4 clocks like clk7_en. The pixel period is P0 clocks
//          up to frame SW and P1 from frame SW on, switched at the start of
//          vsync like the frame-locked enable in main.vhd (hires 2, lowres 4).
// GEN = 1: generic raster of 454 pixels per line, P0 clocks per pixel.
// VLINES lines per frame (313 = PAL), vblank on lines 0..VBEND, vsync on
// lines 3..5. LACE = 1: alternating fields of VLINES and VLINES-1 lines, the
// short field with its vsync at mid-line.
// HBDLY delays HBlank against everything else by 0..7 clocks, the way the
// analog soft blank moves the hblank edges; HBON/HBOFF set the hblank window
// in raster positions (wider window = outward overscan). Two more delays move
// the hblank edges from line to line, so that an input line can be longer than
// the one before it: HBJIT = 1 adds a random delay of 0..3 clocks per line
// (seeded with SEED), STEPD adds a fixed delay from line 0 of frame STEPF on
// (a step, as when the soft-blank geometry changes). VBlank changes with the
// raster event that ends hblank, so it leads a delayed hblank edge; VBDLY > 0
// instead moves both vblank edges to VBDLY clocks after the hblank falling
// edge (HBDLY + VBDLY after the event), as the analog soft blank does.
//
// Each input pixel carries a unique ID {fieldflag, line[8:0], col[9:0]} in
// {B,G,R}. The bench writes trace.txt with change records of the mixer input
// ("I t hblank vblank rgb ok") and of the mixer output ("O t hs vs de ce rgb",
// rgb forced to 0 outside DE) and frame markers ("F t frame"), t = clock count
// since the start. ok is always 1 here (the Minimig raster bench uses it). The
// output log starts three input lines after the input log, so every logged
// output line shows a logged input line.
module tb_scandoubler;
parameter LD       = 1;      // video_mixer LINEDOUBLER
parameter GEN      = 0;
parameter P0       = 4;
parameter P1       = 4;
parameter SW       = 99;
parameter LACE     = 0;
parameter VLINES   = 313;
parameter VBEND    = 25;     // last vblank line
parameter HBDLY    = 0;
parameter HBON     = 25;     // raster position where hblank starts
parameter HBOFF    = 102;    // raster position where hblank ends
parameter HBJIT    = 0;
parameter SEED     = 1;
parameter STEPD    = 0;
parameter STEPF    = 99;
parameter VBDLY    = 0;
parameter LOGFROM  = 2;      // first logged frame
parameter FRAMES   = 3;      // the run stops in this frame ...
parameter STOPLINE = 30;     // ... at the start of this line (past VBEND)

reg clk = 0;
always #17.621 clk = ~clk;

localparam H = GEN ? 454 * P0 : 1816;
reg [12:0] hcnt = 0;
reg [8:0]  vcnt = 0;
reg        lof = 1;               // long field
integer    frame = 0;
reg [3:0]  P = P0;                // current pixel period
reg [3:0]  pc = 0;                // clocks into the current pixel
reg [9:0]  col = 0;
wire       q = GEN ? (pc == 0) : (hcnt[1:0] == 2'd0);    // raster event strobe
wire [9:0] hpos = GEN ? col : hcnt[11:2];
wire [8:0] vtot = (LACE && !lof) ? VLINES - 2 : VLINES - 1;
reg  hs_n = 1, vs_n = 1, hblank = 1, vblank = 1, vs_n_d = 1;
reg  [23:0] pix = 0;
wire newpix = (pc == 0);
reg  [3:0] jit = 0;               // the per-line hblank delay (HBJIT, STEPD)
integer    seed = SEED;

always @(posedge clk) begin
   hcnt <= (hcnt == H - 1) ? 13'd0 : hcnt + 1'd1;
   pc   <= (pc == P - 1 || hcnt == H - 1) ? 4'd0 : pc + 1'd1;
   if (pc == P - 1 || hcnt == H - 1) col <= (hcnt == H - 1) ? 10'd0 : col + 1'd1;
   if (hcnt == H - 1) begin
      if (HBJIT) jit <= $random(seed) & 3;
      if (STEPD != 0 && vcnt == vtot && frame + 1 == STEPF) jit <= STEPD;
      if (vcnt == vtot) begin
         vcnt <= 0; frame <= frame + 1;
         if (LACE) lof <= ~lof;
      end else vcnt <= vcnt + 1'd1;
   end
   if (q) begin
      if (hpos == 37) hs_n <= 0; else if (hpos == 70) hs_n <= 1;
      if (hpos == HBON) hblank <= 1;
      else if (hpos == HBOFF) begin hblank <= 0; vblank <= (vcnt <= VBEND); end
      if (lof) begin
         if (vcnt == 3 && hpos == 37) vs_n <= 0;
         else if (vcnt == 5 && hpos == 264) vs_n <= 1;
      end else begin
         if (vcnt == 2 && hpos == 264) vs_n <= 0;
         else if (vcnt == 5 && hpos == 37) vs_n <= 1;
      end
   end
   // resolution switch at the start of vsync (main.vhd latches frame_hires there)
   vs_n_d <= vs_n;
   if (!GEN && vs_n_d && !vs_n && frame >= SW) P <= P1;
   if (newpix) pix <= {lof, vcnt, col};
end

wire ce = newpix;
reg [15:0] hb_dl = 16'hFFFF;
reg [15:0] vb_dl = 16'hFFFF;
always @(*) hb_dl[0] = hblank;
always @(*) vb_dl[0] = vblank;
always @(posedge clk) begin
   hb_dl[15:1] <= hb_dl[14:0];
   vb_dl[15:1] <= vb_dl[14:0];
end
wire hb_mix = hb_dl[HBDLY + jit];
wire vb_mix = VBDLY ? vb_dl[HBDLY + VBDLY] : vblank;

// AExp's instance in analog_pipeline.vhd: defaults except LINEDOUBLER, hq2x off
wire [7:0] R, G, B;
wire VS, HS, DE, CE_PIXEL;
wire [21:0] gamma_bus;
video_mixer #(.LINEDOUBLER(LD)) dut (
   .CLK_VIDEO(clk), .CE_PIXEL(CE_PIXEL), .ce_pix(ce), .scandoubler(1'b1), .hq2x(1'b0),
   .gamma_bus(gamma_bus),
   .R(pix[7:0]), .G(pix[15:8]), .B(pix[23:16]),
   .HSync(~hs_n), .VSync(~vs_n), .HBlank(hb_mix), .VBlank(vb_mix),
   .HDMI_FREEZE(1'b0), .freeze_sync(),
   .VGA_R(R), .VGA_G(G), .VGA_B(B), .VGA_VS(VS), .VGA_HS(HS), .VGA_DE(DE));

// ------------------------------------------------------------------- trace
integer f;
integer t = 0, out_from = -1, last_frame = -1;
reg [25:0] last_in  = 26'h3FFFFFF;
reg [27:0] last_out = 28'hFFFFFFF;
wire [25:0] cur_in  = {hb_mix, vb_mix, pix};
wire [27:0] cur_out = {HS, VS, DE, CE_PIXEL, DE ? {B, G, R} : 24'h0};
initial begin
   f = $fopen("trace.txt", "w");
   $fwrite(f, "P bench=model LD=%0d GEN=%0d P0=%0d P1=%0d SW=%0d LACE=%0d HBDLY=%0d HBON=%0d HBOFF=%0d HBJIT=%0d SEED=%0d STEPD=%0d STEPF=%0d VBDLY=%0d VLINES=%0d H=%0d\n",
           LD, GEN, P0, P1, SW, LACE, HBDLY, HBON, HBOFF, HBJIT, SEED, STEPD, STEPF, VBDLY, VLINES, H);
end
always @(posedge clk) begin
   t <= t + 1;
   if (frame >= LOGFROM) begin
      if (out_from < 0) out_from <= t + 3 * H;
      if (frame != last_frame) $fwrite(f, "F %0d %0d\n", t, frame);
      last_frame <= frame;
      if (cur_in !== last_in)
         $fwrite(f, "I %0d %0d %0d %h 1\n", t, hb_mix, vb_mix, pix);
      last_in <= cur_in;
      if (out_from >= 0 && t >= out_from) begin
         if (cur_out !== last_out)
            $fwrite(f, "O %0d %0d %0d %0d %0d %h\n", t, HS, VS, DE, CE_PIXEL, DE ? {B, G, R} : 24'h0);
         last_out <= cur_out;
      end
   end
   if (frame == FRAMES && vcnt == STOPLINE) begin
      $fwrite(f, "E %0d\n", t);
      $fclose(f);
      $finish;
   end
end
endmodule
