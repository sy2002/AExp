-- Simulation stub of the Xilinx xpm.vcomponents package.
--
-- Declares only the XPM macros used in the tree (xpm_cdc_async_rst,
-- xpm_cdc_single, xpm_fifo_axis). Without xpm_fifo_axis, M2M's axi_fifo.vhd
-- does not analyse, then avm_fifo, adf_mount_wrapper and mega65.vhd all fail
-- with "design unit not found", which looks like a much bigger problem than it
-- is. There are no entity bodies: analysis only, no elaboration.
-- Compile it into a library named xpm, e.g.
--   nvc --std=2008 --work=xpm:<dir>/xpm -a xpm_stub.vhd
-- CORE/sim/run_nvc_chain.sh does this.

library ieee; use ieee.std_logic_1164.all;
package vcomponents is
   component xpm_cdc_async_rst generic (
      DEST_SYNC_FF : integer := 4; INIT_SYNC_FF : integer := 0;
      RST_ACTIVE_HIGH : integer := 0; SIM_ASSERT_CHK : integer := 0);
   port (src_arst : in std_logic; dest_clk : in std_logic; dest_arst : out std_logic);
   end component;
   component xpm_cdc_single generic (
      DEST_SYNC_FF : integer := 4; INIT_SYNC_FF : integer := 0;
      SIM_ASSERT_CHK : integer := 0; SRC_INPUT_REG : integer := 1);
   port (src_clk : in std_logic; src_in : in std_logic; dest_clk : in std_logic; dest_out : out std_logic);
   end component;
   component xpm_fifo_axis generic (
      CDC_SYNC_STAGES : integer := 2; CLOCKING_MODE : string := "common_clock";
      ECC_MODE : string := "no_ecc"; FIFO_DEPTH : integer := 2048;
      FIFO_MEMORY_TYPE : string := "auto"; PACKET_FIFO : string := "false";
      PROG_EMPTY_THRESH : integer := 10; PROG_FULL_THRESH : integer := 10;
      RD_DATA_COUNT_WIDTH : integer := 11; RELATED_CLOCKS : integer := 0;
      SIM_ASSERT_CHK : integer := 0; TDATA_WIDTH : integer := 32;
      TDEST_WIDTH : integer := 1; TID_WIDTH : integer := 1;
      TUSER_WIDTH : integer := 1; USE_ADV_FEATURES : string := "1000";
      WR_DATA_COUNT_WIDTH : integer := 11);
   port (
      almost_empty_axis : out std_logic; almost_full_axis : out std_logic;
      dbiterr_axis : out std_logic; injectdbiterr_axis : in std_logic;
      injectsbiterr_axis : in std_logic; m_aclk : in std_logic;
      m_axis_tdata : out std_logic_vector(TDATA_WIDTH-1 downto 0);
      m_axis_tdest : out std_logic_vector(TDEST_WIDTH-1 downto 0);
      m_axis_tid : out std_logic_vector(TID_WIDTH-1 downto 0);
      m_axis_tkeep : out std_logic_vector(TDATA_WIDTH/8-1 downto 0);
      m_axis_tlast : out std_logic; m_axis_tready : in std_logic;
      m_axis_tstrb : out std_logic_vector(TDATA_WIDTH/8-1 downto 0);
      m_axis_tuser : out std_logic_vector(TUSER_WIDTH-1 downto 0);
      m_axis_tvalid : out std_logic; prog_empty_axis : out std_logic;
      prog_full_axis : out std_logic;
      rd_data_count_axis : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
      s_aclk : in std_logic; s_aresetn : in std_logic;
      s_axis_tdata : in std_logic_vector(TDATA_WIDTH-1 downto 0);
      s_axis_tdest : in std_logic_vector(TDEST_WIDTH-1 downto 0);
      s_axis_tid : in std_logic_vector(TID_WIDTH-1 downto 0);
      s_axis_tkeep : in std_logic_vector(TDATA_WIDTH/8-1 downto 0);
      s_axis_tlast : in std_logic; s_axis_tready : out std_logic;
      s_axis_tstrb : in std_logic_vector(TDATA_WIDTH/8-1 downto 0);
      s_axis_tuser : in std_logic_vector(TUSER_WIDTH-1 downto 0);
      s_axis_tvalid : in std_logic; sbiterr_axis : out std_logic;
      wr_data_count_axis : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0));
   end component;
end package vcomponents;
