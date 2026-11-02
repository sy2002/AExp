-- Behavioural models of the three Xilinx cells that
-- M2M/vhdl/controllers/HDMI/video_out_clock.vhd instantiates, for the reset
-- bench tb_video_out_clock_reset.vhd (run_voc_reset.sh). They are not the
-- declaration-only stubs of CORE/sim/stubs/unisim_stub.vhd; the runner compiles
-- this file into its own unisim library.
--
-- MMCME2_ADV: the output clocks stop at once while RST is high (asynchronous
--   reset of the output counters). After RST falls they run with a wrong period
--   until LOCK_TIME has elapsed, then LOCKED rises and CLKOUT1 is the nominal
--   74.25 MHz pixel clock, CLKOUT0 five times that (UG472: the clock outputs
--   should not be used prior to the assertion of LOCKED). DRP: DRDY three DCLK
--   cycles after DEN, DO returns the stored register, DWE writes it. All
--   generics are accepted and ignored.
-- BUFG: a wire.
-- BUFGMUX_CTRL: the glitch-free protocol of the real cell. On a change of S the
--   currently selected input is left at its next falling edge, the newly
--   selected input is enabled at its own falling edge. A stopped selected input
--   therefore stalls the switch, which is the hazard the hdmi-clock-reset change
--   avoids.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
package vcomponents is
  component mmcme2_adv generic (
    bandwidth : string := "OPTIMIZED"; clkfbout_mult_f : real := 5.0; clkfbout_phase : real := 0.0;
    clkfbout_use_fine_ps : boolean := false; clkin1_period : real := 0.0; clkin2_period : real := 0.0;
    clkout0_divide_f : real := 1.0; clkout0_duty_cycle : real := 0.5; clkout0_phase : real := 0.0;
    clkout0_use_fine_ps : boolean := false; clkout1_divide : integer := 1; clkout1_duty_cycle : real := 0.5;
    clkout1_phase : real := 0.0; clkout1_use_fine_ps : boolean := false; clkout2_divide : integer := 1;
    clkout2_duty_cycle : real := 0.5; clkout2_phase : real := 0.0; clkout2_use_fine_ps : boolean := false;
    clkout3_divide : integer := 1; clkout3_duty_cycle : real := 0.5; clkout3_phase : real := 0.0;
    clkout3_use_fine_ps : boolean := false; clkout4_cascade : boolean := false; clkout4_divide : integer := 1;
    clkout4_duty_cycle : real := 0.5; clkout4_phase : real := 0.0; clkout4_use_fine_ps : boolean := false;
    clkout5_divide : integer := 1; clkout5_duty_cycle : real := 0.5; clkout5_phase : real := 0.0;
    clkout5_use_fine_ps : boolean := false; clkout6_divide : integer := 1; clkout6_duty_cycle : real := 0.5;
    clkout6_phase : real := 0.0; clkout6_use_fine_ps : boolean := false; compensation : string := "ZHOLD";
    divclk_divide : integer := 1; is_clkinsel_inverted : bit := '0'; is_psen_inverted : bit := '0';
    is_psincdec_inverted : bit := '0'; is_pwrdwn_inverted : bit := '0'; is_rst_inverted : bit := '0';
    ref_jitter1 : real := 0.0; ref_jitter2 : real := 0.0; ss_en : string := "FALSE";
    ss_mode : string := "CENTER_HIGH"; ss_mod_period : integer := 10000; startup_wait : boolean := false);
   port (
    clkfbout, clkfboutb, clkfbstopped, clkinstopped : out std_logic;
    clkout0, clkout0b, clkout1, clkout1b, clkout2, clkout2b, clkout3, clkout3b, clkout4, clkout5, clkout6 : out std_logic;
    do : out std_logic_vector(15 downto 0); drdy, locked, psdone : out std_logic;
    clkfbin, clkin1, clkin2, clkinsel : in std_logic; daddr : in std_logic_vector(6 downto 0);
    dclk, den : in std_logic; di : in std_logic_vector(15 downto 0); dwe, psclk, psen, psincdec, pwrdwn, rst : in std_logic);
  end component;
  component bufg port (o : out std_logic; i : in std_logic); end component;
  component bufgmux_ctrl port (o : out std_logic; i0, i1, s : in std_logic); end component;
