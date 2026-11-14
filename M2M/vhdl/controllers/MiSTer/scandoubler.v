//
// scandoubler.v
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2017-2021 Alexey Melnikov
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 

// TODO: Delay vsync one line

module scandoubler #(
    parameter LENGTH     = 768,
    parameter HALF_DEPTH = 0,
    // M2M-UPSTREAM line-doubler (AExp 2026-10-10): 0 = MiSTer's Hq2x does the
    // line doubling and needs clk_vid >= 4 x the pixel rate of ce_pix. 1 = the
    // plain line doubler at the end of this file does it and needs only 2 x
    // (no hq2x filter in this mode).
    parameter LINEDOUBLER = 0,
    localparam DWIDTH = HALF_DEPTH ? 3 : 7
)
(
	// system interface
	input             clk_vid,
	input             hq2x,

	// shifter video interface
	input             ce_pix,
	input             hs_in,
	input             vs_in,
	input             hb_in,
	input             vb_in,
	input  [DWIDTH:0] r_in,
	input  [DWIDTH:0] g_in,
	input  [DWIDTH:0] b_in,

	// output interface
	output            ce_pix_out,
	output reg        hs_out,
	output            vs_out,
	output            hb_out,
	output            vb_out,
	output [DWIDTH:0] r_out,
	output [DWIDTH:0] g_out,
	output [DWIDTH:0] b_out
);

// M2M-UPSTREAM line-doubler: 1-bit form of LINEDOUBLER, so that every use
// below agrees for any non-zero value
localparam [0:0] LD = (LINEDOUBLER != 0);

reg  [7:0] pix_len = 0;
wire [7:0] pl = pix_len + 1'b1;

reg  [7:0] pix_in_cnt = 0;
wire [7:0] pc_in = pix_in_cnt + 1'b1;
reg  [7:0] pixsz, pixsz2, pixsz4 = 0;

