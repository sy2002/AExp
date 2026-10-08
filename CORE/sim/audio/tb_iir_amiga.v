// Testbench: the two Amiga audio IIR filters as instantiated by
// CORE/vhdl/audio_filters.vhd (coefficients verbatim from MiSTer Minimig.sv,
// unused coefficient ports tied to zero).
//
// Verifies against the analytic RC prototypes:
//   lpf4400: 1st order low-pass, fc = 4400 Hz            (A500 fixed filter)
//   lpf3275: 1st order 3000 Hz cascaded with 3400 Hz     (LED filter)
// plus DC transparency and channel separation of the time-multiplexed core.
//
// See doc/developers/audio.md, section "Verification".
//
// Run: CORE/sim/audio/run.sh (a few seconds, together with tb_audio_filters.vhd).

`timescale 1ns/1ps

module tb_iir_amiga;

   reg clk = 0;
   always #17.62 clk = ~clk;          // ~28.375 MHz

   reg ce = 0;                        // every 2nd clk = 14.19 MHz (clk7_en|clk7n_en)
   always @(posedge clk) ce <= ~ce;

   reg reset = 1;

   reg signed [15:0] in_l = 0, in_r = 0;
   wire signed [15:0] f44_l, f44_r, f32_l, f32_r;

   IIR_filter #(0) lpf4400
   (
      .clk(clk), .reset(reset), .ce(ce), .sample_ce(1'b1),
      .cx(40'd4304835800), .cx0(8'd1), .cx1(8'd0), .cx2(8'd0),
      .cy0(-24'sd2088941), .cy1(24'sd0), .cy2(24'sd0),
      .input_l(in_l), .input_r(in_r), .output_l(f44_l), .output_r(f44_r)
   );

   IIR_filter #(0) lpf3275
   (
      .clk(clk), .reset(reset), .ce(ce), .sample_ce(1'b1),
      .cx(40'd8536629), .cx0(8'd2), .cx1(8'd1), .cx2(8'd0),
      .cy0(-24'sd4182432), .cy1(24'sd2085297), .cy2(24'sd0),
      .input_l(in_l), .input_r(in_r), .output_l(f32_l), .output_r(f32_r)
   );

   real freq = 0.0;
   localparam real AMPL = 20000.0;
   localparam real G44  = 1.0625;     // lpf4400 DC gain (17/16)
   localparam real G32  = 1.1369;     // lpf3275 DC gain
   localparam real PI2  = 6.28318530717958647;

   // sine generator on the left channel; right channel stays silent so the
   // stereo time-multiplexing is proven leak-free at the same time
   always @(posedge clk) begin
      if (freq > 0.0)
         in_l <= $rtoi(AMPL * $sin(PI2 * freq * ($time * 1.0e-9)));
      else
         in_l <= in_l;   // DC test drives in_l directly
      in_r <= 0;
   end

   integer errors = 0;

   task automatic check(input [8*24:1] name, input real measured, input real expected, input real tol_rel);
      begin
         if (expected == 0.0) begin
            if (measured > 60.0) begin
               $display("FAIL %0s: measured %f, expected silence", name, measured);
               errors = errors + 1;
            end else
               $display("pass %0s: %f (silence)", name, measured);
         end else if ((measured < expected * (1.0 - tol_rel)) || (measured > expected * (1.0 + tol_rel))) begin
            $display("FAIL %0s: measured %f, expected %f (+/-%0.1f%%)", name, measured, expected, tol_rel*100.0);
            errors = errors + 1;
         end else
            $display("pass %0s: measured %f, expected %f", name, measured, expected);
      end
   endtask

   real h44, h32;
   real min44, max44, min32, max32, maxr44, maxr32;

   task automatic run_tone(input real f);
      real t_meas;
      integer cycles;
      begin
         freq = f;
         #300_000;                                     // 300 us settling (>5 tau)
         min44 = 1.0e9; max44 = -1.0e9;
         min32 = 1.0e9; max32 = -1.0e9;
         maxr44 = 0.0;  maxr32 = 0.0;
         t_meas = 3.0e9 / f;                           // 3 periods in ns
         if (t_meas < 1.0e6) t_meas = 1.0e6;
         cycles = $rtoi(t_meas / 35.24);
         repeat (cycles) begin
            @(posedge clk);
            if (f44_l > max44) max44 = f44_l;
            if (f44_l < min44) min44 = f44_l;
            if (f32_l > max32) max32 = f32_l;
            if (f32_l < min32) min32 = f32_l;
            if (f44_r > maxr44) maxr44 = f44_r;  if (-f44_r > maxr44) maxr44 = -f44_r;
            if (f32_r > maxr32) maxr32 = f32_r;  if (-f32_r > maxr32) maxr32 = -f32_r;
         end
         // analytic prototypes, scaled by the filters' intrinsic DC gains
         // (lpf4400: exactly 17/16 = +0.53 dB; lpf3275: +1.11 dB - properties
         // of the MiSTer coefficient sets, verified at DC below)
         h44 = G44 / $sqrt(1.0 + (f/4400.0)*(f/4400.0));
         h32 = G32 * (1.0 / $sqrt(1.0 + (f/3000.0)*(f/3000.0))) * (1.0 / $sqrt(1.0 + (f/3400.0)*(f/3400.0)));
         check("lpf4400 gain", (max44 - min44) / 2.0, AMPL * h44, 0.08);
         check("lpf3275 gain", (max32 - min32) / 2.0, AMPL * h32, 0.08);
         check("lpf4400 R silent", maxr44, 0.0, 0.0);
         check("lpf3275 R silent", maxr32, 0.0, 0.0);
      end
   endtask

   initial begin
      #1000 reset = 0;

      // DC behavior: constant input passes at each filter's intrinsic DC gain
      freq = 0.0;
      in_l = 10000;
      #500_000;
      check("lpf4400 DC", f44_l, 10000.0 * G44, 0.005);
      check("lpf3275 DC", f32_l, 10000.0 * G32, 0.005);

      $display("--- 1 kHz ---");   run_tone(1000.0);
      $display("--- 3.2 kHz ---"); run_tone(3200.0);
      $display("--- 4.4 kHz ---"); run_tone(4400.0);
      $display("--- 10 kHz ---");  run_tone(10000.0);

      if (errors == 0)
         $display("ALL PASS");
      else
         $display("%0d FAILURES", errors);
      $finish;
   end

endmodule
