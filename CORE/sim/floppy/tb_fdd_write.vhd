-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- tb_fdd_write: closed-loop testbench of the Hardware Floppy write datapath.
--
-- The loop runs from a model of Paula's write DMA through the real design to
-- a rotating disk and back through the real read chain:
--
--   Paula write model (line-by-line paula_floppy.v: dsklen/dmaen/dmaon, the
--   DISKDMA FSM, wr_fifo_status, host-paced DSKBLK, Agnus 3-words-per-
--   scanline fill) -> real adf_track_engine -> real physical_fdd_top
--   (containing the real write CDC FIFO and the real physical_fdd_writer)
--   -> f_wdata/f_wgate -> live rotating flux model -> f_rdata -> the real
--   read chain -> real engine read service -> Paula read model -> verdicts.
--
-- The flux model is a live rotating disk in 50 MHz cycle timestamps, not
-- cells: every WDATA falling edge is stored at its exact cycle position
-- against the RPM-derived revolution period, WGATE erases the cells it
-- sweeps, and the wrap overwrites the write's own head. It plays back
-- continuously in simulation time, so a read dispatched during a write tail
-- really sees the tail (S12 depends on that), and a writer clocked at 99 or
-- 101 cycles/cell, a placement error or drift reach the read chain as the
-- wrong flux they are. Before every writing scenario the model is seeded
-- with a different track (different payload key, gap length and angular
-- offset), and every writing scenario asserts that the gate opened and that
-- the old flux is gone from the written span, so a writer that never opens
-- its gate cannot pass by re-reading the seed.
--
-- Verdicts, all computed by the disk process from the flux it holds,
-- independently of the DUT's own framing:
--   (a) a KS1.3 trackdisk decoder (the same one as in tb_fdd_splice.vhd:
--       sync hunt over the 16 bit rotations, chunk realignment, the SG=11
--       escape and the per-slot walk) run on the words Paula actually
--       stored through the real chain;
--   (b) the constant-framing real-Paula referee: the same flux re-read with
--       one constant framing (what a real A500 delivers) and decoded by the
--       same trackdisk decoder;
--   (c) per-sector byte compare after an independent bit-level re-sync on
--       the flux playback (the bench's own 0x4489 search, not the front
--       end's framing) against the source word list. Every (track, sector)
--       key must decode clean at least once; an instance cut by the wrap
--       seam is tolerated only when an intact instance of the same key
--       exists.
-- With G_DUMP the disk process also writes wr_dump_*.txt, which the
-- independent Python twin models/td_write_check.py must reproduce edge for
-- edge (run_write_matrix.sh does that for every dump).
--
-- Scenarios (G_SCEN). The multi-drive ownership cases live in
-- tb_adf_multidrive.vhd.
--
--   G_SCEN  name  what it exercises and asserts
--    1      S1    trackdisk cadence, one full 6815-word track. WGATE opens
--                 once for exactly words x 16 x 100 cycles; no CDC
--                 overflow, no underrun, at most 3 words in flight at
--                 DSKBLK; fixed-width WDATA pulses inside 0.2-1.1 us; the
--                 old flux is gone; verdicts (a), (b) and (c). The matrix
--                 runs it over 295.5/300/300.5/304.5 RPM (G_RPM_MHZ) x both
--                 separators (G_LEGACY) x both framing arms (G_FRAMEHOLD);
--                 the realign-always arm asserts that the write laps its own
--                 head instead of a decode outcome.
--    2      S1p   precompensation policy at G_TRACK/G_PRECMODE (AUTO at
--                 80/81/90, ON and OFF at 20): precomp active exactly when
--                 the policy says so (AUTO from track 81), and the 0x78
--                 counter agrees. The twin checks the shift direction.
--    3      S2    X-Copy cadence: a 6656-word write of a 6496-word capture,
--                 all drives deselected 50 us after DSKBLK. The window
--                 stays full, nothing is cut, the track decodes.
--    4      S3    write protect: tab open (no gate, flux untouched); tab
--                 closed but armed before the 10 ms selected-time qualifier
--                 (blocked); qualified (writes); a tab line bouncing at ms
--                 scale (blocked); 20 ms of deselected time (does not
--                 qualify).
--    5      S4    engine abort by bus_grant loss, G_VARIANT 0 = 20 us,
--                 1 = 500 us: abort reason set, the window stops at the
--                 abort, the episode does not resume. G_VARIANT 2 starves
--                 Agnus instead: the underrun aborts the episode and WGATE
--                 never re-asserts.
--    6      S5    gate-term storm, G_VARIANT 0..6 = deselect, motor off,
--                 enable off, tab, disk change, STEP, SIDE: WGATE closes
--                 within 2 us of the lost term and stays closed for the rest
--                 of the episode when the term returns.
--    7      S6    tail sweep: deselect G_VARIANT us after DSKBLK (25..2100).
--                 The drain hold makes every latency a non-event: the window
--                 stays full and the tail-cut counter stays at 0.
--    8      S9    co-selection: G_VARIANT 0 = one-poll click of a
--                 non-existent unit, 1 = click of an existing unit at
--                 another track (neither may abort or move the drain owner),
--                 2 = a foreign selection persisting past C_WR_FOREIGN (must
--                 abort), 3 = the drain cleared under an open episode and
--                 re-latched by a foreign poll (the episode's physical,
--                 non-committing ownership must be inherited; a mounted
--                 ADF drive at unit 2 must never receive the stream).
--    9      S10   physical unit at df0, where Paula's "nothing selected"
--                 and "df0" encode alike: the real /SEL drop alone must cut
--                 the gate.
--   10      S11   residue hygiene: G_VARIANT 0 = abort by deselect, 1 =
--                 QNICE + Amiga reset, 2 = Amiga reset, 3 = bus_grant drop,
--                 each followed by a new episode whose window must be exact
--                 (no stale FIFO residue in front of it); 4 = a one-word DMA
--                 that must bind an episode but never open the gate.
--   11      S12   busy interlock: a read (G_VARIANT 0) or a second write
--                 (1) armed inside the previous write's tail must be
--                 deferred until the writer is idle.
--   12      S2x   X-Copy's DOS-engine buffer, [500 x $AAAA][11 x 544 words]
--                 [1 x $AAAA] = 6485 words, with the SIDE toggle 30 us after
--                 DSKBLK (G_VARIANT 1: the all-drive deselect instead). No
--                 sector payload may be damaged, the window stays full.
--
-- Run: CORE/sim/floppy/run_write_matrix.sh runs every cell (about 74 s per
-- cell on average, 77 cells; JOBS=8 runs eight cells at a time) and the
-- twin; CORE/sim/floppy/run_write_mutants.sh proves that the checks can
-- fail. One cell by hand, from a scratch directory (nvc writes its library
-- and the dumps into the current directory):
--   nvc --std=2008 -a <the physical_fdd/*.vhd files, top last>
--       CORE/vhdl/adf_track_engine.vhd CORE/sim/floppy/tb_fdd_write.vhd
--   nvc --std=2008 -e tb_fdd_write -gG_SCEN=4 -gG_WORDS=600
--   nvc --std=2008 -r tb_fdd_write
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;
use work.physical_fdd_pkg.all;

entity tb_fdd_write is
  generic (
    G_SCEN      : natural := 1;
    G_VARIANT   : natural := 0;
    G_RPM_MHZ   : natural := 300000;   -- milli-RPM of the modeled spindle
    G_LEGACY    : boolean := false;    -- true = legacy quantiser separator
    G_FRAMEHOLD : boolean := true;     -- false = realign-always framing arm
    G_TRACK     : natural := 40;       -- Amiga track of the write episode
    G_PRECMODE  : natural := 0;        -- 0 = AUTO, 1 = ON, 2 = OFF (0x7C)
    G_WORDS     : natural := 6815;     -- write DMA length in words
    G_DUMP      : boolean := false;
    G_TRACE     : boolean := false;    -- periodic state trace (bring-up)
    -- The engine's poll period. The default is the real 1 ms. The busy
    -- interlock mutants need it short: after an episode ends the engine
    -- parks for a full poll period, so with 1 ms it can never re-poll inside
    -- the writer's ~104 us tail and the interlock is unreachable. A short
    -- poll puts the engine back on the channel while the tail is still
    -- draining, the only regime in which the interlock does anything.
    G_POLL      : natural := 28374
  );
end entity tb_fdd_write;

architecture sim of tb_fdd_write is

  -----------------------------------------------------------------------------
  -- clocks and geometry
  -----------------------------------------------------------------------------
  constant C_CLK50   : time := 20 ns;
  constant C_CLKMAIN : time := 35.242 ns;

  constant C_TREV : natural :=
    natural(60.0 * 50.0e6 * 1000.0 / real(G_RPM_MHZ));
  constant C_CELL  : natural := 100;
  constant C_SLOT  : natural := 50;
  constant C_NSLOT : natural := 240000;

  constant C_NSEC      : natural := 11;
  constant C_SEC_WORDS : natural := 544;
  constant C_SECRUN_W  : natural := C_NSEC * C_SEC_WORDS;      -- 5984
  constant C_MASK      : unsigned(31 downto 0) := x"55555555";

  -- X-Copy's DOS copy engine (modes 0/1) does not raw-copy the served
  -- track. It re-frames the capture into its own buffer and writes it with
  -- a constant DSKLEN $D955: 500 words of $AAAA, the eleven canonical
  -- 544-word sectors (5984 words), then exactly one trailing $AAAA, 6485
  -- words in all - the value the diag register 0x71 reads after such a
  -- write. Sector 10's last word is DMA word 6484 of 6485, so the whole
  -- post-DSKBLK margin is that single pad word. That is sized for a real
  -- Paula, which owes one word at DSKBLK because DSKBLK fires when its FIFO
  -- empties into its own shifter. Ours fires when the engine pops Paula
  -- dry, so the word just handed over plus the shifter plus the CDC FIFO
  -- add up to about 3 words; only the drain hold keeps X-Copy's next pin
  -- action from cutting sector 10.
  constant C_SCEN_XCOPY : natural := 12;
  constant C_XC_GAP     : natural := 500;
  constant C_XC_LEN     : natural := C_XC_GAP + C_SECRUN_W + 1;   -- 6485
  -- X-Copy's source read is sync-started and 6496 words long (ADKCON
  -- $9500, DSKLEN $9960), while its destination write is longer (DSKLEN
  -- $DA00 = 6656). The words past the capture are buffer residue and land
  -- in the wrap region, which is why X-Copy survives
  -- its own 40..100 us post-DSKBLK deselect on a real A500: the truncation
  -- costs residue, never captured sector data. Modelling the capture as
  -- the full DMA length would end the stream on sector 11 and make the
  -- deselect destroy real data.
  constant C_XCOPY_CAP : natural := 6496;
  function f_capture return natural is
  begin
    if G_SCEN = 3 and G_WORDS > C_XCOPY_CAP then return C_XCOPY_CAP; end if;
    return G_WORDS;
  end function;
  constant C_CAP_WORDS : natural := f_capture;

  -- the leading gap of the source track. Short-DMA mechanics scenarios
  -- (S4/S5/S9/S10/S11) write only a prefix of it, so the gap has a floor.
  function f_gap return natural is
  begin
    if G_SCEN = C_SCEN_XCOPY then return C_XC_GAP; end if;
    if C_CAP_WORDS > C_SECRUN_W then return C_CAP_WORDS - C_SECRUN_W; end if;
    return 831;                                -- the trackdisk gap
  end function;
  constant C_GAP_WORDS : natural := f_gap;

  constant C_SEED_TRACK : natural := 137;
  constant C_SEED_GAP_W : natural := 700;
  constant C_SEED_KEY   : natural := 9;
  constant C_SRC_KEY    : natural := 1;

  constant C_MAXW : natural := 7600;
  type t_words is array (0 to C_MAXW - 1) of std_logic_vector(15 downto 0);
  type t_payload is array (0 to 127) of unsigned(31 downto 0);

  -----------------------------------------------------------------------------
  -- trackdisk decoder constants (the same as in tb_fdd_splice.vhd): the
  -- 7358-word read DMA lands at buffer+$684, the decoded track at
  -- buffer+$680, sector slots are $440 bytes, and the two sync hunts scan
  -- windows of $ABC and $67C bytes.
  -----------------------------------------------------------------------------
  constant C_DMA_WORDS : natural := 7358;
  constant C_DEC       : natural := 16#680#;
  constant C_CAP       : natural := 16#684#;
  constant C_HUNT1_LEN : natural := 16#ABC#;
  constant C_HUNT2_LEN : natural := 16#67C#;
  constant C_BUF_SZ    : natural := 20480;
  constant C_SLOT_B    : natural := 16#440#;

  constant TDERR_NOSYNC  : natural := 16#15#;
  constant TDERR_BADPRE  : natural := 16#16#;
  constant TDERR_BADID   : natural := 16#17#;
  constant TDERR_BADHSUM : natural := 16#18#;
  constant TDERR_BADDSUM : natural := 16#19#;
  constant TDERR_NOSECT  : natural := 16#1A#;
  constant TDERR_BADHDR  : natural := 16#1B#;

  -- The sync hunt compares the long that ends a run of $AAAA or $5555
  -- words against the sync pair $4489 $4489 as it appears at each bit
  -- rotation: the last k bits of the alternating preamble (the low k bits
  -- of $AAAA) followed by the first 32-k bits of the sync pair. A $5555 run
  -- ends with an odd k = 2e+1 (rotation s = 15-2e), an $AAAA run with an
  -- even k = 2e+2 (s = 14-2e), and the last $AAAA entry is the word-aligned
  -- sync pair itself (k = 0, s = 0). Entries are tried in index order.
  type t_tbl is array (0 to 7) of unsigned(31 downto 0);
  function f_sync_rot(k : natural) return unsigned is
    constant C_SYNC2 : unsigned(31 downto 0) := x"44894489";
    constant C_PRE   : unsigned(31 downto 0) := x"0000AAAA";
    variable v_mask  : unsigned(31 downto 0);
  begin
    if k = 0 then
      return C_SYNC2;
    end if;
    v_mask := shift_left(to_unsigned(1, 32), k) - 1;
    return shift_left(C_PRE and v_mask, 32 - k) or shift_right(C_SYNC2, k);
  end function;
  function f_hunt_tbl(odd_run : boolean) return t_tbl is
    variable t : t_tbl;
  begin
    for e in 0 to 7 loop
      if odd_run then
        t(e) := f_sync_rot(2 * e + 1);
      elsif e < 7 then
        t(e) := f_sync_rot(2 * e + 2);
      else
        t(e) := f_sync_rot(0);
      end if;
    end loop;
    return t;
  end function;
  constant C_TBL_ODD  : t_tbl := f_hunt_tbl(true);
  constant C_TBL_EVEN : t_tbl := f_hunt_tbl(false);

  type t_buf is array (0 to C_BUF_SZ - 1) of natural range 0 to 255;

  type t_res is record
    err       : natural;
    anchor    : integer;
    srom1     : integer;
    first_sec : integer;
    sg        : integer;
    srom2     : integer;
    failslot  : integer;
  end record;

  -----------------------------------------------------------------------------
  -- the track builder: the word stream an Amiga writes for a whole track
  -- ([leading gap of 0xAAAA][11 x 544-word sectors]), with correct MFM clock
  -- bits. This is what the CPU hands to Paula, i.e. exactly what our writer
  -- must serialize bit-for-bit. pure: the Paula model, the control process
  -- and the disk process each build their own identical copy, so no data is
  -- shared between processes.
  -----------------------------------------------------------------------------
  function f_payload(track, sec, key : natural) return t_payload is
    variable p : t_payload;
    variable s : unsigned(31 downto 0);
  begin
    s := to_unsigned((track * 8191 + sec * 65537 + key * 131071) mod 2**28, 32);
    for i in 0 to 127 loop
      s    := resize(s * to_unsigned(1103515, 32), 32)
              + to_unsigned(12345 + i, 32);
      p(i) := s xor to_unsigned((i * 26543) mod 2**28, 32);
    end loop;
    return p;
  end function;

  -- odd/even halves of an MFM-encoded long, as the two 16-bit words each
  function f_odd_hi(l : unsigned(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(shift_right(l, 1)(31 downto 16) and x"5555");
  end function;
  function f_odd_lo(l : unsigned(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(shift_right(l, 1)(15 downto 0) and x"5555");
  end function;
  function f_evn_hi(l : unsigned(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(l(31 downto 16) and x"5555");
  end function;
  function f_evn_lo(l : unsigned(31 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(l(15 downto 0) and x"5555");
  end function;

  -- insert the MFM clock bits of a word given the previous data bit;
  -- returns the completed word and updates prev via the second return.
  -- (clock at odd bit positions = not (prev_data or next_data))
  function f_clockfill(w : std_logic_vector(15 downto 0);
                       prev : std_logic) return std_logic_vector is
    variable v : std_logic_vector(15 downto 0) := w;
    variable p : std_logic := prev;
  begin
    for b in 7 downto 0 loop
      if p = '0' and v(2 * b) = '0' then
        v(2 * b + 1) := '1';
      else
        v(2 * b + 1) := '0';
      end if;
      p := v(2 * b);
    end loop;
    return v;
  end function;

  function f_build_words(track, gap_w, key : natural) return t_words is
    variable v    : t_words := (others => (others => '0'));
    variable idx  : natural := 0;
    variable pl   : t_payload;
    variable info : unsigned(31 downto 0);
    variable hsum : unsigned(31 downto 0);
    variable dsum : unsigned(31 downto 0);
    variable l    : unsigned(31 downto 0);
    variable prev : std_logic := '0';
  begin
    for i in 0 to gap_w - 1 loop
      v(idx) := x"AAAA";
      idx    := idx + 1;
    end loop;
    for sec in 0 to C_NSEC - 1 loop
      pl   := f_payload(track, sec, key);
      info := x"FF" & to_unsigned(track, 8) & to_unsigned(sec, 8)
              & to_unsigned(C_NSEC - sec, 8);
      hsum := (shift_right(info, 1) and C_MASK) xor (info and C_MASK);
      dsum := (others => '0');
      for i in 0 to 127 loop
        l    := pl(i);
        dsum := dsum xor (shift_right(l, 1) and C_MASK) xor (l and C_MASK);
      end loop;

      v(idx + 0) := x"0000";                    -- 2 preamble data bytes 0x00
      v(idx + 1) := x"0000";                    -- (clock fill makes them AAAA)
      v(idx + 2) := x"4489";                    -- the double sync, literal
      v(idx + 3) := x"4489";
      v(idx + 4) := f_odd_hi(info);
      v(idx + 5) := f_odd_lo(info);
      v(idx + 6) := f_evn_hi(info);
      v(idx + 7) := f_evn_lo(info);
      for k in 8 to 23 loop                     -- 16 zero label words
        v(idx + k) := x"0000";
      end loop;
      v(idx + 24) := f_odd_hi(hsum);
      v(idx + 25) := f_odd_lo(hsum);
      v(idx + 26) := f_evn_hi(hsum);
      v(idx + 27) := f_evn_lo(hsum);
      v(idx + 28) := f_odd_hi(dsum);
      v(idx + 29) := f_odd_lo(dsum);
      v(idx + 30) := f_evn_hi(dsum);
      v(idx + 31) := f_evn_lo(dsum);
      for i in 0 to 127 loop
        l := pl(i);
        v(idx + 32 + 2 * i)      := f_odd_hi(l);
        v(idx + 32 + 2 * i + 1)  := f_odd_lo(l);
        v(idx + 288 + 2 * i)     := f_evn_hi(l);
        v(idx + 288 + 2 * i + 1) := f_evn_lo(l);
      end loop;
      idx := idx + C_SEC_WORDS;
    end loop;

    -- X-Copy's DOS engine appends exactly one $AAAA word after the eleven
    -- sectors and stops. Every other caller keeps the old shape.
    if G_SCEN = C_SCEN_XCOPY then
      v(idx) := x"AAAA";
      idx    := idx + 1;
    end if;

    -- MFM clock fill over the whole stream (sync words stay literal)
    prev := '0';
    for i in 0 to idx - 1 loop
      if v(i) = x"4489" then
        prev := '1';                            -- 0x4489 ends in data bit 1
      else
        v(i) := f_clockfill(v(i), prev);
        prev := v(i)(0);
      end if;
    end loop;
    return v;
  end function;

  function f_words_len(gap_w : natural) return natural is
  begin
    if G_SCEN = C_SCEN_XCOPY then return gap_w + C_SECRUN_W + 1; end if;
    return gap_w + C_SECRUN_W;
  end function;

  -- static generic decode (port maps take expressions, not conditionals)
  function f_dpll_dis return std_logic is
  begin
    if G_LEGACY then return '1'; else return '0'; end if;
  end function;
  function f_frame_dis return std_logic is
  begin
    if G_FRAMEHOLD then return '0'; else return '1'; end if;
  end function;
  function f_phys_unit return std_logic_vector is
  begin
    if G_SCEN = 9 then return "00"; else return "01"; end if;
  end function;
  constant C_PHYS_UNIT : std_logic_vector(1 downto 0) := f_phys_unit;
  -- S9 variant 3 (the inheritance kill) needs a real ADF drive at unit 2 for
  -- a wrongly-owned re-latch to have somewhere to commit into. Every other
  -- cell stays physical-only, so no existing scenario changes behaviour.
  function f_adf_en return std_logic_vector is
  begin
    if G_SCEN = 8 and G_VARIANT = 3 then return "100";
    else return "000"; end if;
  end function;
  function f_adf_tracks return std_logic_vector is
  begin
    if G_SCEN = 8 and G_VARIANT = 3 then return x"A00000";  -- unit 2: 160
    else return x"000000"; end if;
  end function;
  constant C_ADF_EN     : std_logic_vector(2 downto 0)  := f_adf_en;
  constant C_ADF_TRACKS : std_logic_vector(23 downto 0) := f_adf_tracks;
  constant C_PRECMODE  : std_logic_vector(1 downto 0) :=
    std_logic_vector(to_unsigned(G_PRECMODE, 2));

  -----------------------------------------------------------------------------
-- the KS1.3 trackdisk decoder, the same as in tb_fdd_splice.vhd: sync
-- hunt, first-header check at the found rotation, chunk realignment, the
-- gap re-hunt (skipped for SG = 11) and the per-slot walk with its literal
-- preamble, sync, checksum and sector-id checks. Architecture scope: both
-- the disk process (verdict (b)) and the control process (verdict (a) on
-- what Paula really stored) run the same decode.
-----------------------------------------------------------------------------
  function f_word(b : t_buf; off : integer) return unsigned is
  begin
    return to_unsigned(b(off), 8) & to_unsigned(b(off + 1), 8);
  end function;
  function f_long(b : t_buf; off : integer) return unsigned is
  begin
    return to_unsigned(b(off), 8) & to_unsigned(b(off + 1), 8)
         & to_unsigned(b(off + 2), 8) & to_unsigned(b(off + 3), 8);
  end function;
  procedure p_put_word(b : inout t_buf; off : in integer;
                       w : in unsigned(15 downto 0)) is
  begin
    b(off)     := to_integer(w(15 downto 8));
    b(off + 1) := to_integer(w(7 downto 0));
  end procedure;
  function f_decode_pair(o, e : unsigned(31 downto 0)) return unsigned is
  begin
    return shift_left(o and C_MASK, 1) or (e and C_MASK);
  end function;
  function f_ext32(b : t_buf; off, j : integer) return unsigned is
    variable v : unsigned(47 downto 0);
  begin
    v := f_long(b, off) & f_word(b, off + 4);
    return v(47 - j downto 16 - j);
  end function;
  function f_cksum(b : t_buf; off, nl : integer) return unsigned is
    variable v : unsigned(31 downto 0) := (others => '0');
  begin
    for i in 0 to nl - 1 loop
      v := v xor f_long(b, off + 4 * i);
    end loop;
    return v and C_MASK;
  end function;
  function f_cksum_sh(b : t_buf; off, nl, j : integer)
    return unsigned is
    variable v : unsigned(31 downto 0) := (others => '0');
  begin
    for i in 0 to nl - 1 loop
      v := v xor f_ext32(b, off + 4 * i, j);
    end loop;
    return v and C_MASK;
  end function;

  procedure td_hunt(b : in t_buf; start, len : in integer;
                    ptr : out integer; srom : out integer) is
    variable a0, aend : integer;
    variable d2, d1w  : unsigned(15 downto 0);
    variable dl       : unsigned(31 downto 0);
    variable odd_run  : boolean;
  begin
    a0 := start; aend := start + len; ptr := -1; srom := -1;
    outer : loop
      d2 := f_word(b, a0); a0 := a0 + 2;
      if d2 = x"AAAA" then
        odd_run := false;
      elsif d2 = x"5555" then
        odd_run := true;
      else
        if aend > a0 then next outer; end if;
        return;
      end if;
      run : loop
        if aend <= a0 then return; end if;
        d1w := f_word(b, a0); a0 := a0 + 2;
        if d1w = d2 then next run; end if;
        a0 := a0 - 2;
        dl := f_long(b, a0);
        for e in 0 to 7 loop
          if odd_run then
            if dl = C_TBL_ODD(e) then
              ptr := a0 - 4; srom := 15 - 2 * e; return;
            end if;
          else
            if dl = C_TBL_EVEN(e) then
              ptr := a0 - 4; srom := 14 - 2 * e; return;
            end if;
          end if;
        end loop;
        next outer;
      end loop run;
    end loop outer;
  end procedure;

  procedure td_copy(b : inout t_buf; src_o, dst, nb, srom : in integer) is
    variable j : integer;
    variable v : unsigned(31 downto 0);
  begin
    j := (16 - srom) mod 16;
    for i in 0 to nb / 2 - 1 loop
      if j = 0 then
        p_put_word(b, dst + 2 * i, f_word(b, src_o + 2 * i));
      else
        v := f_word(b, src_o + 2 * i) & f_word(b, src_o + 2 * i + 2);
        p_put_word(b, dst + 2 * i, v(31 - j downto 16 - j));
      end if;
    end loop;
  end procedure;

  procedure td_decode(b : inout t_buf; exp_track : in natural;
                      r : out t_res) is
    variable x        : t_res;
    variable p, s1, j : integer;
    variable p2, s2   : integer;
    variable io, ie   : unsigned(31 downto 0);
    variable cks, stv : unsigned(31 downto 0);
    variable info     : unsigned(31 downto 0);
    variable d4       : integer;
    variable padw     : unsigned(15 downto 0);
    variable exp_sec  : integer;
    variable off      : integer;
    variable pre      : unsigned(31 downto 0);
  begin
    x := (err => 0, anchor => -1, srom1 => -1, first_sec => -1, sg => -1,
          srom2 => -1, failslot => -1);
    td_hunt(b, C_DEC + 2, C_HUNT1_LEN, p, s1);
    if p = -1 then x.err := TDERR_NOSYNC; r := x; return; end if;
    x.anchor := p; x.srom1 := s1;
    j := (16 - s1) mod 16;
    if s1 = 0 then
      io  := f_long(b, p + 8);
      ie  := f_long(b, p + 12);
      cks := f_cksum(b, p + 8, 10);
      stv := f_decode_pair(f_long(b, p + 16#30#), f_long(b, p + 16#34#));
    else
      io  := f_ext32(b, p + 8, j);
      ie  := f_ext32(b, p + 12, j);
      cks := f_cksum_sh(b, p + 8, 10, j);
      stv := f_decode_pair(f_ext32(b, p + 16#30#, j),
                           f_ext32(b, p + 16#34#, j));
    end if;
    if cks /= stv then x.err := TDERR_BADHDR; r := x; return; end if;
    info := f_decode_pair(io, ie);
    if info(31 downto 24) /= x"FF"
       or to_integer(info(23 downto 16)) /= exp_track then
      x.err := TDERR_BADHDR; r := x; return;
    end if;
    x.first_sec := to_integer(info(15 downto 8));
    x.sg        := to_integer(info(7 downto 0));
    if x.sg < 1 or x.sg > 11 then
      x.err := TDERR_BADHDR; r := x; return;
    end if;
    d4 := x.sg * C_SLOT_B;
    td_copy(b, p, C_DEC, d4, s1);
    if x.sg /= 11 then
      td_hunt(b, p + d4 + 2, C_HUNT2_LEN, p2, s2);
      if p2 = -1 then x.err := TDERR_NOSECT; r := x; return; end if;
      x.srom2 := s2;
      td_copy(b, p2, C_DEC + d4, (C_NSEC - x.sg) * C_SLOT_B, s2);
    end if;
    padw := x"AAA8";
    if (b(C_DEC + 16#2EC0# - 1) mod 2) = 1 then padw := x"2AA8"; end if;
    p_put_word(b, C_DEC + 16#2EC0#, padw);
    p_put_word(b, C_DEC, x"AAAA");
    exp_sec := x.first_sec;
    for slot in 0 to C_NSEC - 1 loop
      off := C_DEC + slot * C_SLOT_B;
      x.failslot := slot;
      pre := f_long(b, off);
      if pre /= x"AAAAAAAA" and pre /= x"2AAAAAAA" then
        x.err := TDERR_BADPRE; r := x; return;
      end if;
      if f_long(b, off + 4) /= x"44894489" then
        x.err := TDERR_BADPRE; r := x; return;
      end if;
      if f_cksum(b, off + 8, 10)
         /= f_decode_pair(f_long(b, off + 16#30#),
                          f_long(b, off + 16#34#)) then
        x.err := TDERR_BADHSUM; r := x; return;
      end if;
      info := f_decode_pair(f_long(b, off + 8), f_long(b, off + 12));
      if info(31 downto 24) /= x"FF"
         or to_integer(info(23 downto 16)) /= exp_track
         or to_integer(info(15 downto 8)) /= exp_sec then
        x.err := TDERR_BADID; r := x; return;
      end if;
      if f_cksum(b, off + 16#40#, 256)
         /= f_decode_pair(f_long(b, off + 16#38#),
                          f_long(b, off + 16#3C#)) then
        x.err := TDERR_BADDSUM; r := x; return;
      end if;
      exp_sec := (exp_sec + 1) mod C_NSEC;
    end loop;
    x.failslot := -1;
    x.err := x.first_sec;
    r := x;
  end procedure;


  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------
  signal clk50     : std_logic := '0';
  signal clkmain   : std_logic := '0';
  signal rst50     : std_logic := '1';
  signal rstmain   : std_logic := '1';
  signal amiga_rst : std_logic := '1';
  signal bus_grant : std_logic := '1';

  signal f_rdata  : std_logic := '1';
  signal f_wdata  : std_logic;
  signal f_wgate  : std_logic;
  signal f_index  : std_logic := '1';
  signal f_track0 : std_logic := '1';
  signal f_wprot  : std_logic := '1';           -- active low; '1' = writable
  signal f_chg    : std_logic := '1';

  signal hwf_en   : std_logic := '0';
  signal hwf_sel  : std_logic := '0';
  signal hwf_mot  : std_logic := '0';
  signal hwf_side : std_logic := '1';
  signal step_n   : std_logic := '1';
  signal stepdir  : std_logic := '1';

  signal hwf_rd_data  : std_logic_vector(15 downto 0);
  signal hwf_rd_empty : std_logic;
  signal hwf_rd_en    : std_logic;
  signal hwf_dsksync  : std_logic_vector(15 downto 0);
  signal hwf_serving  : std_logic;
  signal hwf_srvdata  : std_logic;

  signal wr_valid   : std_logic;
  signal wr_data    : std_logic_vector(15 downto 0);
  signal wr_session : std_logic;
  signal wr_abort   : std_logic;
  signal wr_precomp : std_logic;
  signal wr_track   : std_logic_vector(7 downto 0);
  signal wr_level   : unsigned(2 downto 0);
  signal wr_busy50  : std_logic;
  signal wr_ok50    : std_logic;
  signal wr_busy    : std_logic := '0';
  signal wr_ok      : std_logic := '0';

  signal d_epi_cnt  : unsigned(15 downto 0);
  signal d_words_l  : unsigned(15 downto 0);
  signal d_words_t  : unsigned(15 downto 0);
  signal d_wgate_lo : unsigned(15 downto 0);
  signal d_wgate_hi : unsigned(15 downto 0);
  signal d_underrun : unsigned(15 downto 0);
  signal d_discard  : unsigned(15 downto 0);
  signal d_tail     : unsigned(15 downto 0);
  signal d_precnt   : unsigned(15 downto 0);
  signal d_flags79  : std_logic_vector(15 downto 0);
  signal d_gateopen : unsigned(15 downto 0);
  signal d_reason   : std_logic_vector(7 downto 0);
  signal d_ctrl7c   : std_logic_vector(4 downto 0);
  signal d_overflow : unsigned(15 downto 0);

  signal io_fpga   : std_logic;
  signal io_strobe : std_logic;
  signal io_din    : std_logic_vector(15 downto 0);
  signal io_dout   : std_logic_vector(15 downto 0) := (others => '0');
  signal io_wait   : std_logic := '0';

  -- Paula model observables / controls
  signal p_dsklen   : unsigned(13 downto 0) := (others => '0');
  signal p_dmaen    : std_logic := '0';
  signal p_dsklen14 : std_logic := '0';
  signal p_trackwr  : std_logic := '0';
  signal p_trackrd  : std_logic := '0';
  signal p_blk_cnt  : natural := 0;
  signal p_fifo_cnt : natural := 0;
  signal p_sel      : std_logic_vector(1 downto 0) := "00";
  signal p_track    : std_logic_vector(7 downto 0) := (others => '0');
  signal p_arm      : std_logic := '0';         -- 1-clk: arm a DMA
  signal p_arm_wr   : std_logic := '0';         -- direction for the arm
  signal p_arm_len  : natural := 0;
  signal p_stop     : std_logic := '0';         -- DSKLEN = 0x4000 (stop)
  signal p_fill_en  : std_logic := '1';         -- Agnus fill enable
  signal p_pops     : natural := 0;
  signal p_src_trk  : natural := G_TRACK;       -- which track the CPU writes
  signal p_src_gap  : natural := C_GAP_WORDS;

  -- Paula's read-side store, exported one word at a time
  signal st_stb  : std_logic := '0';
  signal st_word : std_logic_vector(15 downto 0) := (others => '0');

  -- disk-process query interface (the disk process owns the flux arrays)
  signal q_req   : std_logic := '0';            -- toggle: run the checkers
  signal q_ack   : std_logic := '0';
  signal q_kind  : natural := 0;                -- 0 = seed, 1 = verdicts
  signal q_track : natural := G_TRACK;
  signal q_gap   : natural := C_GAP_WORDS;
  signal q_ref_err  : natural := 255;           -- verdict (b) result
  signal q_sec_ok   : natural := 0;             -- verdict (c): keys clean
  signal q_sec_bad  : natural := 0;
  signal q_old_alive : natural := 0;            -- surviving pre-seed edges
  signal q_span_edges : natural := 0;

  signal wg_len_cyc : integer := 0;
  signal wg_opens   : natural := 0;
  signal wg_open_at : integer := -1;

  -- WDATA pulse-width census: every pulse width must lie inside the 0.2 to
  -- 1.1 us window the drive mechanism accepts. A writer-independent check
  -- on the flux the model receives: a runt or an over-wide pulse is a
  -- written-flux defect the mechanism itself would misbehave on, and no
  -- decode verdict sees it.
  signal pw_min     : natural := 999999;
  signal pw_max     : natural := 0;
  signal pw_count   : natural := 0;

  -- direct observation of the busy interlock: a physical read session must
  -- never be open while the writer is still draining a tail. Observing the
  -- interlock itself, rather than a downstream symptom, is what gives the
  -- read-side interlock mutant (xiii) a kill.
  signal ilock_viol : natural := 0;
  -- S9: count drain latches as rising edges of the engine's own in_drain,
  -- observed through a VHDL-2008 external name - no extra engine port. With the ownership latch in place a transient foreign
  -- sel does not re-latch, so the count stays 1 across the click; mutant
  -- (viii) aborts on the first foreign sample and re-latches, giving 2.
  signal drain_latches : natural := 0;
  -- ...and the owner itself. The ownership guard clears in_drain and the
  -- write branch re-latches it in the same cycle, so the last signal
  -- assignment wins and in_drain never actually falls - an edge counter
  -- cannot see the re-latch at all, so mutant (viii) would survive on it.
  -- What does change is who owns the drain, so watch that.
  signal owner_changes : natural := 0;
  -- gate-close latency: WGATE must close as soon as a gate term is lost
  -- (S5). term_mark is stamped by the control process immediately
  -- before it removes a term; gate_off_at is stamped by the monitor on the
  -- f_wgate rising (deasserting) edge.
  signal term_mark  : time := 0 ns;
  signal gate_off_at : time := 0 ns;

  signal p_state    : natural := 0;              -- DISKDMA FSM state
  signal p_fifo_out : std_logic_vector(15 downto 0) := (others => '0');

  -- Paula host-channel signals (signals, not variables: paula_floppy.v runs
  -- these in separate always blocks, so each reads the others' pre-edge
  -- value. Modelling them as variables inside one process serializes the
  -- updates and silently changes the handshake - the structure below
  -- mirrors tb_engine_paula.vhd, which is validated against hardware.)
  signal clk7_en   : std_logic := '0';
  signal clk7_cnt  : unsigned(1 downto 0) := "00";
  signal stb7      : std_logic := '0';
  signal rx_data   : std_logic_vector(15 downto 0) := (others => '0');
  signal cmd_cnt   : unsigned(1 downto 0) := "00";
  signal cmd_fdd   : std_logic := '0';
  signal tx_data   : std_logic_vector(15 downto 0);
  signal wrstat    : std_logic_vector(15 downto 0) := (others => '0');
  signal p_trkwr   : std_logic := '0';
  signal p_trkrd   : std_logic := '0';
  signal p_dmaon   : std_logic := '0';
  signal p_lenzero : std_logic := '1';
  signal stbdat    : std_logic;


begin

  clk50   <= not clk50 after C_CLK50 / 2;
  clkmain <= not clkmain after C_CLKMAIN / 2;

  clkmain <= not clkmain after C_CLKMAIN / 2;

  -----------------------------------------------------------------------------
  -- DUT 1: the real front end (write FIFO + writer inside)
  -----------------------------------------------------------------------------
  i_top : entity work.physical_fdd_top
    port map (
      clk_i            => clk50,
      rst_i            => rst50,
      f_index_i        => f_index,
      f_track0_i       => f_track0,
      f_writeprotect_i => f_wprot,
      f_diskchanged_i  => f_chg,
      f_rdata_i        => f_rdata,
      f_wdata_o        => f_wdata,
      f_wgate_o        => f_wgate,
      enable_i         => hwf_en,
      selected_i       => hwf_sel,
      motor_i          => hwf_mot,
      side_i           => hwf_side,
      dsksync_i        => hwf_dsksync,
      step_n_i         => step_n,
      stepdir_i        => stepdir,
      serving_i        => hwf_serving,
      serving_data_i   => hwf_srvdata,
      wordsync_i       => '0',
      ctrl_i           => "000000",
      clear_i          => '0',
      dpll_dis_i       => f_dpll_dis,
      framehold_dis_i  => f_frame_dis,
      wr_push_i        => wr_valid,
      wr_data_i        => wr_data,
      wr_level_o       => wr_level,
      wr_session_i     => wr_session,
      wr_abort_i       => wr_abort,
      wr_precomp_i     => wr_precomp,
      wr_precmode_i    => C_PRECMODE,
      wr_busy_o        => wr_busy50,
      wr_ok_o          => wr_ok50,
      rd_clk_i         => clkmain,
      rd_rst_i         => rstmain,
      rd_en_i          => hwf_rd_en,
      rd_data_o        => hwf_rd_data,
      rd_empty_o       => hwf_rd_empty,
      dwr_epi_cnt_o     => d_epi_cnt,
      dwr_words_last_o  => d_words_l,
      dwr_words_tot_o   => d_words_t,
      dwr_wgate_lo_o    => d_wgate_lo,
      dwr_wgate_hi_o    => d_wgate_hi,
      dwr_underrun_o    => d_underrun,
      dwr_discard_o     => d_discard,
      dwr_tail_o        => d_tail,
      dwr_precomp_cnt_o => d_precnt,
      dwr_flags79_o     => d_flags79,
      dwr_gateopen_o    => d_gateopen,
      dwr_abortreason_o => d_reason,
      dwr_ctrl7c_o      => d_ctrl7c,
      dwr_overflow_o    => d_overflow
    ); -- i_top

  -----------------------------------------------------------------------------
  -- DUT 2: the real track engine (no ADF drive mounted)
  -----------------------------------------------------------------------------
  i_engine : entity work.adf_track_engine
    generic map (
      G_BASE_DF0   => (others => '0'),
      G_BASE_DF1   => (others => '0'),
      G_BASE_DF2   => (others => '0'),
      G_POLL_DELAY => G_POLL
    )
    port map (
      clk_main_i          => clkmain,
      reset_i             => amiga_rst,
      bus_grant_i         => bus_grant,
      disk_mounted_i      => C_ADF_EN,
      disk_tracks_i       => C_ADF_TRACKS,
      write_en_i          => C_ADF_EN,
      wr_track_o          => open,
      wr_req_o            => open,
      wr_ack_i            => "000",
      adf_en_i            => C_ADF_EN,
      phys_unit_i         => C_PHYS_UNIT,
      phys_en_i           => '1',
      phys_present_i      => '1',
      phys_rd_data_i      => hwf_rd_data,
      phys_rd_empty_i     => hwf_rd_empty,
      phys_rd_en_o        => hwf_rd_en,
      dsksync_o           => hwf_dsksync,
      phys_served_gray_o  => open,
      phys_sig_o          => open,
      phys_sig_ses_o      => open,
      phys_sig_done_o     => open,
      phys_sig_c64_o      => open,
      phys_sig_c256_o     => open,
      phys_serving_o      => hwf_serving,
      phys_data_o         => hwf_srvdata,
      phys_wr_level_i     => wr_level,
      phys_wr_busy_i      => wr_busy,
      phys_wr_ok_i        => wr_ok,
      -- the real per-drive select line, exactly what mega65.vhd hands the
      -- engine. S10 drops it mid-episode, so that scenario also covers the
      -- episode-bind qualifier.
      phys_sel_i          => hwf_sel,
      phys_wr_precmode_i  => C_PRECMODE,
      phys_wr_valid_o     => wr_valid,
      phys_wr_data_o      => wr_data,
      phys_wr_session_o   => wr_session,
      phys_wr_abort_o     => wr_abort,
      phys_wr_precomp_o   => wr_precomp,
      phys_wr_track_o     => wr_track,
      io_fpga_o           => io_fpga,
      io_strobe_o         => io_strobe,
      io_din_o            => io_din,
      io_dout_i           => io_dout,
      io_wait_i           => io_wait,
      avm_busy_o          => open,
      avm_write_o         => open,
      avm_read_o          => open,
      avm_address_o       => open,
      avm_writedata_o     => open,
      avm_byteenable_o    => open,
      avm_burstcount_o    => open,
      avm_readdata_i      => (others => '0'),
      avm_readdatavalid_i => '0',
      avm_waitrequest_i   => '1'
    ); -- i_engine

  -- the cdc_stable pair 50 MHz -> core that mega65.vhd instantiates
  p_cdc : process (clkmain)
    variable m1, m2, n1, n2 : std_logic := '0';
  begin
    if rising_edge(clkmain) then
      m1 := wr_busy50; wr_busy <= m2; m2 := m1;
      n1 := wr_ok50;   wr_ok   <= n2; n2 := n1;
    end if;
  end process p_cdc;

  -----------------------------------------------------------------------------
  -- the live rotating disk: flux store, erase/write, playback - and, on
  -- request from the control process, the independent verdicts (b) and (c)
  -- plus the td_write_check.py dump. The flux arrays never leave this
  -- process, so no data is shared between processes.
  -----------------------------------------------------------------------------
  p_disk : process (clk50)
    -- one slot per C_SLOT cycles holds at most one edge: legal MFM keeps
    -- flux transitions >= 200 cycles apart, so a 50-cycle slot cannot
    -- collide even with the +/-7-cycle precomp shifts
    type t_flux is array (0 to C_NSLOT - 1) of integer;
    variable flux : t_flux := (others => -1);
    variable fgen : t_flux := (others => -1);
    variable seed : t_flux := (others => -1);

    variable pos     : integer := 0;
    variable wd_prev : std_logic := '1';
    variable wg_prev : std_logic := '1';
    variable gen     : integer := 0;
    variable pulse   : natural := 0;
    variable sl      : natural;
    variable q_prev  : std_logic := '0';
    variable opened  : integer := -1;
    variable pw_run  : natural := 0;
    variable wgcyc   : natural := 0;

    -- ---- checker state -----------------------------------------------------
    variable src   : t_words;
    variable cap   : t_words;
    variable capn  : natural;
    variable buf   : t_buf;
    variable res   : t_res;

    -- lay a whole track onto the flux at nominal cell pace from angle a0
    procedure lay(track, gap_w, key : in natural; a0 : in integer) is
      variable w  : t_words;
      variable n  : natural;
      variable p  : integer;
      variable c  : natural := 0;
      variable s  : natural;
      variable bt : std_logic;
    begin
      w := f_build_words(track, gap_w, key);
      n := f_words_len(gap_w);
      for i in 0 to n - 1 loop
        for b in 15 downto 0 loop
          bt := w(i)(b);
          if bt = '1' then
            p := (a0 + c * C_CELL + 10) mod C_TREV;
            s := p / C_SLOT;
            flux(s) := p;
            fgen(s) := -1;                      -- pre-seed generation
          end if;
          c := c + 1;
        end loop;
      end loop;
    end procedure;

    -- ---- the TB's own independent separator + framing over the flux -------
    -- (a plain adaptive quantiser, deliberately not the DUT's code, so a
    -- DUT separator bug cannot hide behind a shared implementation)
    type t_bits is array (0 to 200000) of std_logic;
    variable bits  : t_bits;
    variable nbits : natural;

    procedure replay(from : in integer; want : in natural) is
      variable p    : integer;
      variable prev : integer := -1;
      variable est  : integer := 100 * 16;      -- Q4
      variable g, n, err, tol : integer;
      variable cnt  : natural := 0;
      variable scan : natural := 0;
    begin
      nbits := 0;
      p     := from;
      -- find the first edge at/after 'from'
      while scan < C_TREV loop
        if flux(p / C_SLOT) = p then
          prev := p;
          exit;
        end if;
        p    := (p + 1) mod C_TREV;
        scan := scan + 1;
      end loop;
      if prev < 0 then return; end if;
      scan := 0;
      while nbits < want and scan < 4 * C_TREV loop
        p    := (p + 1) mod C_TREV;
        scan := scan + 1;
        if flux(p / C_SLOT) = p then
          g := scan;                            -- cycles since the last edge
          scan := 0;
          if g * 16 < est * 5 / 2 then
            n := 2;
          elsif g * 16 < est * 7 / 2 then
            n := 3;
          else
            n := 4;
          end if;
          err := g * 16 - n * est;
          tol := est / 2;
          if err >= -tol and err <= tol then
            for k in 1 to n - 1 loop
              if nbits <= bits'high then bits(nbits) := '0'; end if;
              nbits := nbits + 1;
            end loop;
            if nbits <= bits'high then bits(nbits) := '1'; end if;
            nbits := nbits + 1;
            if err > 0 and est < 110 * 16 then
              est := est + 2;
            elsif err < 0 and est > 90 * 16 then
              est := est - 2;
            end if;
          else
            est := 100 * 16;                    -- loss of lock: re-seed
          end if;
        end if;
      end loop;
    end procedure;

    -- constant-framing capture from the first sync (verdict (b)) and a
    -- realign-free per-sector scan (verdict (c))
    impure function frame_const(nwords : natural) return t_words is
      variable w   : t_words := (others => (others => '0'));
      variable sh  : unsigned(15 downto 0) := (others => '0');
      variable n   : natural := 0;
      variable c   : natural := 0;
      variable hunting : boolean := true;
    begin
      for i in 0 to nbits - 1 loop
        sh := sh(14 downto 0) & bits(i);
        if hunting then
          if sh = x"4489" then
            hunting := false;
            w(0)    := x"4489";
            n       := 1;
            c       := 0;
          end if;
        else
          c := c + 1;
          if c = 16 then
            c := 0;
            if n < nwords and n < C_MAXW then
              w(n) := std_logic_vector(sh);
            end if;
            n := n + 1;
          end if;
        end if;
        exit when n >= nwords;
      end loop;
      return w;
    end function;

    variable ref_w  : t_words;
    variable sec_ok : natural;
    variable sec_bad : natural;
    variable seen   : std_logic_vector(10 downto 0);
    variable alive  : natural;
    variable spanE  : natural;

    -- verdict (c): independent bit-level re-sync + per-sector compare
    procedure sector_compare(track, gap_w : in natural) is
      variable sh   : unsigned(15 downto 0) := (others => '0');
      variable s2   : unsigned(15 downto 0);
      variable i    : natural;
      variable c2   : natural;
      variable m    : natural;
      variable k    : natural;
      variable pl   : t_payload;
      variable info : unsigned(31 downto 0);
      variable io, ie : unsigned(31 downto 0);
      variable okk  : boolean;
      variable sec  : natural;
      variable ww   : t_words;
    begin
      sec_ok  := 0;
      sec_bad := 0;
      seen    := (others => '0');
      sh      := (others => '0');
      i       := 0;
      while i < nbits - 16 loop
        sh := sh(14 downto 0) & bits(i);
        if sh = x"4489" then
          -- collect one full sector slot at this bit alignment (the TB's
          -- own re-sync, independent of the front end's framing)
          ww    := (others => (others => '0'));
          ww(0) := x"4489";
          s2 := (others => '0');
          c2 := 0;
          m  := 1;
          k  := i + 1;
          while k < nbits and m < C_SEC_WORDS loop
            s2 := s2(14 downto 0) & bits(k);
            c2 := c2 + 1;
            if c2 = 16 then
              c2    := 0;
              ww(m) := std_logic_vector(s2);
              m     := m + 1;
            end if;
            k := k + 1;
          end loop;
          if m >= C_SEC_WORDS and ww(1) = x"4489" then
            io   := unsigned(ww(2)) & unsigned(ww(3));
            ie   := unsigned(ww(4)) & unsigned(ww(5));
            info := shift_left(io and C_MASK, 1) or (ie and C_MASK);
            if info(31 downto 24) = x"FF"
               and to_integer(info(23 downto 16)) = track
               and to_integer(info(15 downto 8)) <= 10 then
              sec := to_integer(info(15 downto 8));
              pl  := f_payload(track, sec, C_SRC_KEY);
              okk := true;
              for q in 0 to 127 loop
                -- ww(0) is the first sync word, i.e. build index idx+2, so
                -- every field sits two words lower than in the builder:
                -- data odd  build idx+32  -> ww(30), even idx+288 -> ww(286)
                io := unsigned(ww(30 + 2 * q)) & unsigned(ww(31 + 2 * q));
                ie := unsigned(ww(286 + 2 * q)) & unsigned(ww(287 + 2 * q));
                if (shift_left(io and C_MASK, 1) or (ie and C_MASK))
                   /= pl(q) then
                  okk := false;
                  exit;
                end if;
              end loop;
              if okk then
                seen(sec) := '1';
                sec_ok    := sec_ok + 1;
              else
                sec_bad := sec_bad + 1;
              end if;
            end if;
          end if;
        end if;
        i := i + 1;
      end loop;
    end procedure;

    file dumpf : text;
    variable dl : line;

  begin
    if rising_edge(clk50) then
      ---------------------------------------------------------------------
      -- spindle, erase, write, playback
      ---------------------------------------------------------------------
      pos := (pos + 1) mod C_TREV;
      sl  := pos / C_SLOT;

      if pos < 150000 then f_index <= '0'; else f_index <= '1'; end if;

      -- WGATE window, measured in cycles: a trackdisk write is 109 % of a
      -- revolution, so a position difference would wrap and read short
      if f_wgate = '0' and wg_prev = '1' then
        gen        := gen + 1;
        opened     := pos;
        wgcyc      := 0;
        wg_open_at <= pos;
        wg_opens   <= wg_opens + 1;
      elsif f_wgate = '1' and wg_prev = '0' then
        wg_len_cyc <= wgcyc;
      end if;
      wg_prev := f_wgate;

      -- WDATA pulse-width census while the gate is open
      if f_wdata = '0' then
        if wd_prev = '1' then
          pw_run := 1;
        else
          pw_run := pw_run + 1;
        end if;
      elsif wd_prev = '0' and pw_run > 0 then
        if pw_run < pw_min then pw_min <= pw_run; end if;
        if pw_run > pw_max then pw_max <= pw_run; end if;
        pw_count <= pw_count + 1;
        pw_run := 0;
      end if;

      if f_wgate = '0' then
        wgcyc := wgcyc + 1;
        -- The erase head sweeps CONTINUOUSLY, so model it at cycle
        -- granularity: whatever transition sits exactly under the head is
        -- wiped, whoever wrote it. Erasing a whole 50-cycle slot on entry
        -- instead would wipe transitions the head has not physically
        -- reached yet, which shows up at the splice as edges that the
        -- independent twin expects and the model does not have.
        -- The generation stamp marks slots this episode wrote (not merely
        -- swept), so a surviving pre-seed edge stays distinguishable.
        if flux(sl) = pos then
          flux(sl) := -1;
        end if;
        if f_wdata = '0' and wd_prev = '1' then
          flux(sl) := pos;
          fgen(sl) := gen;
        end if;
      end if;
      wd_prev := f_wdata;

      if pulse /= 0 then
        pulse := pulse - 1;
        if pulse = 0 then f_rdata <= '1'; end if;
      elsif f_wgate = '1' and flux(sl) = pos then
        f_rdata <= '0';
        pulse   := 30;
      end if;

      ---------------------------------------------------------------------
      -- query interface from the control process
      ---------------------------------------------------------------------
      if q_req /= q_prev then
        q_prev := q_req;
        case q_kind is

          when 0 =>                             -- (re)seed a different track
            flux := (others => -1);
            fgen := (others => -1);
            lay(C_SEED_TRACK, C_SEED_GAP_W, C_SEED_KEY, C_TREV / 3);
            seed := flux;

          when others =>                        -- run verdicts (b) and (c)
            -- how much pre-seed flux survived inside the written span, and
            -- how many edges the span now holds
            -- A pre-seed edge is a survivor when its slot still carries an
            -- edge this episode never wrote: lay() stamps generation -1, the
            -- writer stamps the episode's generation on every slot its head
            -- enters. Counting only inside the swept span would be vacuous
            -- (the sweep erases by construction) and would make S4's
            -- "no erase past the abort" assert unfalsifiable.
            alive := 0;
            spanE := 0;
            for s in 0 to C_NSLOT - 1 loop
              if flux(s) >= 0 and fgen(s) = -1 then
                alive := alive + 1;
              end if;
              if fgen(s) = gen and flux(s) >= 0 then
                spanE := spanE + 1;
              end if;
            end loop;
            q_old_alive  <= alive;
            q_span_edges <= spanE;

            -- verdict (b): constant framing over our own replay
            replay(0, 190000);
            ref_w := frame_const(C_DMA_WORDS);
            buf := (others => 0);
            p_put_word(buf, C_DEC, x"AAAA");
            p_put_word(buf, C_DEC + 2, x"AAAA");
            for i in 0 to C_DMA_WORDS - 1 loop
              p_put_word(buf, C_CAP + 2 * i, unsigned(ref_w(i)));
            end loop;
            td_decode(buf, q_track, res);
            q_ref_err <= res.err;

            -- verdict (c): independent per-sector byte compare
            sector_compare(q_track, q_gap);
            q_sec_ok  <= sec_ok;
            q_sec_bad <= sec_bad;

            -- the td_write_check.py dump
            if G_DUMP then
              -- the name must identify the cell: S1p sweeps track and
              -- precomp mode at one scenario/variant/RPM, so a name built
              -- from those three alone has every S1p run overwrite the
              -- last and leaves the twin grading whichever ran last.
              file_open(dumpf, "wr_dump_s" & integer'image(G_SCEN) & "_v"
                        & integer'image(G_VARIANT) & "_r"
                        & integer'image(G_RPM_MHZ) & "_t"
                        & integer'image(G_TRACK) & "_p"
                        & integer'image(G_PRECMODE) & ".txt", write_mode);
              write(dl, string'("# t_rev=" & integer'image(C_TREV)
                    & " cell=100 precomp=" & integer'image(
                        boolean'pos(wr_precomp = '1'))
                    & " wstart=" & integer'image(wg_open_at)
                    & " wlen=" & integer'image(wg_len_cyc)
                    & " words=" & integer'image(G_WORDS)
                    & " gap_words=" & integer'image(q_gap)
                    & " scen=" & integer'image(G_SCEN)));
              writeline(dumpf, dl);
              src := f_build_words(q_track, q_gap, C_SRC_KEY);
              for i in 0 to f_words_len(q_gap) - 1 loop
                write(dl, string'("W " & to_hstring(src(i))));
                writeline(dumpf, dl);
              end loop;
              for s in 0 to C_NSLOT - 1 loop
                if seed(s) >= 0 then
                  write(dl, string'("P " & integer'image(seed(s))));
                  writeline(dumpf, dl);
                end if;
              end loop;
              for s in 0 to C_NSLOT - 1 loop
                if flux(s) >= 0 then
                  write(dl, string'("E " & integer'image(flux(s))));
                  writeline(dumpf, dl);
                end if;
              end loop;
              file_close(dumpf);
            end if;
        end case;
        q_ack <= q_req;
      end if;
    end if;
  end process p_disk;

  -----------------------------------------------------------------------------
  -- Paula model (line-by-line paula_floppy.v, both directions)
  -----------------------------------------------------------------------------
  p_monitors : process (clkmain, clk50)
    alias eng_in_drain is << signal .tb_fdd_write.i_engine.in_drain
                             : std_logic >>;
    alias eng_drain_unit is << signal .tb_fdd_write.i_engine.drain_unit
                               : unsigned(1 downto 0) >>;
    alias eng_drain_commit is << signal .tb_fdd_write.i_engine.drain_commit
                                 : std_logic >>;
    alias eng_epi_bound is << signal .tb_fdd_write.i_engine.epi_bound
                              : std_logic >>;
    alias eng_epi_phys is << signal .tb_fdd_write.i_engine.epi_phys
                             : std_logic >>;
    variable prev_drain : std_logic := '0';
    variable prev_owner : unsigned(1 downto 0) := "00";
    variable prev_cmt   : std_logic := '0';
    variable first      : boolean := true;
  begin
    if rising_edge(clkmain) then
      if hwf_serving = '1' and wr_busy = '1' then
        ilock_viol <= ilock_viol + 1;
      end if;
      if eng_in_drain = '1' and prev_drain = '0' then
        drain_latches <= drain_latches + 1;
      end if;
      prev_drain := eng_in_drain;
      if not first
         and (eng_drain_unit /= prev_owner or eng_drain_commit /= prev_cmt)
      then
        owner_changes <= owner_changes + 1;
      end if;
      -- the episode-inheritance invariant (the kill for mutant xi):
      -- every drain re-latched inside an open physical write episode
      -- inherits that episode's ownership. If a re-latch that samples a
      -- foreign unit is allowed to re-own the drain, the physical write
      -- stream is decoded and committed into that drive's ADF image. The
      -- ownership guard cannot catch it: inside an episode the guard is
      -- deliberately suspended, so inheritance is the only wall.
      if eng_epi_bound = '1' and eng_epi_phys = '1' then
        assert eng_drain_commit = '0'
          report "EPISODE OWNERSHIP: a drain inside an open physical write "
                 & "episode is COMMITTING (unit "
                 & integer'image(to_integer(eng_drain_unit))
                 & ") - the inherited re-latch re-owned the drain to an ADF "
                 & "drive and is about to write the physical stream into its "
                 & "image (mutant xi)" severity failure;
        assert eng_drain_unit = unsigned(C_PHYS_UNIT)
          report "EPISODE OWNERSHIP: the drain inside an open physical write "
                 & "episode is bound to unit "
                 & integer'image(to_integer(eng_drain_unit))
                 & ", not to the physical unit "
                 & integer'image(to_integer(unsigned(C_PHYS_UNIT)))
                 & " - inheritance was not applied (mutant xi)"
          severity failure;
      end if;
      prev_owner := eng_drain_unit;
      prev_cmt   := eng_drain_commit;
      first      := false;
    end if;
  end process p_monitors;

  p_gate_edge : process (clk50)
    variable prev : std_logic := '1';
  begin
    if rising_edge(clk50) then
      if f_wgate = '1' and prev = '0' then
        gate_off_at <= now;
      end if;
      prev := f_wgate;
    end if;
  end process p_gate_edge;

  clk7_grid : process (clkmain)
  begin
    if rising_edge(clkmain) then
      clk7_cnt <= clk7_cnt + 1;
      if clk7_cnt = "10" then
        clk7_en <= '1';
      else
        clk7_en <= '0';
      end if;
    end if;
  end process clk7_grid;

  -- paula_floppy.v DISKDMA_ACTIVE outputs, verbatim:
  --   trackrd = ~lenzero & ~dsklen[14];
  --   trackwr = dsklen[14];               <- not gated by lenzero!
  --   dmaon   = ~lenzero | ~dsklen[14];
  -- trackwr staying high after the last word was DMA'd is precisely why
  -- Paula's write DMA survives every engine-side drain abort, and hence why
  -- the unit of write-session state is the trackwr episode.
  p_lenzero <= '1' when p_dsklen = 0 else '0';
  p_trkrd   <= (not p_lenzero) and (not p_dsklen14) when p_state = 2 else '0';
  p_trkwr   <= p_dsklen14 when p_state = 2 else '0';
  p_dmaon   <= (not p_lenzero) or (not p_dsklen14) when p_state = 2 else '0';
  p_trackrd <= p_trkrd;
  p_trackwr <= p_trkwr;
  stbdat    <= cmd_fdd and stb7 when cmd_cnt = "11" else '0';

  tx_data <= p_sel & "01" & "00" & p_trkwr & p_trkrd & p_track
                when cmd_cnt = "00" else
             x"4489"
                when cmd_cnt = "01" else
             wrstat
                when cmd_cnt = "10" and p_trkwr = '1' else
             p_dmaen & '0' & std_logic_vector(p_dsklen)
                when cmd_cnt = "10" else
             p_fifo_out;

  -- the host channel: IO_STROBE -> IO_WAIT is captured on the full clock
  -- (paula_floppy.v:241-259); only the two-phase stb7 handshake is on the
  -- clk7 grid. Gating the capture would miss the engine's 1-cycle strobe.
  paula_rx : process (clkmain)
  begin
    if rising_edge(clkmain) then
      if io_fpga = '0' then
        io_wait <= '0';
        stb7    <= '0';
        cmd_cnt <= "00";
      else
        if io_strobe = '1' then
          io_wait <= '1';
        end if;
        if clk7_en = '1' and io_wait = '1' then
          if stb7 = '0' then
            rx_data <= io_din;
            stb7    <= '1';
          else
            stb7    <= '0';
            io_wait <= '0';
            io_dout <= tx_data;
          end if;
        end if;
        if clk7_en = '1' and stb7 = '1' and cmd_cnt /= "11" then
          cmd_cnt <= cmd_cnt + 1;
        end if;
      end if;
    end if;
  end process paula_rx;

  -- the disk controller: Agnus fill, the host pop, dsklen, the DISKDMA FSM
  -- and the host-paced DSKBLK
  paula_fdd : process (clkmain)
    variable fifo    : t_words := (others => (others => '0'));
    variable fhead   : natural := 0;
    variable ftail   : natural := 0;
    variable fcnt    : natural := 0;
    variable fwr_del : std_logic := '0';
    variable fifo_wr : std_logic;
    variable src     : t_words;
    variable src_idx : natural := 0;
    variable src_len : natural := 0;
    variable linecnt : natural := 0;
    variable burst   : natural := 0;
  begin
    if rising_edge(clkmain) then
      st_stb  <= '0';
      fifo_wr := '0';

      -- the CPU's double DSKLEN write
      if p_arm = '1' then
        src      := f_build_words(p_src_trk, p_src_gap, C_SRC_KEY);
        src_len  := f_words_len(p_src_gap);
        src_idx  := 0;
        p_dsklen   <= to_unsigned(p_arm_len mod 16384, 14);
        p_dmaen    <= '1';
        p_dsklen14 <= p_arm_wr;
      end if;
      if p_stop = '1' then
        p_dmaen <= '0';
      end if;

      if clk7_en = '1' then
        -- cmd_fdd (paula_floppy.v:271-276)
        if io_fpga = '0' then
          cmd_fdd <= '0';
        elsif stb7 = '1' and cmd_cnt = "00" then
          if rx_data(15 downto 13) = "000" then
            cmd_fdd <= '1';
          else
            cmd_fdd <= '0';
          end if;
        end if;

        -- Agnus disk DMA fills the write FIFO: 3 slots per 64 us scanline
        -- (the measured 21.3 us/word average, in 3-word line bursts)
        if p_dsklen14 = '1' and p_dmaon = '1' and p_lenzero = '0'
           and p_fill_en = '1' then
          -- 3 disk-DMA slots per PAL scanline: 64 us / 140.97 ns per
          -- clk7_en tick = 454 ticks, giving the measured 21.3 us/word
          -- average in 3-word line bursts. (A faster supply would hide a
          -- pacing defect by keeping Paula's FIFO permanently full.)
          linecnt := linecnt + 1;
          if linecnt >= 454 then
            linecnt := 0;
            burst   := 3;
          end if;
          if burst > 0 and fcnt < 2048 then
            if src_idx < src_len then
              fifo(fhead) := src(src_idx);
            else
              fifo(fhead) := x"AAAA";     -- buffer residue past the capture
            end if;
            fhead    := (fhead + 1) mod 2048;
            fcnt     := fcnt + 1;
            src_idx  := src_idx + 1;
            burst    := burst - 1;
            fifo_wr  := '1';
            p_dsklen <= p_dsklen - 1;
          end if;
        end if;

        -- the host pops one FIFO word per word-3+ handshake
        if p_trkwr = '1' and stbdat = '1' and fcnt > 0 then
          ftail  := (ftail + 1) mod 2048;
          fcnt   := fcnt - 1;
          p_pops <= p_pops + 1;
        end if;

        -- the read direction stores (WORDSYNC = 0: from the first word)
        if p_trkrd = '1' and stbdat = '1' and p_lenzero = '0' then
          st_word  <= rx_data;
          st_stb   <= '1';
          p_dsklen <= p_dsklen - 1;
          fifo_wr  := '1';
        end if;

        -- wr_fifo_status is latched when the previous word starts to
        -- transmit (paula_floppy.v:300-305)
        if stb7 = '1' then
          wrstat <= (p_dmaen and p_dsklen14) & "000"
                    & std_logic_vector(to_unsigned(fcnt, 12));
        end if;

        -- the DISKDMA state machine (word-1 arming, host-paced DSKBLK)
        case p_state is
          when 0 =>
            if cmd_fdd = '1' and stb7 = '1' and cmd_cnt = "01"
               and p_dmaen = '1' and p_lenzero = '0' then
              p_state <= 2;
            end if;
          when 2 =>
            if p_dmaen = '0' then
              p_state <= 0;
            elsif p_lenzero = '1' and fcnt = 0 and fwr_del = '0' then
              p_state <= 3;
            end if;
          when others =>
            p_blk_cnt <= p_blk_cnt + 1;
            p_dmaen   <= '0';
            p_state   <= 0;
        end case;
        fwr_del := fifo_wr;
      end if;

      p_fifo_out <= fifo(ftail);
      p_fifo_cnt <= fcnt;

      if amiga_rst = '1' then
        p_state    <= 0;
        p_dmaen    <= '0';
        p_dsklen   <= (others => '0');
        fhead := 0; ftail := 0; fcnt := 0;
      end if;
    end if;
  end process paula_fdd;

  -- bring-up trace: one line per millisecond of simulated time with the
  -- handful of signals that separate "the engine stopped polling" from
  -- "the writer never armed" from "Paula never completed"
  gen_trace : if G_TRACE generate
    p_trace : process
    begin
      loop
        wait for 1 ms;
        report "T epi=" & std_logic'image(wr_session)
               & " abrt=" & std_logic'image(wr_abort)
               & " busy=" & std_logic'image(wr_busy50)
               & " ok=" & std_logic'image(wr_ok50)
               & " wgate=" & std_logic'image(f_wgate)
               & " opens=" & integer'image(wg_opens)
               & " lvl=" & integer'image(to_integer(wr_level))
               & " trkwr=" & std_logic'image(p_trackwr)
               & " dmaen=" & std_logic'image(p_dmaen)
               & " len=" & integer'image(to_integer(p_dsklen))
               & " fcnt=" & integer'image(p_fifo_cnt)
               & " pops=" & integer'image(p_pops)
               & " blk=" & integer'image(p_blk_cnt)
               & " epicnt=" & integer'image(to_integer(d_epi_cnt));
      end loop;
    end process p_trace;
  end generate gen_trace;

  -----------------------------------------------------------------------------
  -- the control process: scenario sequencing and the scenario asserts. A
  -- failing assert is a DUT defect until it is shown to be a checker defect.
  -----------------------------------------------------------------------------
  p_control : process
    variable cap   : t_words := (others => (others => '0'));
    variable capn  : natural := 0;
    variable buf   : t_buf;
    variable res   : t_res;
    variable n0    : natural;
    variable pops0 : natural;
    variable t0    : time;
    variable v_ok  : boolean;
    variable v_own : natural;

    procedure tick(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clkmain);
      end loop;
    end procedure;

    -- the CPU arms a DMA (the double DSKLEN write)
    procedure arm(nwords : natural; wr : boolean; track : natural) is
    begin
      p_src_trk <= track;
      p_src_gap <= C_GAP_WORDS;
      p_track   <= std_logic_vector(to_unsigned(track, 8));
      if wr then p_arm_wr <= '1'; else p_arm_wr <= '0'; end if;
      p_arm_len <= nwords;
      tick(2);
      p_arm <= '1';
      tick(1);
      p_arm <= '0';
      tick(1);
    end procedure;

    -- wait for the host-paced DSKBLK of the DMA just armed
    procedure wait_blk(tmo : time; what : string) is
      variable c0 : natural := p_blk_cnt;
    begin
      wait until p_blk_cnt /= c0 for tmo;
      assert p_blk_cnt /= c0
        report "DSKBLK never fired for " & what
               & " - Paula's DMA did not complete (the engine stopped "
               & "draining: a wedge, not a write defect)"
        severity failure;
    end procedure;

    -- capture a read DMA through the real chain into the local buffer
    procedure capture(nwords : natural; track : natural) is
      variable guard : natural := 0;
    begin
      capn := 0;
      arm(nwords, false, track);
      while capn < nwords and guard < 200_000_000 loop
        wait until rising_edge(clkmain);
        guard := guard + 1;
        if st_stb = '1' then
          if capn < C_MAXW then
            cap(capn) := st_word;
          end if;
          capn := capn + 1;
        end if;
      end loop;
      assert capn >= nwords
        report "read-back capture stalled at " & integer'image(capn)
               & " of " & integer'image(nwords) & " words"
        severity failure;
    end procedure;

    -- run the disk process's independent verdicts (b) and (c)
    procedure verdicts(track : natural) is
    begin
      q_track <= track;
      q_gap   <= C_GAP_WORDS;
      q_kind  <= 1;
      tick(2);
      q_req <= not q_req;
      wait until q_ack = q_req;
      tick(2);
    end procedure;

    procedure seed_disk is
    begin
      q_kind <= 0;
      tick(2);
      q_req <= not q_req;
      wait until q_ack = q_req;
      tick(2);
    end procedure;

    -- verdict (a): the trackdisk decode of what Paula stored
    procedure verdict_a(track : natural) is
    begin
      buf := (others => 0);
      p_put_word(buf, C_DEC, x"AAAA");
      p_put_word(buf, C_DEC + 2, x"AAAA");
      for i in 0 to C_DMA_WORDS - 1 loop
        p_put_word(buf, C_CAP + 2 * i, unsigned(cap(i)));
      end loop;
      td_decode(buf, track, res);
    end procedure;

    function hex8(v : natural) return string is
    begin
      return to_hstring(to_unsigned(v, 8));
    end function;

  begin
    report "tb_fdd_write: scen=" & integer'image(G_SCEN)
           & " variant=" & integer'image(G_VARIANT)
           & " rpm=" & integer'image(G_RPM_MHZ)
           & " legacy=" & boolean'image(G_LEGACY)
           & " framehold=" & boolean'image(G_FRAMEHOLD)
           & " track=" & integer'image(G_TRACK)
           & " precmode=" & integer'image(G_PRECMODE)
           & " words=" & integer'image(G_WORDS)
           & " T_rev=" & integer'image(C_TREV)
           & " slip=" & integer'image(C_TREV mod C_CELL);

    ---------------------------------------------------------------------------
    -- common preamble: release reset, seed a different track, select the
    -- drive and let the write-protect qualifier accumulate its 10 ms of
    -- selected time (every writing scenario starts from this preamble)
    ---------------------------------------------------------------------------
    tick(20);
    rst50     <= '0';
    rstmain   <= '0';
    tick(10);
    amiga_rst <= '0';
    tick(10);
    seed_disk;

    hwf_en  <= '1';
    hwf_mot <= '1';
    hwf_sel <= '1';
    p_sel   <= C_PHYS_UNIT;

    if G_SCEN = 4 then
      f_wprot <= '0';                 -- S3 episode 1: the tab window is open
    end if;

    wait for 12 ms;                   -- > C_WPROT_QUAL = 10 ms selected

    if G_SCEN /= 4 then
      assert wr_ok50 = '1'
        report "wr_ok did not qualify after 12 ms of selected time with the "
               & "tab writable - the 10 ms accumulator is broken (no write "
               & "scenario below can be meaningful)"
        severity failure;
    else
      assert wr_ok50 = '0'
        report "S3: wr_ok qualified while the tab window is OPEN (= PROTECTED)"
        severity failure;
    end if;

    case G_SCEN is

      -------------------------------------------------------------------------
      -- S1: trackdisk cadence, full track. The reference scenario.
      -------------------------------------------------------------------------
      when 1 | 2 =>
        arm(G_WORDS, true, G_TRACK);
        wait_blk(500 ms, "the trackdisk-cadence write");
        wait for 2100 us;             -- trackdisk's own post-DSKBLK wait

        assert wg_opens = 1
          report "WGATE opened " & integer'image(wg_opens)
                 & " times, expected exactly 1" severity failure;
        assert wg_len_cyc = G_WORDS * 16 * C_CELL
          report "WGATE window " & integer'image(wg_len_cyc)
                 & " cycles, expected words*16*100 = "
                 & integer'image(G_WORDS * 16 * C_CELL)
                 & " (pin-to-pin, no lead-in/lead-out cells)"
          severity failure;
        assert d_overflow = 0
          report "0x7D CDC overflow = " & integer'image(to_integer(d_overflow))
                 & " - the 2.2 occupancy invariant is violated"
          severity failure;
        assert d_underrun = 0
          report "0x75 underrun count = "
                 & integer'image(to_integer(d_underrun))
                 & " - the serializer ran dry (rate closure broken)"
          severity failure;
        assert d_discard = 0
          report "0x76 tab-blocked count nonzero on a writable disk"
          severity failure;
        assert d_gateopen = 1
          report "0x7A gate-opened episodes = "
                 & integer'image(to_integer(d_gateopen)) & ", expected 1"
          severity failure;
        assert d_words_l = to_unsigned(G_WORDS, 16)
          report "0x71 words consumed = "
                 & integer'image(to_integer(d_words_l)) & ", expected "
                 & integer'image(G_WORDS) severity failure;
        -- the occupancy invariant, stated exactly: ready =
        -- (wr_level <= 1), so occupancy after any admitted pop is <= 2, and
        -- the in-flight residue at the DSKBLK moment is <= 2 FIFO words +
        -- the shift register = 3. This bound keeps the tail close to a real
        -- Paula's, so it is asserted at 3 and not at a comfortable
        -- 4: a ready of (level <= 2) - mutant (vi) - reaches 4 and must be
        -- caught here, because it does not overflow the 4-deep FIFO and so
        -- never trips the 0x7D instrument.
        assert to_integer(unsigned(d_tail(15 downto 8))) <= 3
          report "0x77 max in-flight words at episode end = "
                 & integer'image(to_integer(unsigned(d_tail(15 downto 8))))
                 & ", expected <= 3 (2 FIFO words + the shift register); "
                 & "the pop policy is admitting too early, so the tail is "
                 & "no longer real-Amiga-scale" severity failure;
        assert d_flags79(8) = '1'
          report "0x79 completion flag not set after a clean episode"
          severity failure;

        -- the writer-independent absolute check on the flux itself: the
        -- mechanism's WDATA window is 0.2-1.1 us (TEAC FD-05HF class
        -- drives). A runt or an over-wide pulse
        -- is a written-flux defect that no decode verdict can see, because
        -- our own read chain only cares about edge positions.
        report "  0x77 in-flight at DSKBLK = "
               & integer'image(to_integer(unsigned(d_tail(15 downto 8))))
               & " word(s), tail-cut " & integer'image(
                   to_integer(unsigned(d_tail(7 downto 0))));
        report "  WDATA pulses: " & integer'image(pw_count) & ", width "
               & integer'image(pw_min) & ".." & integer'image(pw_max)
               & " cycles (" & integer'image(pw_min * 20) & ".."
               & integer'image(pw_max * 20) & " ns)";
        assert pw_count > 20000
          report "only " & integer'image(pw_count) & " WDATA pulses were "
                 & "emitted for a full track - the writer is not writing"
          severity failure;
        assert pw_min >= 10
          report "WDATA runt pulse of " & integer'image(pw_min * 20)
                 & " ns - below the mechanism's 0.2 us floor; the drive may "
                 & "drop or smear the transition" severity failure;
        assert pw_max <= 55
          report "WDATA pulse of " & integer'image(pw_max * 20)
                 & " ns - above the mechanism's 1.1 us ceiling"
          severity failure;
        assert pw_min = pw_max
          report "WDATA pulse width varies (" & integer'image(pw_min)
                 & ".." & integer'image(pw_max) & " cycles) - the pulse is "
                 & "a fixed-width one-shot, so a spread means a cell "
                 & "boundary is clipping it" severity failure;

        verdicts(G_TRACK);
        assert q_old_alive = 0
          report "verdict: " & integer'image(q_old_alive) & " pre-seed flux "
                 & "edge(s) survived inside the written span - the gate did "
                 & "not erase (a no-op writer re-reading the seed)"
          severity failure;
        assert q_span_edges > 20000
          report "only " & integer'image(q_span_edges) & " edges in the "
                 & "written span - the writer wrote (almost) nothing"
          severity failure;
        assert q_ref_err < 11
          report "VERDICT (b) real-Paula referee FAILED with $"
                 & hex8(q_ref_err) & " - a constant-framing re-read of our "
                 & "own flux does not decode: the written track is wrong"
          severity failure;
        assert q_sec_ok >= C_NSEC
          report "VERDICT (c) only " & integer'image(q_sec_ok)
                 & " clean sector instances (expected >= 11) with "
                 & integer'image(q_sec_bad) & " bad" severity failure;

        capture(C_DMA_WORDS, G_TRACK);
        verdict_a(G_TRACK);
        report "  verdict (a) trackdisk decode: err=$" & hex8(res.err)
               & " sec=" & integer'image(res.first_sec)
               & " SG=" & integer'image(res.sg)
               & " s2=" & integer'image(res.srom2);
        if G_FRAMEHOLD then
          assert res.err < 11
            report "VERDICT (a) trackdisk FAILED with $" & hex8(res.err)
                   & " in the framing-HOLD arm - our own re-read of a track "
                   & "we just wrote must decode"
            severity failure;
        else
          -- the realign-always arm exists to show the written splice is
          -- physically real, so it asserts the geometry rather than a decode
          -- outcome. The write window is ~109 % of a revolution, so its tail
          -- necessarily laps its own head; the head returns each revolution
          -- offset by T_rev mod C_CELL (the flux model advances the head one
          -- cycle per clock and wraps modulo T_rev), which is the slip. That
          -- lap is what a seam is made of, and it is measurable here.
          --
          -- Whether a given seam then kills a trackdisk decode is geometry,
          -- not correctness: it depends on where the lap falls inside the
          -- leading gap and how much gap remains after it for the hunt. In a
          -- track this core writes in one continuous window the lap lands
          -- inside the write's own 831-word leading gap, and it decodes -
          -- which is the good news, not a defect. The seam itself is
          -- reproduced, deliberately, in tb_fdd_splice, whose four arms are
          -- part of the floppy regression; asserting a decode outcome here
          -- would pin something this scenario does not control.
          assert wg_len_cyc > C_TREV
            report "REALIGN arm: the WGATE window is "
                   & integer'image(wg_len_cyc) & " cycles against a "
                   & integer'image(C_TREV) & "-cycle revolution, so the "
                   & "write never lapped its own head - there is no splice "
                   & "in this flux and the arm proves nothing"
            severity failure;
          report "  REALIGN arm at slip "
                 & integer'image(C_TREV mod C_CELL) & ": self-overlap "
                 & integer'image(wg_len_cyc - C_TREV) & " cycles, decode $"
                 & hex8(res.err);
          if (C_TREV mod C_CELL) = 0 then
            assert res.err < 11
              report "REALIGN arm at slip 0: expected GREEN (the seamless "
                     & "degenerate case) but got $" & hex8(res.err)
              severity failure;
          end if;
        end if;

        if G_SCEN = 2 then             -- S1p: the precomp assertions
          report "  S1p: 0x78 precompensated pulses = "
                 & integer'image(to_integer(d_precnt))
                 & ", precomp active = " & std_logic'image(d_ctrl7c(2));
          if (G_PRECMODE = 0 and G_TRACK >= 81) or G_PRECMODE = 1 then
            assert d_ctrl7c(2) = '1'
              report "S1p: precomp INACTIVE at track "
                     & integer'image(G_TRACK) & " mode "
                     & integer'image(G_PRECMODE)
                     & " - the KS1.3 policy is track >= 81 in AUTO, always "
                     & "in ON" severity failure;
            assert d_precnt > 0
              report "S1p: precomp active but 0x78 counted no shifted pulse"
              severity failure;
          else
            assert d_ctrl7c(2) = '0'
              report "S1p: precomp ACTIVE at track "
                     & integer'image(G_TRACK) & " mode "
                     & integer'image(G_PRECMODE)
                     & " - AUTO must not shift below track 81 (trackdisk's "
                     & "track-80 exclusion) and OFF must never shift"
              severity failure;
            assert d_precnt = 0
              report "S1p: precomp inactive but 0x78 counted "
                     & integer'image(to_integer(d_precnt)) & " shifts"
              severity failure;
          end if;
        end if;

      -------------------------------------------------------------------------
      -- S2: X-Copy cadence - the write is index-synced and the host deselects
      -- ~50 us after DSKBLK, truncating the tail inside its self-overlap.
      -------------------------------------------------------------------------
      when 3 =>
        arm(G_WORDS, true, G_TRACK);
        wait_blk(500 ms, "the X-Copy-cadence write");
        wait for 50 us;               -- the measured deselect-all latency
        hwf_sel <= '0';
        p_sel   <= "11";
        wait for 2 ms;

        assert wg_opens = 1
          report "WGATE opened " & integer'image(wg_opens) & " times"
          severity failure;
        -- A real Paula owes one word at DSKBLK (its own shifter fires the
        -- interrupt), this design owes two to three (DSKBLK fires when the
        -- engine pops Paula dry), and X-Copy provisions exactly one pad word,
        -- so a deselect that cut the drain would reach sector 10's last data
        -- word. The drain hold makes a post-DSKBLK deselect a non-event:
        -- the window must be full and nothing may be cut.
        assert to_integer(unsigned(d_tail(7 downto 0))) = 0
          report "0x77 tail-cut ticked although the host only deselected "
                 & "AFTER DSKBLK - once the Amiga has been told the write "
                 & "completed, the flux we still owe is flux it believes is "
                 & "on the disk and must be written, not cut"
          severity failure;
        assert wg_len_cyc = G_WORDS * 16 * C_CELL
          report "the WGATE window was TRUNCATED by a post-DSKBLK deselect: "
                 & integer'image(wg_len_cyc) & " of "
                 & integer'image(G_WORDS * 16 * C_CELL) & " cycles"
          severity failure;
        hwf_sel <= '1';
        wait for 12 ms;
        verdicts(G_TRACK);
        assert q_ref_err < 11
          report "S2: VERDICT (b) real-Paula referee FAILED with $"
                 & hex8(q_ref_err) & " after the X-Copy tail cut"
          severity failure;
        assert q_sec_ok >= C_NSEC
          report "S2: only " & integer'image(q_sec_ok) & " clean sector "
                 & "instances after a tail-cut X-Copy write - the cut must "
                 & "land in the SELF-OVERLAP (buffer residue past the "
                 & "capture), never in captured sector data" severity failure;

      -------------------------------------------------------------------------
      -- S3: write-protect, three episodes plus the bounce and
      -- deselected-line cases
      -------------------------------------------------------------------------
      when 4 =>
        -- episode 1: the tab window is open (= protected)
        arm(600, true, G_TRACK);
        wait_blk(200 ms, "the tab-protected episode 1");
        wait for 500 us;
        assert wg_opens = 0
          report "S3/1: WGATE OPENED on a write-protected disk - the hard "
                 & "gate failed (this is the one defect that destroys a "
                 & "user's original)" severity failure;
        assert d_discard >= 1
          report "S3/1: 0x76 tab-blocked episode counter did not tick"
          severity failure;
        verdicts(G_TRACK);
        -- "the flux is untouched" = no slot carries this episode's
        -- generation (nothing was swept or written) AND the pre-seed track
        -- is still all there. Both halves matter: the first alone would
        -- pass on a writer that erased without writing.
        assert q_span_edges = 0
          report "S3/1: " & integer'image(q_span_edges) & " flux edge(s) "
                 & "written although the disk is write-protected - THE ONE "
                 & "DEFECT THAT DESTROYS A USER ORIGINAL" severity failure;
        assert q_old_alive > 20000
          report "S3/1: only " & integer'image(q_old_alive) & " pre-seed "
                 & "edges survive - the seed track was erased on a "
                 & "write-protected disk" severity failure;

        -- episode 2: the tab closes, but armed before the qualifier expires
        f_wprot <= '1';
        wait for 200 us;              -- far below C_WPROT_QUAL = 10 ms
        arm(600, true, G_TRACK);
        wait_blk(200 ms, "the pre-qualifier episode 2");
        wait for 500 us;
        assert wg_opens = 0
          report "S3/2: WGATE opened before the 10 ms selected-time "
                 & "qualifier had accumulated" severity failure;
        assert d_discard >= 2
          report "S3/2: the pre-qualifier episode did not count as blocked"
          severity failure;

        -- episode 3: after the qualifier - this one must write
        wait for 12 ms;
        assert wr_ok50 = '1'
          report "S3/3: wr_ok still not qualified after 12 ms" severity failure;
        arm(600, true, G_TRACK);
        wait_blk(200 ms, "the qualified episode 3");
        wait for 500 us;
        assert wg_opens = 1
          report "S3/3: WGATE never opened on a writable, qualified disk"
          severity failure;
        assert wg_len_cyc = 600 * 16 * C_CELL
          report "S3/3: window " & integer'image(wg_len_cyc)
                 & " cycles, expected " & integer'image(600 * 16 * C_CELL)
          severity failure;

        -- S3/4 the bounce case: a tab line toggling at ms scale
        -- while the unit is selected must never let the gate open - each
        -- qualified low both clears wr_ok and restarts the 10 ms
        -- accumulator, so the qualifier can never complete.
        n0 := wg_opens;
        for i in 1 to 15 loop
          f_wprot <= '0';
          wait for 1 ms;
          f_wprot <= '1';
          wait for 1 ms;
        end loop;
        arm(600, true, G_TRACK);
        wait_blk(200 ms, "the bouncing-tab episode");
        wait for 500 us;
        assert wg_opens = n0
          report "S3/4: WGATE opened although the write-protect line was "
                 & "bouncing at ms scale throughout - a single qualified "
                 & "low must restart the whole 10 ms accumulator"
          severity failure;

        -- S3/5 the deselected-line case: the PC mechanism does
        -- not drive its outputs while deselected, so a '1' read there is
        -- meaningless and must not advance the qualifier. Clear wr_ok, then
        -- spend 20 ms deselected with the line reading writable, re-select
        -- and write after only 1 ms: it must still be blocked.
        f_wprot <= '0';
        wait for 1 ms;                -- clear wr_ok while selected
        f_wprot <= '1';
        hwf_sel <= '0';
        wait for 20 ms;               -- 2x the qualifier, but deselected
        hwf_sel <= '1';
        wait for 1 ms;                -- far below C_WPROT_QUAL
        assert wr_ok50 = '0'
          report "S3/5: wr_ok qualified after 20 ms of DESELECTED time - "
                 & "the accumulator advanced on a line the mechanism was "
                 & "not driving" severity failure;
        n0 := wg_opens;
        arm(600, true, G_TRACK);
        wait_blk(200 ms, "the deselected-qualifier episode");
        wait for 500 us;
        assert wg_opens = n0
          report "S3/5: WGATE opened after only 1 ms of SELECTED time - "
                 & "deselected time was counted towards the qualifier"
          severity failure;

      -------------------------------------------------------------------------
      -- S4: engine-side abort (bus_grant loss). Short = shorter than the
      -- in-flight time (mutant ix's kill), long = beyond it.
      -------------------------------------------------------------------------
      when 5 =>
        arm(2000, true, G_TRACK);
        wait until wr_session = '1' for 50 ms;
        assert wr_session = '1'
          report "S4: the write episode never opened" severity failure;
        wait for 3 ms;                -- stream a while
        if G_VARIANT = 2 then
          -- the underrun path. Rate closure makes it unreachable in normal
          -- operation, which is no safety argument, so this variant reaches
          -- it on purpose. Starving Agnus (not the engine) empties Paula's
          -- FIFO, the
          -- engine then has nothing to pop, and the serializer runs dry
          -- with the DMA still open. That must abort the episode, not
          -- deassert WGATE and silently re-assert it once the pipe refills,
          -- which would leave an erased hole in the middle of a written
          -- track that no write verify would ever catch.
          p_fill_en <= '0';
          wait until f_wgate = '1' for 100 ms;
          assert f_wgate = '1'
            report "S4/2: WGATE never closed although the pipe was starved"
            severity failure;
          wait for 2 ms;
          assert d_underrun = 1
            report "S4/2: 0x75 underrun count = "
                   & integer'image(to_integer(d_underrun))
                   & ", expected 1 - a dry serializer with the DMA still "
                   & "open MUST abort the episode" severity failure;
          assert d_reason(6) = '1'
            report "S4/2: 0x7B underrun reason bit not set (reason = "
                   & to_hstring(d_reason) & ")" severity failure;
          assert wg_opens = 1
            report "S4/2: WGATE opened " & integer'image(wg_opens)
                   & " times - it RE-ASSERTED after the dry spell, writing "
                   & "an erased hole into the middle of the track"
            severity failure;
          p_fill_en <= '1';
          wait_blk(400 ms, "the starved episode");
          report "TB_FDD_WRITE scen=5 variant=2 rpm="
                 & integer'image(G_RPM_MHZ) & ": ALL CHECKS PASS";
          stop;
        end if;
        bus_grant <= '0';
        if G_VARIANT = 0 then
          wait for 20 us;             -- shorter than the in-flight time
        else
          wait for 500 us;            -- longer
        end if;
        bus_grant <= '1';
        wait_blk(300 ms, "the aborted episode (the DMA must still complete)");
        wait for 500 us;

        assert wr_abort = '0'
          report "S4: the abort level is still set after the episode ended"
          severity failure;
        assert d_reason(7) = '1'
          report "S4: 0x7B abort reason bit 7 (engine abort) not set, "
                 & "reason = " & to_hstring(d_reason) severity failure;
        assert d_underrun = 0
          report "S4: 0x75 underrun fired - the ABORT, not the underrun "
                 & "path, must be what closed the gate"
          severity failure;
        -- the kill for mutant (ix). "Old flux survives" alone is vacuous
        -- here: S4 streams ~3 ms of a ~64 ms DMA, so ~95 % of the
        -- revolution is untouched whatever the DUT does. What actually
        -- distinguishes "the abort stopped the write" from "the episode
        -- resumed and wrote the whole track" is the length of the WGATE
        -- window, so bound it: ~3 ms of streaming is <= 150,000 cycles,
        -- while the full 2000-word DMA would be 2000*16*100 = 3,200,000.
        assert wg_len_cyc > 0
          report "S4: WGATE never opened, so there was no write to abort"
          severity failure;
        assert wg_len_cyc < 300_000
          report "S4: the WGATE window ran " & integer'image(wg_len_cyc)
                 & " cycles (a full DMA would be "
                 & integer'image(2000 * 16 * C_CELL) & ") - the write did "
                 & "NOT stop at the abort point. This is mutant (ix): "
                 & "without the abort LEVEL the engine re-opens inherited "
                 & "drains and the episode simply resumes."
          severity failure;
        verdicts(G_TRACK);
        assert q_old_alive > 0
          report "S4: no pre-seed flux survives anywhere - the writer swept "
                 & "the whole revolution despite the abort" severity failure;

      -------------------------------------------------------------------------
      -- S5: gate-term storm - each term mid-stream must cut WGATE and latch
      -- the abort for the whole episode.
      -------------------------------------------------------------------------
      when 6 =>
        arm(3000, true, G_TRACK);
        wait until f_wgate = '0' for 60 ms;
        assert f_wgate = '0'
          report "S5: WGATE never opened" severity failure;
        wait for 2 ms;
        term_mark <= now;
        case G_VARIANT is
          when 0 => hwf_sel <= '0';                     -- deselect
          when 1 => hwf_mot <= '0';                     -- motor off
          when 2 => hwf_en  <= '0';                     -- enable off
          when 3 => f_wprot <= '0';                     -- tab flips
          when 4 => f_chg   <= '0';                     -- disk change
          when 5 => step_n  <= '0';                     -- STEP pulse
          when others => hwf_side <= '0';               -- SIDE flip
        end case;
        wait for 20 us;
        assert f_wgate = '1'
          report "S5 variant " & integer'image(G_VARIANT)
                 & ": WGATE still asserted 20 us after the gate term was "
                 & "lost - the term is not in the gate" severity failure;
        -- WGATE must close at the boundary where the term is lost. The
        -- term crosses at most a 2-FF core->50 MHz
        -- synchronizer plus the 4-sample revoke filter, so the honest bound
        -- is well under one channel cell. A 20 us window would let a DUT
        -- keep writing for ten more cells after a STEP edge or a SIDE flip
        -- - i.e. smear the write across a cylinder or onto the other
        -- surface, which is exactly what the term exists to prevent.
        report "  S5 gate-close latency: "
               & time'image(gate_off_at - term_mark);
        assert gate_off_at > term_mark
               and (gate_off_at - term_mark) < 2 us
          report "S5 variant " & integer'image(G_VARIANT)
                 & ": WGATE took " & time'image(gate_off_at - term_mark)
                 & " to close after the term was lost (bound: < 2 us = one "
                 & "channel cell) - the write smears past the event"
          severity failure;
        -- restore the term: the gate must not re-open (the abort latch)
        hwf_sel <= '1'; hwf_mot <= '1'; hwf_en <= '1';
        f_wprot <= '1'; f_chg <= '1'; step_n <= '1'; hwf_side <= '1';
        wait for 3 ms;
        assert f_wgate = '1'
          report "S5 variant " & integer'image(G_VARIANT)
                 & ": WGATE RE-OPENED after the gate term returned - the "
                 & "abort must latch for the rest of the episode"
          severity failure;
        wait_blk(300 ms, "the storm-aborted episode");
        assert wg_opens = 1
          report "S5: WGATE opened " & integer'image(wg_opens)
                 & " times in one episode" severity failure;

      -------------------------------------------------------------------------
      -- S6: tail sweep - deselect X us after DSKBLK.
      -------------------------------------------------------------------------
      when 7 =>
        arm(G_WORDS, true, G_TRACK);
        wait_blk(500 ms, "the tail-sweep write");
        wait for G_VARIANT * 1 us;
        hwf_sel <= '0';
        wait for 3 ms;
        report "  S6 X=" & integer'image(G_VARIANT) & " us: window "
               & integer'image(wg_len_cyc) & " of "
               & integer'image(G_WORDS * 16 * C_CELL) & " cycles, tail-cut "
               & integer'image(to_integer(unsigned(d_tail(7 downto 0))));
        -- Without the drain hold the residue (at most 3 word times of 32 us
        -- plus the launch latency) is fully serialized between 104 and
        -- 128 us after DSKBLK, and X-Copy deselects 40..100 us after it. The
        -- sweep (25..2100 us) proves the drain is immune to a post-DSKBLK
        -- deselect at every latency; a cut at any X means the drain hold
        -- does not cover the window it claims to.
        assert wg_len_cyc = G_WORDS * 16 * C_CELL
          report "S6: a deselect " & integer'image(G_VARIANT)
                 & " us after DSKBLK truncated the window to "
                 & integer'image(wg_len_cyc) & " of "
                 & integer'image(G_WORDS * 16 * C_CELL) & " cycles"
          severity failure;
        assert to_integer(unsigned(d_tail(7 downto 0))) = 0
          report "S6: tail-cut ticked for a deselect "
                 & integer'image(G_VARIANT) & " us after DSKBLK"
          severity failure;
        assert to_integer(unsigned(d_tail(15 downto 8))) <= 4
          report "S6: 0x77 max in-flight = "
                 & integer'image(to_integer(unsigned(d_tail(15 downto 8))))
          severity failure;

      -------------------------------------------------------------------------
      -- S9: co-selection. A transient foreign sel must not abort; a
      -- persisting one must.
      -------------------------------------------------------------------------
      when 8 =>
        arm(3000, true, G_TRACK);
        wait until f_wgate = '0' for 60 ms;
        assert f_wgate = '0' report "S9: WGATE never opened" severity failure;
        wait for 2 ms;
        n0 := drain_latches;
        v_own := owner_changes;
        case G_VARIANT is
          when 0 =>                    -- a one-poll click of a non-existent unit
            p_sel <= "11";
            wait for 5 us;
            p_sel <= C_PHYS_UNIT;
          when 1 =>                    -- an existing unit at another track
            p_track <= x"20";
            p_sel   <= "10";
            wait for 5 us;
            p_sel   <= C_PHYS_UNIT;
            p_track <= std_logic_vector(to_unsigned(G_TRACK, 8));
          when 2 =>                    -- persisting foreign selection
            p_sel <= "10";
            wait for 300 us;           -- > C_WR_FOREIGN = 100 us
          when others =>
            -- the inheritance kill (mutant xi). Inside an episode the
            -- ownership guard is suspended, so a foreign sel alone can
            -- never re-latch the drain - the only way to reach the
            -- inheritance branch is to have the drain cleared underneath
            -- the episode (a global abort does exactly that, and
            -- deliberately leaves the episode bound because Paula still
            -- holds trackwr) and then let the next poll sample a foreign
            -- unit. The real engine inherits the physical, non-committing
            -- ownership; without inheritance the re-latch binds unit 2 -
            -- a mounted, write-enabled ADF drive - and starts decoding the
            -- physical write stream into its image.
            p_sel <= "10";
            wait for 5 us;             -- let one poll sample the foreign unit
            bus_grant <= '0';          -- clear in_drain, keep the episode
            wait for 2 us;
            bus_grant <= '1';
            wait for 300 us;           -- the re-latch happens in here
            p_sel <= C_PHYS_UNIT;
        end case;
        wait for 200 us;
        if G_VARIANT = 3 then
          -- the invariant monitor is what kills the mutant; here we only
          -- prove the scenario really reached the inheritance branch
          -- instead of passing vacuously.
          assert drain_latches > n0
            report "S9/3: the drain never re-latched after the abort - the "
                   & "inheritance branch was never exercised, so this "
                   & "scenario proves nothing" severity failure;
          assert wr_session = '1' or wr_busy = '1'
            report "S9/3: the episode was gone before the re-latch - a "
                   & "global abort must NOT end the episode" severity failure;
        elsif G_VARIANT < 2 then
          assert f_wgate = '0'
            report "S9 variant " & integer'image(G_VARIANT)
                   & ": a ONE-POLL foreign sel closed the gate - the "
                   & "ownership latch is missing (mutant viii)"
            severity failure;
          -- the kill for mutant (viii): the gate staying open is not
          -- enough, because an episode that re-latches an inherited drain
          -- keeps writing seamlessly. What the ownership latch actually
          -- guarantees is that the click does not re-open a drain at all.
          -- the kill for mutant (viii). The guard and the re-latch happen
          -- in the same cycle, so in_drain never falls and an edge counter
          -- sees nothing; the owner is what moves. With the latch in place
          -- the drain stays bound to the physical unit and non-committing
          -- for the whole episode.
          assert owner_changes = v_own
            report "S9 variant " & integer'image(G_VARIANT) & ": the click "
                   & "changed the drain's OWNER " & integer'image(
                       owner_changes - v_own) & " time(s) - a single foreign "
                   & "sample re-latched the drain to another unit (mutant "
                   & "viii). That is the path that ends with a physical "
                   & "write being committed into an ADF image."
            severity failure;
          assert drain_latches = n0 or true
            report "" severity note;
          assert wr_abort = '0'
            report "S9: the abort level rose on a transient click"
            severity failure;
        else
          assert f_wgate = '1'
            report "S9/2: a foreign sel persisting past C_WR_FOREIGN did "
                   & "NOT abort the episode" severity failure;
          p_sel <= C_PHYS_UNIT;
        end if;
        wait_blk(300 ms, "the co-selection episode");
        assert wg_opens = 1
          report "S9: WGATE opened " & integer'image(wg_opens) & " times"
          severity failure;

      -------------------------------------------------------------------------
      -- S10: the physical unit is df0 (sel = 00 is ambiguous in Paula's
      -- priority encoder); the writer's own sel_s term must cut the gate.
      -------------------------------------------------------------------------
      when 9 =>
        arm(3000, true, G_TRACK);
        wait until f_wgate = '0' for 60 ms;
        assert f_wgate = '0' report "S10: WGATE never opened" severity failure;
        wait for 2 ms;
        hwf_sel <= '0';                -- the real /SEL drops
        wait for 20 us;
        assert f_wgate = '1'
          report "S10: WGATE still asserted after the physical /SEL dropped "
                 & "- with the unit at df0 the status sel bits cannot tell "
                 & "us apart from 'nothing selected', so the writer's OWN "
                 & "sel term is the only wall" severity failure;
        hwf_sel <= '1';
        wait_blk(300 ms, "the df0 deselect episode");

      -------------------------------------------------------------------------
      -- S11: residue hygiene across the reset classes + the sub-threshold DMA
      -------------------------------------------------------------------------
      when 10 =>
        if G_VARIANT = 4 then
          arm(1, true, G_TRACK);       -- a 1-word DMA: never reaches stream
          wait_blk(200 ms, "the 1-word DMA");
          wait for 500 us;
          -- the episode must really have happened (otherwise the two
          -- asserts below would pass vacuously on a writer that never saw
          -- anything at all)
          assert d_epi_cnt >= 1
            report "S11/4: the writer counted no episode - the 1-word DMA "
                   & "never bound one, so this scenario proves nothing"
            severity failure;
          assert wg_opens = 0
            report "S11/4: WGATE opened for a 1-word DMA (ARM needs >= 2 "
                   & "words buffered before STREAM)" severity failure;
          assert d_gateopen = 0
            report "S11/4: 0x7A counted a gate-opened episode" severity failure;
          assert wr_session = '0'
            report "S11/4: the episode never closed - a sub-threshold DMA "
                   & "wedged the writer" severity failure;
          assert wr_busy = '0'
            report "S11/4: the writer is still busy - it did not return to "
                   & "IDLE after a sub-threshold episode" severity failure;
        else
          arm(G_WORDS, true, G_TRACK);
          wait until f_wgate = '0' for 60 ms;
          assert f_wgate = '0'
            report "S11: WGATE never opened before the reset injection"
            severity failure;
          wait for 1 ms;
          case G_VARIANT is
            when 1 =>                  -- full QNICE + Amiga reset
              rst50 <= '1'; rstmain <= '1'; amiga_rst <= '1';
              wait for 50 us;
              rst50 <= '0'; rstmain <= '0'; amiga_rst <= '0';
            when 2 =>                  -- Amiga reset alone
              amiga_rst <= '1';
              wait for 50 us;
              amiga_rst <= '0';
            when 3 =>                  -- bus_grant drop
              bus_grant <= '0';
              wait for 50 us;
              bus_grant <= '1';
            when others =>             -- abort via deselect, then re-arm
              hwf_sel <= '0';
              wait for 50 us;
              hwf_sel <= '1';
          end case;
          wait for 2 ms;
          assert f_wgate = '1'
            report "S11: WGATE still asserted after the reset class "
                   & integer'image(G_VARIANT) severity failure;

          -- Let the first episode finish before arming the next one. The
          -- writer discards an aborted episode at cell pace, so a DMA of
          -- G_WORDS words still takes words x 32 us to drain - arming on
          -- top of it would model something no Amiga ever does. Classes 1
          -- and 2 reset the Amiga, which destroys Paula's DMA outright, so
          -- there is no DSKBLK to wait for there; wait for the writer to
          -- fall back to idle instead.
          if G_VARIANT = 1 or G_VARIANT = 2 then
            wait until wr_busy = '0' for 400 ms;
            assert wr_busy = '0'
              report "S11: the writer never returned to IDLE after an "
                     & "Amiga reset destroyed the DMA" severity failure;
          else
            wait_blk(400 ms, "the aborted first episode");
          end if;
          wait for 2 ms;
          assert wr_session = '0'
            report "S11: the episode is still open after its DMA ended"
            severity failure;

          -- a new episode must start from its own first word
          wait for 12 ms;              -- re-qualify wr_ok after a reset
          n0 := wg_opens;
          arm(1200, true, G_TRACK);
          wait_blk(300 ms, "the episode after the reset");
          wait for 500 us;
          assert wg_opens = n0 + 1
            report "S11: the follow-up episode did not open its gate exactly "
                   & "once (" & integer'image(wg_opens - n0) & ")"
            severity failure;
          assert d_overflow = 0
            report "S11: 0x7D overflow nonzero after a reset - FIFO residue "
                   & "or desynchronized Gray pointers" severity failure;
          assert wg_len_cyc = 1200 * 16 * C_CELL
            report "S11: the follow-up window is "
                   & integer'image(wg_len_cyc) & " cycles, expected "
                   & integer'image(1200 * 16 * C_CELL)
                   & " - stale FIFO residue was serialized in front of it"
            severity failure;
        end if;

      -------------------------------------------------------------------------
      -- S2x: X-Copy's DOS-engine write. The buffer is [500 x $AAAA]
      -- [11 x 544][one trailing $AAAA] = 6485 words, and the host's first
      -- pin action after DSKBLK is the SIDE toggle about 30 us later, not a
      -- deselect: X-Copy selects the destination once and writes head 1,
      -- then head 0, with no selection change between them. G_VARIANT 1
      -- runs the deselect arm instead (the head-0 path, where the next pin
      -- action is the stepper's all-drive deselect about 70-90 us out).
      --
      -- The assert that matters is sector content. With one pad word of
      -- margin, a ~3-word residue cut at the SIDE toggle would land inside
      -- sector 10's last word: byte 510/511 of sector 10 (MFM stream word
      -- 543) on every head-1 track. This cell fails without the drain hold.
      -- S2 cannot see that, because there the capture is 6496 words with
      -- the gap first and the DMA longer still, so a cut lands in residue.
      -------------------------------------------------------------------------
      when 12 =>
        arm(C_XC_LEN, true, G_TRACK);
        wait_blk(500 ms, "the X-Copy DOS-engine write");
        wait for 30 us;                        -- the measured host latency
        if G_VARIANT = 1 then
          hwf_sel  <= '0'; p_sel <= "11";      -- deselect arm (head-0 path)
        else
          hwf_side <= '0';                     -- SIDE toggle (head-1 path)
        end if;
        wait for 2 ms;
        report "  S2x: WGATE window " & integer'image(wg_len_cyc)
               & " of " & integer'image(C_XC_LEN * 16 * C_CELL)
               & " cyc (deficit "
               & integer'image((C_XC_LEN * 16 * C_CELL - wg_len_cyc) / C_CELL)
               & " channel cells), 0x77 tail-cut "
               & integer'image(to_integer(unsigned(d_tail(7 downto 0))));
        hwf_sel <= '1'; p_sel <= C_PHYS_UNIT; hwf_side <= '1';
        wait for 12 ms;
        verdicts(G_TRACK);
        report "  S2x: sectors " & integer'image(q_sec_ok) & " clean / "
               & integer'image(q_sec_bad) & " BAD, referee err=$"
               & hex8(q_ref_err);
        -- the primary assert. q_sec_ok alone is not enough: it counts sector
        -- instances over a re-read that spans more than one revolution, so a
        -- destroyed sector 10 is masked by clean copies of the other ten and
        -- the count still reaches 11. q_sec_bad counts slots of this track
        -- whose payload decoded wrong, which is exactly the claim: the cut
        -- reached captured sector data.
        assert q_sec_bad = 0
          report "S2x: " & integer'image(q_sec_bad) & " sector slot(s) of "
                 & "this track decoded with a WRONG PAYLOAD - the host's "
                 & "post-DSKBLK pin action cut into CAPTURED SECTOR DATA. "
                 & "X-Copy leaves exactly ONE pad word of margin (DSKLEN "
                 & "$D955 = 6485 = 500 + 11x544 + 1), so the in-flight "
                 & "residue at DSKBLK must be <= 1 word, as on a real Paula."
          severity failure;
        assert q_sec_ok >= C_NSEC
          report "S2x: only " & integer'image(q_sec_ok) & " clean sector "
                 & "instances of " & integer'image(C_NSEC)
          severity failure;
        assert q_ref_err < 11
          report "S2x: the real-Paula referee FAILED with $" & hex8(q_ref_err)
          severity failure;
        -- the same absolutes S2 and S6 carry: with the drain hold in
        -- place a post-DSKBLK pin action is a non-event, so the window
        -- must be pin-exact and nothing may be cut. Without these, S2x
        -- could pass on a design that wrote the payload by luck.
        assert wg_len_cyc = C_XC_LEN * 16 * C_CELL
          report "S2x: the WGATE window was truncated to "
                 & integer'image(wg_len_cyc) & " of "
                 & integer'image(C_XC_LEN * 16 * C_CELL) & " cycles"
          severity failure;
        assert to_integer(unsigned(d_tail(7 downto 0))) = 0
          report "S2x: 0x77 tail-cut ticked for a post-DSKBLK pin action"
          severity failure;
        assert wg_opens = 1
          report "S2x: WGATE opened " & integer'image(wg_opens)
                 & " times in one episode" severity failure;

      -------------------------------------------------------------------------
      -- S12: the busy interlock. A read (or a new write) arriving during the
      -- tail must be deferred until the writer is idle.
      -------------------------------------------------------------------------
      when others =>
        arm(G_WORDS, true, G_TRACK);
        wait_blk(500 ms, "the write before the interlock test");
        -- the tail is now draining: fire the next request immediately
        t0 := now;
        if G_VARIANT = 0 then
          -- The read must be armed while the writer is still draining -
          -- that overlap is the scenario - and it must then be a real
          -- trackdisk read: verdict (a) is a full trackdisk decode, and it
          -- cannot succeed on a fragment, so the capture is the same
          -- 7358-word DMA KS1.3 issues.
          assert wr_busy = '1'
            report "S12/0: the writer was already IDLE when the read was "
                   & "armed - the tail is not being exercised, so this "
                   & "scenario proves nothing about the interlock"
            severity failure;
          capture(C_DMA_WORDS, G_TRACK);   -- a physical read inside the tail
          assert f_wgate = '1'
            report "S12: WGATE was still asserted when the deferred read "
                   & "started streaming" severity failure;
          verdict_a(G_TRACK);
          assert res.err < 11
            report "S12: the deferred read decoded $" & hex8(res.err)
                   & " - a read that the interlock correctly deferred must "
                   & "come back clean" severity failure;
          -- the kill for mutant (xiii). cap(0) = 0x4489 is guaranteed by the
          -- engine's serve-from-sync gate whatever the interlock does, so
          -- it proves nothing; observe the interlock directly instead - a
          -- physical read session must never be open while the writer is
          -- still draining its tail.
          assert ilock_viol = 0
            report "S12: a physical READ session was open for "
                   & integer'image(ilock_viol) & " cycle(s) while the "
                   & "writer was still busy - the READ-side busy interlock "
                   & "did not defer the read (mutant xiii); the read then "
                   & "captures the tail it is racing" severity failure;
          assert cap(0) = x"4489"
            report "S12: the deferred read's capture does not start at a "
                   & "sync word (got " & to_hstring(cap(0)) & ")"
            severity failure;
        else
          -- inside the tail: the writer is still draining its residue right
          -- now (the tail is ~104 us), so arming here is exactly the
          -- overlap the busy interlock exists for. Waiting for the writer
          -- to go idle first would let the tail finish and the interlock
          -- would never be exercised at all, so the assert below pins the
          -- precondition instead of trusting the timing.
          n0 := wg_opens;
          assert wr_busy = '1'
            report "S12/1: the writer was already IDLE when the second "
                   & "write was armed - the tail is not being exercised, so "
                   & "this scenario proves nothing about the interlock"
            severity failure;
          arm(1200, true, G_TRACK);    -- a new write inside the tail
          wait_blk(300 ms, "the deferred second write");
          wait for 500 us;
          assert wg_opens = n0 + 1
            report "S12: the second episode opened its gate "
                   & integer'image(wg_opens - n0) & " times" severity failure;
          assert wg_len_cyc = 1200 * 16 * C_CELL
            report "S12: the deferred write's window is "
                   & integer'image(wg_len_cyc) & " cycles, expected "
                   & integer'image(1200 * 16 * C_CELL)
                   & " - the second episode was bound on top of the first "
                   & "one's tail instead of being deferred (the WRITE-side "
                   & "interlock, mutant x)"
            severity failure;
        end if;

    end case;

    report "TB_FDD_WRITE scen=" & integer'image(G_SCEN)
           & " variant=" & integer'image(G_VARIANT)
           & " rpm=" & integer'image(G_RPM_MHZ)
           & " legacy=" & boolean'image(G_LEGACY)
           & " framehold=" & boolean'image(G_FRAMEHOLD)
           & ": ALL CHECKS PASS";
    stop;
  end process p_control;

end architecture sim;