end package;

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity mmcme2_adv is generic (
    bandwidth : string := "OPTIMIZED"; clkfbout_mult_f : real := 5.0; clkfbout_phase : real := 0.0;
    clkfbout_use_fine_ps : boolean := false; clkin1_period : real := 0.0; clkin2_period : real := 0.0;
    clkout0_divide_f : real := 1.0; clkout0_duty_cycle : real := 0.5; clkout0_phase : real := 0.0;
    clkout0_use_fine_ps : boolean := false; clkout1_divide : integer := 1; clkout1_duty_cycle : real := 0.5;
    clkout1_phase : real := 0.0; clkout1_use_fine_ps : boolean := false; clkout2_divide : integer := 1;
    clkout2_duty_cycle : real := 0.5; clkout2_phase : real := 0.0; clkout2_use_fine_ps : boolean := false;
    clkout3_divide : integer := 1; clkout3_duty_cycle : real := 0.5; clkout3_phase : real := 0.0;
    clkout3_use_fine_ps : boolean := false; clkout4_cascade : boolean := false; clkout4_divide : integer := 1;
    clkout4_duty_cycle : real := 0.5; clkout4_phase : real := 0.0; clkout4_use_fine_ps : boolean := false;
    clkout5_divide : integer := 1; clkout5_duty_cycle : real := 0.5; clkout5_phase : real := 0.0;
    clkout5_use_fine_ps : boolean := false; clkout6_divide : integer := 1; clkout6_duty_cycle : real := 0.5;
    clkout6_phase : real := 0.0; clkout6_use_fine_ps : boolean := false; compensation : string := "ZHOLD";
    divclk_divide : integer := 1; is_clkinsel_inverted : bit := '0'; is_psen_inverted : bit := '0';
    is_psincdec_inverted : bit := '0'; is_pwrdwn_inverted : bit := '0'; is_rst_inverted : bit := '0';
    ref_jitter1 : real := 0.0; ref_jitter2 : real := 0.0; ss_en : string := "FALSE";
    ss_mode : string := "CENTER_HIGH"; ss_mod_period : integer := 10000; startup_wait : boolean := false);
   port (
    clkfbout, clkfboutb, clkfbstopped, clkinstopped : out std_logic;
    clkout0, clkout0b, clkout1, clkout1b, clkout2, clkout2b, clkout3, clkout3b, clkout4, clkout5, clkout6 : out std_logic;
    do : out std_logic_vector(15 downto 0); drdy, locked, psdone : out std_logic;
    clkfbin, clkin1, clkin2, clkinsel : in std_logic; daddr : in std_logic_vector(6 downto 0);
    dclk, den : in std_logic; di : in std_logic_vector(15 downto 0); dwe, psclk, psen, psincdec, pwrdwn, rst : in std_logic);
end entity;
architecture model of mmcme2_adv is
  constant T_PIX_NOM  : time := 13468 ps;   -- 74.25 MHz
  constant T_PIX_WILD : time := 9000 ps;    -- "not valid" output before LOCKED
  constant LOCK_TIME  : time := 50 us;
  signal running : boolean := false;
  signal lockedi : std_logic := '0';
  signal pix, pix5 : std_logic := '0';
  type regs_t is array (0 to 127) of std_logic_vector(15 downto 0);
  signal regs : regs_t := (others => x"0000");
begin
  clkfbout <= '0'; clkfboutb <= '0'; clkfbstopped <= '0'; clkinstopped <= '0';
  clkout0b <= '0'; clkout1b <= '0'; clkout2 <= '0'; clkout2b <= '0'; clkout3 <= '0'; clkout3b <= '0';
  clkout4 <= '0'; clkout5 <= '0'; clkout6 <= '0'; psdone <= '0';
  locked <= lockedi;
  -- lock sequencing
  process
  begin
    wait for 1 ns;
    loop
      if rst = '0' then
        running <= true;
        wait until rst /= '0' for LOCK_TIME;
        if rst = '0' then
          lockedi <= '1';
          wait until rst /= '0';
        end if;
      else
        running <= false; lockedi <= '0';
        wait until rst = '0';
      end if;
    end loop;
  end process;
  -- pixel clock: stops at once when RST asserts (asynchronous reset of the output
  -- counters), runs with a wrong period before LOCKED, nominal afterwards
  process
    variable half : time;
  begin
    if not running then
      pix <= '0';
      wait until running;
    end if;
    if lockedi = '1' then half := T_PIX_NOM / 2; else half := T_PIX_WILD / 2; end if;
    pix <= '1';
    wait until not running for half;
    if running then
      pix <= '0';
      wait until not running for half;
    end if;
  end process;
  -- 5x serialiser clock, same gating
  process
    variable half5 : time;
  begin
    if not running then
      pix5 <= '0';
      wait until running;
    end if;
    if lockedi = '1' then half5 := T_PIX_NOM / 10; else half5 := T_PIX_WILD / 10; end if;
    pix5 <= '1';
    wait until not running for half5;
    if running then
      pix5 <= '0';
      wait until not running for half5;
    end if;
  end process;
  clkout1 <= pix; clkout0 <= pix5;
  -- DRP
  process (dclk)
    variable cnt : integer := 0;
    variable pend : boolean := false;
    variable addr : integer := 0;
  begin
    if rising_edge(dclk) then
      drdy <= '0';
      if pend then
        cnt := cnt - 1;
        if cnt = 0 then
          drdy <= '1'; pend := false;
          do <= regs(addr);
        end if;
      elsif den = '1' then
        pend := true; cnt := 3; addr := to_integer(unsigned(daddr));
        if dwe = '1' then regs(addr) <= di; end if;
      end if;
    end if;
  end process;
end architecture;

library ieee; use ieee.std_logic_1164.all;
entity bufg is port (o : out std_logic; i : in std_logic); end entity;
architecture model of bufg is begin o <= i; end architecture;

library ieee; use ieee.std_logic_1164.all;
entity bufgmux_ctrl is port (o : out std_logic; i0, i1, s : in std_logic); end entity;
architecture model of bufgmux_ctrl is
  signal sel_q : std_logic := '0';   -- registered select, hardware init 0
  signal en    : std_logic := '1';   -- output enabled (low between two inputs)
begin
  process
    variable want : std_logic;
  begin
    want := s;
    if want = 'U' then want := '0'; end if;
    if want /= sel_q then
      -- the real cell: disable the current clock at its next falling edge (a stopped
      -- clock never delivers one), then enable the new clock at its falling edge
      if sel_q = '0' then wait until falling_edge(i0); else wait until falling_edge(i1); end if;
      en <= '0';
      if want = '0' then wait until falling_edge(i0); else wait until falling_edge(i1); end if;
      sel_q <= want; en <= '1';
      wait for 0 ns;                 -- then look at S again: it may have changed meanwhile
    else
      wait on s;
    end if;
  end process;
  o <= '0' when en = '0' else i0 when sel_q = '0' else i1;
end architecture;
