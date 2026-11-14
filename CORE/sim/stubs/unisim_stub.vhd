-- Simulation stub of the Xilinx unisim.vcomponents package.
--
-- Declares only the primitives that AExp's VHDL instantiates (MMCME2_ADV,
-- BUFG, BUFGCE, BUFGMUX_CTRL in clk.vhd) so that nvc can analyse clk.vhd and
-- mega65.vhd outside Vivado. There are no entity bodies: designs that use these
-- components analyse, but they cannot be elaborated or simulated with this stub.
-- Compile it into a library named unisim, e.g.
--   nvc --std=2008 --work=unisim:<dir>/unisim -a unisim_stub.vhd
-- CORE/sim/run_nvc_chain.sh does this.

library ieee; use ieee.std_logic_1164.all;
package vcomponents is
   component MMCME2_ADV generic (
      BANDWIDTH : string := "OPTIMIZED"; CLKFBOUT_MULT_F : real := 5.0;
      CLKFBOUT_PHASE : real := 0.0; CLKIN1_PERIOD : real := 0.0;
      CLKIN2_PERIOD : real := 0.0; CLKOUT0_DIVIDE_F : real := 1.0;
      CLKOUT0_DUTY_CYCLE : real := 0.5; CLKOUT0_PHASE : real := 0.0;
      CLKOUT1_DIVIDE : integer := 1; CLKOUT1_DUTY_CYCLE : real := 0.5;
      CLKOUT1_PHASE : real := 0.0; CLKOUT2_DIVIDE : integer := 1;
      CLKOUT2_DUTY_CYCLE : real := 0.5; CLKOUT2_PHASE : real := 0.0;
      CLKOUT3_DIVIDE : integer := 1; CLKOUT3_DUTY_CYCLE : real := 0.5;
      CLKOUT3_PHASE : real := 0.0; CLKOUT4_CASCADE : boolean := false;
      CLKOUT4_DIVIDE : integer := 1; CLKOUT4_DUTY_CYCLE : real := 0.5;
      CLKOUT4_PHASE : real := 0.0; CLKOUT5_DIVIDE : integer := 1;
      CLKOUT5_DUTY_CYCLE : real := 0.5; CLKOUT5_PHASE : real := 0.0;
      CLKOUT6_DIVIDE : integer := 1; CLKOUT6_DUTY_CYCLE : real := 0.5;
      CLKOUT6_PHASE : real := 0.0; COMPENSATION : string := "ZHOLD";
      DIVCLK_DIVIDE : integer := 1; REF_JITTER1 : real := 0.0;
      REF_JITTER2 : real := 0.0; STARTUP_WAIT : boolean := false;
      SS_EN : string := "FALSE"; SS_MODE : string := "CENTER_HIGH";
      SS_MOD_PERIOD : integer := 10000; CLKFBOUT_USE_FINE_PS : boolean := false;
      CLKOUT0_USE_FINE_PS : boolean := false; CLKOUT1_USE_FINE_PS : boolean := false;
      CLKOUT2_USE_FINE_PS : boolean := false; CLKOUT3_USE_FINE_PS : boolean := false;
      CLKOUT4_USE_FINE_PS : boolean := false; CLKOUT5_USE_FINE_PS : boolean := false;
      CLKOUT6_USE_FINE_PS : boolean := false);
   port (
      CLKFBOUT : out std_logic; CLKFBOUTB : out std_logic; CLKFBSTOPPED : out std_logic;
      CLKINSTOPPED : out std_logic; CLKOUT0 : out std_logic; CLKOUT0B : out std_logic;
      CLKOUT1 : out std_logic; CLKOUT1B : out std_logic; CLKOUT2 : out std_logic;
      CLKOUT2B : out std_logic; CLKOUT3 : out std_logic; CLKOUT3B : out std_logic;
      CLKOUT4 : out std_logic; CLKOUT5 : out std_logic; CLKOUT6 : out std_logic;
      DO : out std_logic_vector(15 downto 0); DRDY : out std_logic; LOCKED : out std_logic;
      PSDONE : out std_logic; CLKFBIN : in std_logic; CLKIN1 : in std_logic;
      CLKIN2 : in std_logic; CLKINSEL : in std_logic;
      DADDR : in std_logic_vector(6 downto 0); DCLK : in std_logic; DEN : in std_logic;
      DI : in std_logic_vector(15 downto 0); DWE : in std_logic; PSCLK : in std_logic;
      PSEN : in std_logic; PSINCDEC : in std_logic; PWRDWN : in std_logic; RST : in std_logic);
   end component;
   component BUFG port (O : out std_logic; I : in std_logic); end component;
   component BUFGCE port (O : out std_logic; CE : in std_logic; I : in std_logic); end component;
   component BUFGMUX_CTRL port (O : out std_logic; I0 : in std_logic; I1 : in std_logic; S : in std_logic); end component;
end package vcomponents;
