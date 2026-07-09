-------------------------------------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Clock Generator using the Xilinx specific MMCME2_ADV:
--
--   Single core clock domain: clk_main = 28.375000 MHz (PAL Amiga master clock)
--
-- Frequency math (PAL):
--    The original PAL Amiga master crystal runs at 28.37516 MHz, i.e.
--    6.4 x 4.43361875 MHz (PAL colorburst) = 4 x 7.09379 MHz (CCK x 4).
--    We generate from the 100 MHz board clock:
--       f_VCO  = 100 MHz x CLKFBOUT_MULT_F / DIVCLK_DIVIDE = 100 x 56.750 / 5 = 1135.000 MHz
--       f_OUT  = f_VCO / CLKOUT0_DIVIDE_F                  = 1135.000 / 40    =   28.375000 MHz
--    Error vs. ideal 28.3751600 MHz: -160 Hz = -5.6 ppm. A real Amiga crystal is
--    specified at +/-50 ppm (typ.), so we are well within the tolerance of original hardware.
--
-- MMCME2_ADV legality checks (Artix-7 XC7A200T-2, see Xilinx DS181 / UG472):
--    * VCO = 1135.000 MHz is within the -2 speed grade MMCM VCO range of 600..1440 MHz
--    * PFD = 100 MHz / DIVCLK_DIVIDE(5) = 20 MHz, within the allowed 10..500 MHz (-2)
--    * CLKFBOUT_MULT_F = 56.750 is a multiple of 0.125 within 2.000..64.000 (legal fractional);
--      fractional dividers are only permitted on CLKFBOUT and CLKOUT0 - here only CLKFBOUT
--      is fractional, CLKOUT0_DIVIDE_F = 40.000 is integer-valued (1.000..128.000, legal)
--
-- HDMI flicker-free (implemented, GitHub issue #12):
--    The native 28.375 MHz clock gives a 313-line PAL frame rate of 49.9201 Hz, which is
--    slightly *below* the hardware-nailed HDMI rate of exactly 50.000 Hz. The ascal scaler's
--    single-framebuffer read (HDMI, 50.000) and write (core, 49.92) pointers therefore drift
--    and eventually cross over, dropping/repeating one frame roughly every 12 s (a judder or
--    tear on horizontal scrollers). We add a second MMCM "i_clk_fast" that produces
--    28.437500 MHz (313-line = 50.030 Hz, slightly *above* 50) and switch between "native"
--    and "fast" glitch-free with a BUFGMUX_CTRL. The select comes from the ascal over/under
--    flow feedback (core_speed_i, driven by the FSM in mega65.vhd); the resulting bang-bang
--    dither makes the core's *time-average* frame rate exactly 50.000 Hz, so the pointers no
--    longer cross. Interlace field-pairs already average exactly 50.000 Hz (625 x 1816 core
--    clocks = 2 x 28.375 MHz for two fields), so the loop simply settles on "native" there.
--
--    Direction note vs C64MEGA65: the C64's native rate is ABOVE 50 Hz, so its flicker-free
--    twin is *slower*. The Amiga's native rate is BELOW 50 Hz, so ours (i_clk_fast) is
--    *faster*. The mechanism is identical, only the sign of the twin's offset flips.
--
-- Future extensions (documented here for later milestones, NOT implemented yet):
--    * Increment 2 (3-clock): add a third MMCM "i_clk_slow" at 28.312500 MHz (312-line =
--      49.970 Hz, below 50) plus a 3-state ladder FSM, to also pull sustained >50 Hz content
--      (parity-forced-short interlace, held short frames) down to exactly 50.000 Hz. The
--      native and fast legs stay unchanged, so this is a pure addition.
--    * NTSC: the NTSC Amiga master clock is 28.63636 MHz (= 315/11 MHz = 8 x 3.579545 MHz
--      colorburst). This is achievable EXACTLY with a second MMCM (or DRP reconfiguration):
--      DIVCLK_DIVIDE = 5, CLKFBOUT_MULT_F = 63.000 (VCO = 1260.000 MHz, in range),
--      CLKOUT0_DIVIDE_F = 44.000 -> 100 x 63 / 5 / 44 = 28.636364 MHz, 0 ppm error.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: rewrote the M2M template clock
-- (single MMCM, 54 MHz demo clock) to generate the 28.375 MHz Amiga PAL core clock.
-- Entity ports kept identical to the template. Based on the MiSTer2MEGA65 framework
-- done by sy2002 and MJoergen and licensed under GPL v3.
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      -- HDMI flicker-free core clock select (asynchronous, glitch-free absorbed by BUFGMUX_CTRL):
      --   "00" = native 28.375000 MHz (49.9201 Hz, below 50; also the flicker-free-OFF/authentic case)
      --   "01" = fast   28.437500 MHz (50.030 Hz, above 50)
      -- Bit 1 is reserved for the Increment-2 "slow" leg (3-clock design); unused here.
      core_speed_i    : in  unsigned(1 downto 0);

      main_clk_o      : out std_logic;   -- Amiga PAL core clock: 28.375000 MHz (ideal: 28.3751600 MHz, -5.6 ppm)
      main_rst_o      : out std_logic    -- main's reset, synchronized
   );
