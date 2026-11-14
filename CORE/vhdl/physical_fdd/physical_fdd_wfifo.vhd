-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_wfifo: dual-clock asynchronous word FIFO between the 50 MHz
-- front end and the 28.375 MHz core clock. physical_fdd_top uses it in both
-- directions:
--   * read path, G_AW = 5 (32 words), 50 MHz -> core clock, drained by
--     adf_track_engine into Paula's host channel. It is the elastic queue
--     for the clock crossing, never a pacing element: words arrive at disk
--     speed, about one per 32 us, and the engine drains far faster.
--   * write path, G_AW = 2 (4 words), core clock -> physical_fdd_writer at
--     50 MHz. Its shallowness bounds the flux still owed when Paula signals
--     DSKBLK; see doc/developers/hardware-floppy.md, section 6.1 (The
--     structure, and the elastic-buffer argument).
--
-- Textbook Gray-code async FIFO (Cummings, SNUG 2002):
--   * Binary and Gray write/read pointers, each G_AW+1 bits wide (the extra
--     MSB distinguishes full from empty).
--   * The Gray pointer of each domain is 2-FF synchronized into the opposite
--     domain (the first flop carries the Xilinx `async_reg` attribute).
--   * FULL  when the next write-Gray equals the synced read-Gray with the top
--     two bits inverted.
--   * EMPTY when the next read-Gray equals the synced write-Gray.
--   * Storage is a shared dual-port array: clocked write port, asynchronous
--     read of the current head (first-word-fall-through: rd_data_o always
--     shows the head; rd_en_i pops it).
--
-- Reset discipline: both sides must reset from the same event, each
-- synchronized into its own domain. A one-sided reset permanently
-- desynchronizes the Gray pointers and corrupts data silently (seen in the
-- C64MEGA65 physical-1581 bring-up). Both instances take their resets from
-- the QNICE reset; mega65.vhd provides the copy synchronized into the core
-- clock domain.
--
-- Depth = 2**G_AW (default 32). G_AW must be >= 2. Storage is distributed
-- LUTRAM by construction, because the block RAM of the device is fully used.
--
-- Adapted from C64MEGA65 CORE/vhdl/physical_1581/physical_1581_rdfifo.vhd
-- (sy2002 2026, GPLv3); changes: 16-bit words instead of bytes, level tap
-- width for the shallow default depth, and the read-side level rd_level_o.
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity physical_fdd_wfifo is
  generic (
    G_AW : natural := 5   -- depth = 2**G_AW = 32 words
  );
  port (
    wr_clk_i   : in  std_logic;
    wr_rst_i   : in  std_logic;
    wr_en_i    : in  std_logic;
    wr_data_i  : in  std_logic_vector(15 downto 0);
    wr_full_o  : out std_logic;
    -- Write-side occupancy: binary write pointer minus the Gray-synced
    -- (decoded) read pointer, in the wr_clk_i domain. Conservative-high:
    -- reads show up only after their Gray pointer crosses the 2-FF sync.
    -- The read-path instance feeds it to the diagnostics; on the write path
    -- adf_track_engine admits a pop only while it reads at most 1.
    wr_level_o : out unsigned(G_AW downto 0);
    rd_clk_i   : in  std_logic;
    rd_rst_i   : in  std_logic;
    rd_en_i    : in  std_logic;
    rd_data_o  : out std_logic_vector(15 downto 0);
    rd_empty_o : out std_logic;
    -- Read-side occupancy, the mirror of wr_level_o: the Gray-synced
    -- (decoded) write pointer minus the binary read pointer, in the
    -- rd_clk_i domain. Conservative-low: writes show up only after their
    -- Gray pointer has crossed the 2-FF sync, so a consumer that waits for
    -- a threshold is never told there is more than there really is. The
    -- read-path instance leaves it open; the write-path instance feeds it to
    -- the writer, which starts streaming only once two words are buffered.
    rd_level_o : out unsigned(G_AW downto 0)
  );
end entity physical_fdd_wfifo;