reg ce_x4i, ce_x1i;
always @(posedge clk_vid) begin
	reg old_ce, valid, hs;

	if(~&pix_len) pix_len <= pl;
	if(~&pix_in_cnt) pix_in_cnt <= pc_in;

	ce_x4i <= 0;
	ce_x1i <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_in == pixsz4) || (pc_in == pixsz2) || (pc_in == (pixsz2+pixsz4))) ce_x4i <= 1;

	old_ce <= ce_pix;
	if(~old_ce & ce_pix) begin
		// M2M-UPSTREAM line-doubler: with LINEDOUBLER the pixel period is also
		// measured in the vblank lines, so that a pixel rate switched at the
		// start of vsync is in effect from the first active pixel on. This needs
		// a regular ce_pix during vblank.
		if(valid & ~hb_in & (~vb_in | LD)) begin
			pixsz  <= pl;
			pixsz2 <= {1'b0,  pl[7:1]};
			pixsz4 <= {2'b00, pl[7:2]};
		end
		pix_len <= 0;
		valid <= 1;
	end

	hs <= hs_in;
	if((~hs & hs_in) || (pc_in >= pixsz)) begin
		ce_x4i <= 1;
		ce_x1i <= 1;
		pix_in_cnt <= 0;
	end

	if(hb_in | (vb_in & ~LD)) valid <= 0;
end

reg req_line_reset;
reg [DWIDTH:0] r_d, g_d, b_d;
always @(posedge clk_vid) begin
	if(ce_x1i) begin
		req_line_reset <= hb_in;
		r_d <= r_in;
		g_d <= g_in;
		b_d <= b_in;
	end
end

reg ce_x4o, ce_x2o;
reg [1:0] sd_line;
reg [3:0] vbo;
reg [3:0] vso;
reg [8:0] hbo;
reg       ld_line_start;
reg       ld_second = 0, ld_early = 0;
reg [15:0] ld_vbs = 0;

// M2M-UPSTREAM line-doubler: LINEDOUBLER selects the plain line doubler
// instead of Hq2x. It writes one pixel per ce_x1i and reads one per ce_x2o.
generate
if (LD) begin : g_linedoubler
	linedoubler #(.LENGTH(LENGTH), .DWIDTH(DWIDTH*3+2)) linedoubler
	(
		.clk(clk_vid),

		.ce_in(ce_x1i),
		.hb_in(req_line_reset),
		.pix_in({b_d,g_d,r_d}),
		.line_start(ld_line_start),

		.ce_out(ce_x2o),
		.hb_out(hbo[6]),
		.pix_out({b_out,g_out,r_out})
	);
end else begin : g_hq2x
	Hq2x #(.LENGTH(LENGTH), .HALF_DEPTH(HALF_DEPTH)) Hq2x
	(
		.clk(clk_vid),

		.ce_in(ce_x4i),
		.inputpixel({b_d,g_d,r_d}),
		.disable_hq2x(~hq2x),
		.reset_frame(vb_in),
		.reset_line(req_line_reset),

		.ce_out(ce_x4o),
		.read_y(sd_line),
		.hblank(hbo[0]&hbo[8]),
		.outpixel({b_out,g_out,r_out})
	);
end
endgenerate

reg  [7:0] pix_out_cnt = 0;
wire [7:0] pc_out = pix_out_cnt + 1'b1;

always @(posedge clk_vid) begin
	reg hs;

	if(~&pix_out_cnt) pix_out_cnt <= pc_out;

	ce_x4o <= 0;
	ce_x2o <= 0;

	// use such odd comparison to place ce_x4 evenly if master clock isn't multiple of 4.
	if((pc_out == pixsz4) || (pc_out == pixsz2) || (pc_out == (pixsz2+pixsz4))) ce_x4o <= 1;
	if( pc_out == pixsz2) ce_x2o <= 1;

	hs <= hs_out;
	if((~hs & hs_out) || (pc_out >= pixsz)) begin
		ce_x2o <= 1;
		ce_x4o <= 1;
		pix_out_cnt <= 0;
	end
end

always @(posedge clk_vid) begin

	reg [31:0] hcnt;
	reg [30:0] sd_hcnt;
	reg [30:0] hs_start, hs_end;
	reg [30:0] hde_start, hde_end;

	reg hs, hb;

	ld_line_start <= 0;

	// M2M-UPSTREAM line-doubler: vb_in is sampled again 16 clocks after the
	// input active start. A vblank edge that trails the hblank edge by a few
	// clocks (the analog soft blank changes vblank one clock after its hblank
	// falls) is then attributed to the right input line. The core's own
	// vblank changes together with hblank, so the second sample equals the
	// first there.
	ld_vbs <= {ld_vbs[14:0], 1'b0};
	if(LD & ld_vbs[15]) vbo[0] <= vb_in;

	if(ce_x4o) begin
		hbo[8:1] <= hbo[7:0];
	end

	// output counter synchronous to input and at twice the rate
	sd_hcnt <= sd_hcnt + 1'd1;
	if(sd_hcnt == hde_start) begin
		sd_hcnt <= 0;
		vbo[3:1] <= vbo[2:0];

		// M2M-UPSTREAM line-doubler: the first of these window starts within an
		// input line opens the second output copy. A further one opens the first
		// copy of the next line ahead of its input active start, which happens
		// when that input line is longer than the previous one; the line doubler
		// swaps its halves there, and not again at the input active start.
		if(ld_second & ~ld_early) begin
			ld_line_start <= 1;
			ld_early <= 1;
		end
		ld_second <= 1;
	end

	if(sd_hcnt == hs_end) begin
		sd_line <= sd_line + 1'd1;
		if(&vbo[3:2]) sd_line <= 1;
		vso[3:1] <= vso[2:0];
	end

	if(sd_hcnt == hde_start)hbo[0] <= 0;
	if(sd_hcnt == hde_end)  hbo[0] <= 1;

	// replicate horizontal sync at twice the speed
	if(sd_hcnt == hs_end)   hs_out <= 0;
	if(sd_hcnt == hs_start) hs_out <= 1;

	hs <= hs_in;
	hb <= hb_in;

	hcnt <= hcnt + 1'd1;
	if(hb && !hb_in) begin
		ld_line_start <= ~ld_early;
		ld_early <= 0;
		ld_second <= 0;
		ld_vbs[0] <= 1;
		hde_start <= hcnt[31:1];
		hbo[0] <= 0;
		hcnt <= 0;
		sd_hcnt <= 0;
		vbo <= {vbo[2:0],vb_in};
	end

	if(!hb && hb_in) hde_end <= hcnt[31:1];

	// falling edge of hsync indicates start of line
	if(hs && !hs_in) begin
		hs_end <= hcnt[31:1];
		vso[0] <= vs_in;
	end

	// save position of rising edge
	if(!hs && hs_in) hs_start <= hcnt[31:1];
end

// M2M-UPSTREAM line-doubler: the line doubler shows input line L on the two
// output lines that start with input line L+1 (latency one input line), Hq2x
// half an input line later. The vsync and vblank delay lines are therefore
// tapped one output line earlier with LINEDOUBLER.
assign vs_out = LD ? vso[2] : vso[3];
assign ce_pix_out = hq2x ? ce_x4o : ce_x2o;

//Compensate picture shift after HQ2x
assign vb_out = LD ? vbo[2] : vbo[3];
assign hb_out = hbo[6];

endmodule

////////////////////////////////////////////////////////////////////////////////////////////////////////

// M2M-UPSTREAM line-doubler (AExp 2026-10-10): plain line doubler, used by
// scandoubler instead of Hq2x when LINEDOUBLER = 1.
//
// One input pixel per ce_in (ce_x1i) is written into one half of a two-line
// buffer while the other half, the previous complete input line, is read
// twice, one pixel per ce_out (ce_x2o, the output pixel enable). It therefore
// works down to clk >= 2 x the input pixel rate, where Hq2x needs 4 x because
// it spends four ce_in on every input pixel.
//
// Each half spans the full address range of LENGTH (1024 entries for LENGTH
// 513..1024). A whole input line including its blanking fits, also when an
// analog overscan widens the active window beyond LENGTH. Both halves are
// distributed RAM.
//
// Write: address 0 is the first pixel sampled with hblank low; the address
// saturates at the top. The write half is the one not being read, including
// the clock in which the halves swap (line_start), because the swap and the
// first write of a line can fall on the same clock when the hblank edge moves.
// Read: the halves swap when the output window of the first copy of a line
// opens (line_start): at the input active start, the event that restarts the
// output line timing, or earlier when the scandoubler opens that window ahead
// of a longer input line. The j-th ce_out inside the output active window
// shows pixel j; the RAM read is registered, so the address leads by the
// enable of the current clock.

module linedoubler #(
    parameter LENGTH = 768,
    parameter DWIDTH = 23,
    localparam AWIDTH = $clog2(LENGTH)-1,
    localparam DEPTH  = 2**(AWIDTH+1)
)
(
	input             clk,

	input             ce_in,       // one per input pixel; pix_in and hb_in are valid one clock later
	input             hb_in,       // input hblank, sampled together with pix_in
	input  [DWIDTH:0] pix_in,
	input             line_start,  // first output copy of a line starts: the halves swap roles

	input             ce_out,      // one per output pixel
	input             hb_out,      // output hblank (scandoubler hb_out)
	output [DWIDTH:0] pix_out
);

(* ram_style = "distributed" *) reg [DWIDTH:0] ram0[0:DEPTH-1];
(* ram_style = "distributed" *) reg [DWIDTH:0] ram1[0:DEPTH-1];

reg  [DWIDTH:0] q0, q1;
reg             rbuf = 0;          // half that holds the previous, complete input line
reg             rbuf_d = 0;
reg  [AWIDTH:0] wa;
reg  [AWIDTH:0] ra;
reg             ce_in_d, hb_in_d;
reg             we;
reg  [AWIDTH:0] we_a;
reg             we_b;
reg  [DWIDTH:0] we_d;

wire            rd_ev = ce_out & ~hb_out;
wire [AWIDTH:0] rd_a  = ra + rd_ev;
wire            wbuf  = line_start ? rbuf : ~rbuf;

always @(posedge clk) begin
	ce_in_d <= ce_in;
	we      <= 0;

	if (line_start) rbuf <= ~rbuf;

	if (ce_in_d) begin
		hb_in_d <= hb_in;
		if (hb_in_d & ~hb_in) begin        // first active pixel of the input line
			we <= 1; we_a <= 0; we_b <= wbuf; we_d <= pix_in;
			wa <= 1'd1;
		end else if (~&wa) begin
			we <= 1; we_a <= wa; we_b <= wbuf; we_d <= pix_in;
			wa <= wa + 1'd1;
		end
	end

	if (we & ~we_b) ram0[we_a] <= we_d;
	if (we &  we_b) ram1[we_a] <= we_d;

	if (hb_out) ra <= 0;
	else if (rd_ev) ra <= ra + 1'd1;

	q0     <= ram0[rd_a];
	q1     <= ram1[rd_a];
	rbuf_d <= rbuf;
end

assign pix_out = rbuf_d ? q1 : q0;

endmodule