end entity clk;

architecture rtl of clk is

-- native leg (28.375000 MHz)
signal main_fb            : std_logic;
signal main_fb_mmcm       : std_logic;
signal native_clk_mmcm    : std_logic;
signal main_locked        : std_logic;

-- fast leg (28.437500 MHz), HDMI flicker-free twin
signal fast_fb            : std_logic;
signal fast_fb_mmcm       : std_logic;
signal fast_clk_mmcm      : std_logic;
signal fast_locked        : std_logic;

-- glitch-free mux output feeding the shared output BUFG
signal main_clk_mmcm      : std_logic;

begin

   -------------------------------------------------------------------------------------
   -- Generate the Amiga core clock: 28.375000 MHz
   -- 100 MHz x 56.750 / 5 = 1135.000 MHz VCO; 1135.000 MHz / 40 = 28.375000 MHz
   -------------------------------------------------------------------------------------

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         -- MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: template made 54 MHz
         -- (DIVCLK_DIVIDE=1, CLKFBOUT_MULT_F=6.750, CLKOUT0_DIVIDE_F=12.500);
         -- changed to 28.375 MHz Amiga PAL master clock, see header for the math.
         DIVCLK_DIVIDE        => 5,
         CLKFBOUT_MULT_F      => 56.750,     -- VCO = 1135.000 MHz (legal: 600..1440 MHz @ -2)
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 40.000,     -- 28.375000 MHz (ideal 28.3751600 MHz, -5.6 ppm)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE
      )
      port map (
         -- Output clocks
         CLKFBOUT            => main_fb_mmcm,
         CLKOUT0             => native_clk_mmcm,
         -- Input clock control
         CLKFBIN             => main_fb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         -- Tied to always select the primary input clock
         CLKINSEL            => '1',
         -- Ports for dynamic reconfiguration
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         -- Ports for dynamic phase shift
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         -- Other control and status signals
         LOCKED              => main_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_main

   -------------------------------------------------------------------------------------
   -- HDMI flicker-free "fast" twin: 28.437500 MHz
   -- 100 MHz x 56.875 / 5 = 1137.500 MHz VCO; 1137.500 MHz / 40 = 28.437500 MHz
   -- Shares the native leg's DIVCLK_DIVIDE (5) and CLKOUT0_DIVIDE_F (40); only
   -- CLKFBOUT_MULT_F differs by +0.125, for the tightest possible jitter/clock-tree
   -- match to native and minimal placement perturbation near the HyperRAM PHY.
   -- Legality (Artix-7 -2): VCO 1137.5 MHz in 600..1440; PFD 20 MHz in 10..500;
   -- MULT_F 56.875 = 455/8 is a legal multiple of 0.125 within 2.000..64.000.
   -------------------------------------------------------------------------------------

   i_clk_fast : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,
         CLKFBOUT_MULT_F      => 56.875,     -- VCO = 1137.500 MHz (legal: 600..1440 MHz @ -2)
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 40.000,     -- 28.437500 MHz (313-line PAL = 50.030 Hz, above 50)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE
      )
      port map (
         -- Output clocks
         CLKFBOUT            => fast_fb_mmcm,
         CLKOUT0             => fast_clk_mmcm,
         -- Input clock control
         CLKFBIN             => fast_fb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         -- Tied to always select the primary input clock
         CLKINSEL            => '1',
         -- Ports for dynamic reconfiguration
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         -- Ports for dynamic phase shift
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         -- Other control and status signals
         LOCKED              => fast_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_fast

   -------------------------------------------------------------------------------------
   -- Output buffering
   -------------------------------------------------------------------------------------

   -- native leg feedback (ZHOLD compensates one BUFG delay)
   main_fb_bufg : BUFG
      port map (
         I => main_fb_mmcm,
         O => main_fb
      );

   -- fast leg feedback (its own BUFG, symmetric with native)
   fast_fb_bufg : BUFG
      port map (
         I => fast_fb_mmcm,
         O => fast_fb
      );

   -- Glitch-free switch between native ("00") and fast ("01"); the select is treated
   -- asynchronously to both clock inputs and absorbed cleanly by the BUFGMUX_CTRL.
   i_bufgmux : BUFGMUX_CTRL
      port map (
         I0 => native_clk_mmcm,     -- s = 0 -> native (28.375000 MHz)
         I1 => fast_clk_mmcm,       -- s = 1 -> fast   (28.437500 MHz)
         S  => core_speed_i(0),
         O  => main_clk_mmcm
      );

   main_clk_bufg : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk_o
      );

   -------------------------------------
   -- Reset generation
   -------------------------------------

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         -- Hold the core in reset until BOTH legs are locked, so the "fast" MMCM is already
         -- toggling before the select can ever choose it (load-bearing: BUFGMUX_CTRL would
         -- otherwise forward a dead clock on the first native->fast switch).
         src_arst  => not (main_locked and fast_locked),   -- 1-bit input: Source reset signal.
         dest_clk  => main_clk_o,        -- 1-bit input: Destination clock.
         dest_arst => main_rst_o         -- 1-bit output: src_rst synchronized to the destination clock domain.
                                         -- This output is registered.
      );

end architecture rtl;