architecture rtl of physical_fdd_wfifo is

  -- Binary -> Gray (g = (b srl 1) xor b).
  function bin2gray(b : unsigned) return unsigned is
  begin
    return shift_right(b, 1) xor b;
  end function;

  -- Gray -> binary (b(i) = xor of g(high downto i)).
  function gray2bin(g : unsigned) return unsigned is
    variable b : unsigned(g'range);
  begin
    b(g'high) := g(g'high);
    for i in g'high - 1 downto g'low loop
      b(i) := b(i + 1) xor g(i);
    end loop;
    return b;
  end function;

  type mem_t is array (0 to 2**G_AW - 1) of std_logic_vector(15 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of mem : signal is "distributed";

  -- Write domain.
  signal wbin       : unsigned(G_AW downto 0) := (others => '0');
  signal wgray      : unsigned(G_AW downto 0) := (others => '0');
  signal wbin_next  : unsigned(G_AW downto 0);
  signal wgray_next : unsigned(G_AW downto 0);
  signal w_do_write : std_logic;
  signal full_q     : std_logic := '0';

  -- Read domain.
  signal rbin       : unsigned(G_AW downto 0) := (others => '0');
  signal rgray      : unsigned(G_AW downto 0) := (others => '0');
  signal rbin_next  : unsigned(G_AW downto 0);
  signal rgray_next : unsigned(G_AW downto 0);
  signal r_do_read  : std_logic;
  signal empty_q    : std_logic := '1';

  -- Cross-domain 2-FF synchronizers.
  signal rq1_wgray  : unsigned(G_AW downto 0) := (others => '0');  -- write-Gray into read domain
  signal rq2_wgray  : unsigned(G_AW downto 0) := (others => '0');
  signal wq1_rgray  : unsigned(G_AW downto 0) := (others => '0');  -- read-Gray into write domain
  signal wq2_rgray  : unsigned(G_AW downto 0) := (others => '0');

  attribute async_reg              : string;
  attribute async_reg of rq1_wgray : signal is "true";
  attribute async_reg of wq1_rgray : signal is "true";

begin

  -----------------------------------------------------------------------------
  -- Write domain (wr_clk_i)
  -----------------------------------------------------------------------------
  w_do_write <= wr_en_i and not full_q;
  wbin_next  <= wbin + 1 when w_do_write = '1' else wbin;
  wgray_next <= bin2gray(wbin_next);

  wr_full_o <= full_q;

  -- Write-side occupancy tap (see the port comment). The pointer difference is
  -- taken modulo 2**(G_AW+1), which is exact for any fill level 0..2**G_AW.
  wr_level_o <= wbin - gray2bin(wq2_rgray);

  -- Read-side occupancy tap (the mirror; see the port comment).
  rd_level_o <= gray2bin(rq2_wgray) - rbin;

  wr_domain : process (wr_clk_i)
  begin
    if rising_edge(wr_clk_i) then
      -- Synchronize the read Gray pointer into the write domain.
      wq1_rgray <= rgray;
      wq2_rgray <= wq1_rgray;

      if wr_rst_i = '1' then
        wbin   <= (others => '0');
        wgray  <= (others => '0');
        full_q <= '0';
      else
        if w_do_write = '1' then
          mem(to_integer(wbin(G_AW - 1 downto 0))) <= wr_data_i;
        end if;
        wbin  <= wbin_next;
        wgray <= wgray_next;
        -- FULL: next write-Gray equals synced read-Gray with top two bits flipped.
        if wgray_next =
             ((not wq2_rgray(G_AW)) & (not wq2_rgray(G_AW - 1)) &
              wq2_rgray(G_AW - 2 downto 0)) then
          full_q <= '1';
        else
          full_q <= '0';
        end if;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Read domain (rd_clk_i)
  -----------------------------------------------------------------------------
  r_do_read  <= rd_en_i and not empty_q;
  rbin_next  <= rbin + 1 when r_do_read = '1' else rbin;
  rgray_next <= bin2gray(rbin_next);

  rd_empty_o <= empty_q;
  -- Asynchronous head read (first-word-fall-through).
  rd_data_o  <= mem(to_integer(rbin(G_AW - 1 downto 0)));

  rd_domain : process (rd_clk_i)
  begin
    if rising_edge(rd_clk_i) then
      -- Synchronize the write Gray pointer into the read domain.
      rq1_wgray <= wgray;
      rq2_wgray <= rq1_wgray;

      if rd_rst_i = '1' then
        rbin    <= (others => '0');
        rgray   <= (others => '0');
        empty_q <= '1';
      else
        rbin  <= rbin_next;
        rgray <= rgray_next;
        -- EMPTY: next read-Gray equals synced write-Gray.
        if rgray_next = rq2_wgray then
          empty_q <= '1';
        else
          empty_q <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
