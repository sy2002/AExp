`timescale 1ns/1ps
// M2M video_mixer with the scandoubler on (Standard VGA), fed by the raster
// of the real Minimig amiga_clk.v and agnus_beamcounter.v (PAL, 1816 clocks
// per line, 313 lines) at main_clk, with the frame-locked pixel enable of
// main.vhd (video_ce_proc): frame_hires latches at the start of vsync whether
// the previous frame had a hires line, and the enable is clk7_en, plus
// clk7n_en in hires frames. Run by run_scandoubler.sh, judged by
// check_scandoubler.py.
//
// SCHED gives the content of each frame (frame 0 first, the last letter
// repeats): L lowres, H hires, M mixed (lowres above line MIXSPLIT, hires
// from it on). A frame counts from one start of vsync to the next, like
// frame_hires. The content of a frame reaches the hires rate one frame later,
// so hires content in a frame at the lowres rate is undersampled by the core
// itself: those input pixels are flagged ok = 0 and the checker skips them.
// Frame 0 lasts one clock: _vsync powers up low (Vivado INIT = 0), so the
// first start of vsync, which latches frame_hires, is at t = 0, as in the
// FPGA. FH0 = 1 powers fs_res up as if the frame before had a hires line
// (main.vhd: 0), so that frame 1 already runs at the hires rate.
//
// Each hires column carries a unique ID: R = col[7:0],
// G = {vpos[5:0], col[9:8]}, B = {frame[1:0], hires, vpos[8:6], 2'b01},
// col = 2 * hpos + the half of the lowres slot (always 0 on lowres lines, so
// a lowres pixel lasts four clocks). PIXD delays RGB (and its ok flag) by
// 0..8 clocks, HBOFS delays HBlank by 0..16 clocks (soft-blank model).
//
// trace.txt: the same records as tb_scandoubler.v, the frame markers as
// "F t frame frame_hires content". The trace starts in frame LOGFROM once the
// Amiga reset is released, and the run stops in frame NFRAMES at line 8.
module tb_scandoubler_minimig;
parameter LD       = 1;        // video_mixer LINEDOUBLER
parameter PIXD     = 0;
parameter HBOFS    = 0;
parameter NFRAMES  = 4;
parameter LOGFROM  = 1;        // first logged frame
parameter MIXSPLIT = 160;
parameter SCHED    = "LLHH";
parameter FH0      = 0;

localparam NS = $bits(SCHED) / 8;
localparam H  = 1816;

reg clk = 0;
always #17.621 clk = ~clk;     // main_clk, 28.375 MHz

// ---------------------------------------------------------------- Minimig raster
reg reset_n = 0;
reg reset   = 1;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk uclk (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                .cck(cck), .eclk(eclk), .reset_n(reset_n));

wire [8:0]  hpos;
wire [10:0] vpos;
wire _hsync, _vsync, field1, lace, _csync, hblank, vblank, vbl, vblend, eol, eof, vbl_int;
wire [15:0] bc_dout;
wire [8:0]  htotal_out;
wire harddis_out, varbeamen_out;
agnus_beamcounter bc (
   .clk(clk), .clk7_en(clk7_en), .reset(reset), .cck(cck), .ntsc(1'b0), .aga(1'b0), .ecs(1'b0), .a1k(1'b0),
   .data_in(16'h0000), .data_out(bc_dout), .reg_address_in(8'hFF),       // 0x1FE: no register
   .hpos(hpos), .vpos(vpos), ._hsync(_hsync), ._vsync(_vsync), .field1(field1), .lace(lace), ._csync(_csync),
   .hblank(hblank), .vblank(vblank), .vbl(vbl), .vblend(vblend), .eol(eol), .eof(eof), .vbl_int(vbl_int),
   .htotal_out(htotal_out), .harddis_out(harddis_out), .varbeamen_out(varbeamen_out));

// FPGA power-up state: registers without a reset start at 0 (Vivado INIT = 0)
initial begin
   bc.hpos_hi = 0; bc.vpos = 0; bc.end_of_line = 0; bc.vpos_inc = 0; bc.long_line = 0;
   bc.extra_line = 0; bc._hsync = 1'b0; bc._vsync = 1'b0; bc.hblank = 0; bc.vblank = 0;
   bc.vbl_int = 0; bc.vser = 0;
end
initial begin
   repeat (5) @(posedge clk);
   reset_n = 1;
   repeat (40) @(posedge clk);
   reset = 0;
end

// ------------------------------------------------------ frame schedule, content
integer frame = 0;
reg [7:0] ctype;
always @(*) begin
   if (frame < NS) ctype = SCHED[8*(NS-1-frame) +: 8];
   else            ctype = SCHED[7:0];
end
wire line_hires = (ctype == "H") || (ctype == "M" && vpos >= MIXSPLIT);

// main.vhd: vid_vs <= not vsync_n; frame_hires latches at the start of vsync
// from the OR of res(0) over the active area of the frame before
wire vid_vs = ~_vsync;
reg  vid_vs_d = 0;
reg  [1:0] fs_res = FH0 ? 2'b01 : 2'b00;
reg  frame_hires = 0;
wire [1:0] vid_res = {1'b0, line_hires};
always @(posedge clk) begin
   if (!hblank && !vblank) fs_res <= fs_res | vid_res;
   vid_vs_d <= vid_vs;
   if (vid_vs && !vid_vs_d) begin
      frame_hires <= fs_res[0];
      fs_res      <= 2'b00;
      frame       <= frame + 1;
   end
end
wire ce = clk7_en | (clk7n_en & frame_hires);

// Denise-like pixel stream: the hires shifter steps at the clk7_en/clk7n_en
// edges; hpos is constant over clk7_cnt = 2, 3, 0, 1
wire [1:0] k    = uclk.clk7_cnt;
wire       half = line_hires ? (k == 2'd0 || k == 2'd1) : 1'b0;
wire [9:0] col  = {hpos, 1'b0} + half;
wire [24:0] id0 = {line_hires && !frame_hires ? 1'b0 : 1'b1,
                   frame[1:0], line_hires, vpos[8:6], 2'b01, vpos[5:0], col[9:8], col[7:0]};
reg  [8*25-1:0] idp = 0;     // idp[25*n +: 25] = id0 delayed by n + 1 clocks
always @(posedge clk) idp <= {idp[7*25-1:0], id0};
wire [24:0] pixd = (PIXD == 0) ? id0 : idp[25*(PIXD-1) +: 25];
wire [23:0] rgb  = pixd[23:0];
wire        rgb_ok = pixd[24];

reg [15:0] hbd = 16'hFFFF;
always @(posedge clk) hbd <= {hbd[14:0], hblank};
wire hb_mix = (HBOFS == 0) ? hblank : hbd[HBOFS-1];

// AExp's instance in analog_pipeline.vhd: defaults except LINEDOUBLER, hq2x off
wire [21:0] gbus;
wire CE_PIXEL, VS, HS, DE;
wire [7:0] R, G, B;
video_mixer #(.LINEDOUBLER(LD)) mix (
   .CLK_VIDEO(clk), .CE_PIXEL(CE_PIXEL), .ce_pix(ce), .scandoubler(1'b1), .hq2x(1'b0),
   .gamma_bus(gbus), .R(rgb[7:0]), .G(rgb[15:8]), .B(rgb[23:16]),
   .HSync(~_hsync), .VSync(~_vsync), .HBlank(hb_mix), .VBlank(vblank),
   .HDMI_FREEZE(1'b0), .freeze_sync(),
   .VGA_R(R), .VGA_G(G), .VGA_B(B), .VGA_VS(VS), .VGA_HS(HS), .VGA_DE(DE));

// ------------------------------------------------------------------------ trace
integer f;
integer t = 0, out_from = -1, last_frame = -1;
reg [26:0] last_in  = 27'h7FFFFFF;
reg [27:0] last_out = 28'hFFFFFFF;
wire [26:0] cur_in  = {hb_mix, vblank, rgb_ok, rgb};
wire [27:0] cur_out = {HS, VS, DE, CE_PIXEL, DE ? {B, G, R} : 24'h0};
initial begin
   f = $fopen("trace.txt", "w");
   $fwrite(f, "P bench=minimig LD=%0d PIXD=%0d HBOFS=%0d SCHED=%s MIXSPLIT=%0d FH0=%0d H=%0d\n",
           LD, PIXD, HBOFS, SCHED, MIXSPLIT, FH0, H);
end
always @(posedge clk) begin
   t <= t + 1;
   if (frame >= LOGFROM && !reset) begin
      if (out_from < 0) out_from <= t + 3 * H;
      if (frame != last_frame) $fwrite(f, "F %0d %0d %0d %s\n", t, frame, frame_hires, ctype);
      last_frame <= frame;
      if (cur_in !== last_in)
         $fwrite(f, "I %0d %0d %0d %h %0d\n", t, hb_mix, vblank, rgb, rgb_ok);
      last_in <= cur_in;
      if (out_from >= 0 && t >= out_from) begin
         if (cur_out !== last_out)
            $fwrite(f, "O %0d %0d %0d %0d %0d %h\n", t, HS, VS, DE, CE_PIXEL, DE ? {B, G, R} : 24'h0);
         last_out <= cur_out;
      end
   end
   if (frame == NFRAMES && vpos == 8) begin
      $fwrite(f, "E %0d\n", t);
      $fclose(f);
      $finish;
   end
end
endmodule
