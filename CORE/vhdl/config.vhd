----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Configuration data for the Shell
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2023 and licensed under GPL v3.
-- Amiga 500 port (AExp) done in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config is
port (
   clk_i       : in std_logic;

   -- bits 27 .. 12:    select configuration data block; called "Selector" hereafter
   -- bits 11 downto 0: address the up to 4k the configuration data
   address_i   : in std_logic_vector(27 downto 0);

   -- config data
   data_o      : out std_logic_vector(15 downto 0)
);
end entity config;

architecture beh of config is

--------------------------------------------------------------------------------------------------------------------
-- String and character constants (specific for the Anikki-16x16 font)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant CHR_LINE_1  : character := character'val(196);
constant CHR_LINE_5  : string := CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1;
constant CHR_LINE_10 : string := CHR_LINE_5 & CHR_LINE_5;
constant CHR_LINE_50 : string := CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10;

--------------------------------------------------------------------------------------------------------------------
-- Welcome and Help Screens (Selectors 0x1000 .. 0x1FFF)
--------------------------------------------------------------------------------------------------------------------

-- define the amount of WHS array elements: between 1 and 16
constant WHS_RECORDS   : natural := 2;

-- define the maximum amount of pages per WHS array element: between 1 and 256
-- (this is necessary because Vivado does not support unconstrained arrays in a record)
constant WHS_MAX_PAGES : natural := 2;

 -- !!! DO NOT TOUCH !!!
constant SEL_WHS           : std_logic_vector(15 downto 0) := x"1000";
type WHS_INDEX_TYPE is array (0 to WHS_MAX_PAGES - 1) of natural;
type WHS_RECORD_TYPE is record
   page_count  : natural;
   page_start  : WHS_INDEX_TYPE;
   page_length : WHS_INDEX_TYPE;
end record;
type WHS_RECORD_ARRAY_TYPE is array (0 to WHS_RECORDS - 1) of WHS_RECORD_TYPE;

-- START YOUR CONFIGURATION BELOW THIS LINE

-- The core's version string. Single source of truth (same convention as
-- C64MEGA65, its GitHub issue #182): this constant is used by SCR_WELCOME,
-- HELP_1 and HELP_2 (the welcome and help screens just below), by CORENAME
-- (the serial-terminal banner further down) and by CFG_FILE (the on-SD-card
-- config filename further down). Update this one line when releasing a new
-- version; make_release.py parses it and uses it as the official version
-- string for that release.
constant CORE_VERSION : string := "WIP-V1-A3";

constant SCR_WELCOME : string :=

   "Amiga 500 for MEGA65 - " & CORE_VERSION & "\n" &
   "MiSTer Minimig-AGA port, by sy2002 in 2026\n\n" &

   "Powered by MiSTer2MEGA65 Version 2.0.1,\n" &
   "done by sy2002 and MJoergen\n\n\n" &

   "This core needs the Kickstart 1.3 ROM on\n" &
   "your SD card (FAT32):\n\n" &
   "    /amiga/kick.rom\n\n" &
   "Raw 256 KB dump of Kickstart 1.3\n" &
   "(rev 34.5, A500), no byte swapping.\n\n\n" &

   "    Key                Amiga 500\n" &
   "    " & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_1 & CHR_LINE_1 & "\n" &
   "    MEGA               Amiga (left)\n" &
   "    Help               Help / Options menu\n\n\n" &

   "\n\n    Press Space to continue.\n\n\n";

constant HELP_1 : string :=

   "\n Amiga 500 for MEGA65 - " & CORE_VERSION & "\n\n" &

   " MiSTer Minimig-AGA port, by sy2002 in 2026\n" &
   " Powered by MiSTer2MEGA65\n\n\n" &

   " Emulated machine:\n\n" &
   " Amiga 500, OCS chipset, PAL\n" &
   " 68000 CPU\n" &
   " 512 KB Chip RAM + 512 KB Slow RAM\n" &
   " Kickstart 1.3 (from /amiga/kick.rom)\n\n" &

   " Floppy: mount an .adf disk image via\n" &
   " the ' ADF:' menu item (read-only).\n" &
   " The disk boots after mounting.\n\n" &

   " Cursor right to learn more.       (1 of 2)\n" &
   " Press Space to close the help screen.";

constant HELP_2 : string :=

   "\n Amiga 500 for MEGA65 - " & CORE_VERSION & "\n\n" &

   " SD card setup:\n\n" &
   " The SD card must be FAT32 formatted\n" &
   " and 32 GB or smaller. The card in the\n" &
   " back slot has precedence over the\n" &
   " bottom slot.\n\n" &

   " Mandatory file:\n\n" &
   "    /amiga/kick.rom\n\n" &
   " 256 KB raw dump of Kickstart 1.3.\n" &
   " Without this file the core will not\n" &
   " start.\n\n" &

   " Crsr left: Prev                   (2 of 2)\n" &
   " Press Space to close the help screen.";

-- Concatenate all your Welcome and Help screens into one large string, so that during synthesis one large string ROM can be build.
constant WHS_DATA : string := SCR_WELCOME & HELP_1 & HELP_2;

-- The WHS array needs the start address of each page.
constant SCR_WELCOME_START : natural := 0;
constant HELP_1_START      : natural := SCR_WELCOME'length;
constant HELP_2_START      : natural := HELP_1_START + HELP_1'length;

-- Fill the WHS array with page start addresses and the length of each page.
-- Make sure that array element 0 is always your Welcome page.
constant WHS : WHS_RECORD_ARRAY_TYPE := (
   --- Welcome Screen
   (page_count    => 1,
    page_start    => (SCR_WELCOME_START,  0),
    page_length   => (SCR_WELCOME'length, 0)),

   --- Help pages
   (page_count    => 2,
    page_start    => (HELP_1_START,  HELP_2_START),
    page_length   => (HELP_1'length, HELP_2'length))
);

--------------------------------------------------------------------------------------------------------------------
-- Set start folder for file browser and specify config file for menu persistence (Selectors 0x0100 and 0x0101)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_DIR_START     : std_logic_vector(15 downto 0) := x"0100";
constant SEL_CFG_FILE      : std_logic_vector(15 downto 0) := x"0101";

-- START YOUR CONFIGURATION BELOW THIS LINE

constant DIR_START         : string := "/amiga";
constant CFG_FILE          : string := "/amiga/aexp-" & CORE_VERSION & ".cfg";

--------------------------------------------------------------------------------------------------------------------
-- General configuration settings: Reset, Pause, OSD behavior, Ascal, etc. (Selector 0x0110)
--------------------------------------------------------------------------------------------------------------------

constant SEL_GENERAL       : std_logic_vector(15 downto 0) := x"0110";  -- !!! DO NOT TOUCH !!!

-- START YOUR CONFIGURATION BELOW THIS LINE

-- at a minimum, keep the reset line active for this amount of "QNICE loops" (see gencfg.asm).
-- "0" means: deactivate this feature
constant RESET_COUNTER     : natural := 100;

-- put the core in PAUSE state if any OSD opens
-- IMPORTANT: must stay false for the Amiga core: main.vhd does not implement
-- pause_i yet (minimig has no clean pause point; would need gating of the
-- clk7/c1/c3/cck enables - later milestone)
constant OPTM_PAUSE        : boolean := false;

-- show the welcome screen in general
-- Switched off like in the C64MEGA65 reference: boots straight into the core.
-- The mandatory-ROM fatal screen names /amiga/kick.rom if it is missing, and
-- the About & Help pages document the SD card setup, so nothing is lost.
-- (SCR_WELCOME stays defined: WHS array position 0 must always exist.)
constant WELCOME_ACTIVE    : boolean := false;

-- shall the welcome screen also be shown after the core is reset?
-- (only relevant if WELCOME_ACTIVE is true)
constant WELCOME_AT_RESET  : boolean := false;

-- keyboard and joystick connection during reset and OSD
constant KEYBOARD_AT_RESET : boolean := false;
constant JOY_1_AT_RESET    : boolean := false;
constant JOY_2_AT_RESET    : boolean := false;

constant KEYBOARD_AT_OSD   : boolean := false;
constant JOY_1_AT_OSD      : boolean := true;   -- mouse (Amiga port 1) stays active while the OSM is
                                                -- open; the keyboard belongs to the OSM (false above)
constant JOY_2_AT_OSD      : boolean := false;

-- Avalon Scaler settings (see ascal.vhd, used for HDMI output only)
-- 0=set ascal mode (via QNICE's ascal_mode_o) to the value of the config.vhd constant ASCAL_MODE
-- 1=do nothing, leave ascal mode alone, custom QNICE assembly code can still change it via M2M$ASCAL_MODE
--               and QNICE's CSR will be set to not automatically sync ascal_mode_i
-- 2=keep ascal mode in sync with the QNICE input register ascal_mode_i:
--   use this if you want to control the ascal mode for example via the Options menu
--   where you would wire the output of certain options menu bits with ascal_mode_i
constant ASCAL_USAGE       : natural := 1;   -- AUSE_CUSTOM, like C64MEGA65 V6: the HDMI Filter dispatcher in
                                             -- CORE/m2m-rom/m2m-rom.asm writes M2M$ASCAL_MODE directly (ASCAL_INIT
                                             -- in M2M/rom/gencfg.asm clears the CSR ascal-autosync bit first)
constant ASCAL_MODE        : natural := 0;   -- ignored when ASCAL_USAGE=1; m2m-rom sets the mode per HDMI Filter
                                             -- selection (No Filter/Sharp Bilinear/Bicubic -> native
                                             -- NEAREST/SBILINEAR/BICUBIC, the other 5 -> POLYPHASE)

-- Save on-screen-display settings if the file specified by CFG_FILE exists and if it has
-- the length of OPTM_SIZE bytes. If the first byte of the file has the value 0xFF then it
-- is considered as "default", i.e. the menu items specified by OPTM_G_STDSEL are selected.
-- If the file does not exists, then settings are not saved and OPTM_G_STDSEL always denotes the standard settings.
constant SAVE_SETTINGS     : boolean := true;

-- Delay in ms between the last write request to a virtual drive from the core and the start of the
-- cache flushing (i.e. writing to the SD card).
constant VD_ANTI_THRASHING_DELAY : natural := 2000;

-- Amount of bytes saved in one iteration of the background saving (buffer flushing) process
constant VD_ITERATION_SIZE       : natural := 100;

--------------------------------------------------------------------------------------------------------------------
-- Name and version of the core  (Selector 0x0200)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_CORENAME      : std_logic_vector(15 downto 0) := x"0200";

-- START YOUR CONFIGURATION BELOW THIS LINE

-- Currently this is only used in the debug console. Use the welcome screen and the
-- help system to display the name and version of your core to the end user
constant CORENAME          : string := "Amiga 500 for MEGA65 " & CORE_VERSION;

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu  (Selectors 0x0300 .. 0x0312): DO NOT TOUCH
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!! Selectors for accessing the menu configuration data
constant SEL_OPTM_ITEMS       : std_logic_vector(15 downto 0) := x"0300";
constant SEL_OPTM_GROUPS      : std_logic_vector(15 downto 0) := x"0301";
constant SEL_OPTM_STDSEL      : std_logic_vector(15 downto 0) := x"0302";
constant SEL_OPTM_LINES       : std_logic_vector(15 downto 0) := x"0303";
constant SEL_OPTM_START       : std_logic_vector(15 downto 0) := x"0304";
constant SEL_OPTM_ICOUNT      : std_logic_vector(15 downto 0) := x"0305";
constant SEL_OPTM_MOUNT_DRV   : std_logic_vector(15 downto 0) := x"0306";
constant SEL_OPTM_SINGLESEL   : std_logic_vector(15 downto 0) := x"0307";
constant SEL_OPTM_MOUNT_STR   : std_logic_vector(15 downto 0) := x"0308";
constant SEL_OPTM_DIMENSIONS  : std_logic_vector(15 downto 0) := x"0309";
constant SEL_OPTM_SAVING_STR  : std_logic_vector(15 downto 0) := x"030A";
constant SEL_OPTM_HELP        : std_logic_vector(15 downto 0) := x"0310";
constant SEL_OPTM_CRTROM      : std_logic_vector(15 downto 0) := x"0311";
constant SEL_OPTM_CRTROM_STR  : std_logic_vector(15 downto 0) := x"0312";

-- !!! DO NOT TOUCH !!! Configuration constants for OPTM_GROUPS (shell.asm and menu.asm expect them to be like this)
constant OPTM_G_TEXT       : integer := 16#00000#;         -- text that cannot be selected
constant OPTM_G_CLOSE      : integer := 16#000FF#;        -- menu items that closes menu
constant OPTM_G_STDSEL     : integer := 16#00100#;        -- item within a group that is selected by default
constant OPTM_G_LINE       : integer := 16#00200#;        -- draw a line at this position
constant OPTM_G_START      : integer := 16#00400#;        -- selector / cursor position after startup (only use once!)
                                                          -- 16#00800# is used in OPTM_G_MOUNT_DRV (OPTM_G_SINGLESEL)
constant OPTM_G_HEADLINE   : integer := 16#01000#;        -- like OPTM_G_TEXT but will be shown in a brigher color
                                                          -- 16#02000# is used in OPTM_G_HELP (plus OPTM_G_SINGLESEL)
                                                          -- 16#04000# is used in OPTM_G_SUBMENU
constant OPTM_G_SINGLESEL  : integer := 16#08000#;        -- single select item
constant OPTM_G_MOUNT_DRV  : integer := 16#08800#;        -- line item means: mount drive; first occurance = drive 0, second = drive 1, ...
constant OPTM_G_HELP       : integer := 16#0A000#;        -- line item means: help screen; first occurance = WHS(1), second = WHS(2), ...
constant OPTM_G_SUBMENU    : integer := 16#0C000#;        -- starts/ends a section that is treated as submenu
constant OPTM_G_LOAD_ROM   : integer := 16#18000#;        -- line item means: load ROM; first occurance = rom 0, second = rom 1, ...

constant OPTM_GTC          : natural := 17;                -- Amount of significant bits in OPTM_G_* constants

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu: START YOUR CONFIGURATION BELOW THIS LINE
--------------------------------------------------------------------------------------------------------------------

-- Strings with which %s will be replaced in case the menu item is of type OPTM_G_MOUNT_DRV
constant OPTM_S_MOUNT      : string := "<Mount Drive>";     -- no disk image mounted, yet
constant OPTM_S_CRTROM     : string := "<Load>";            -- no ROM loaded, yet
constant OPTM_S_SAVING     : string := "<Saving>";          -- the internal write cache is dirty and not yet written back to the SD card

-- Size of menu and menu items
-- CAUTION: 1. End each line (also the last one) with a \n and make sure empty lines / separator lines are only consisting of a "\n"
--             Do use a lower case \n. If you forget one of them or if you use upper case, you will run into undefined behavior.
--          2. Start each line that contains an actual menu item (multi- or single-select) with a Space character,
--             otherwise you will experience visual glitches.
constant OPTM_SIZE         : natural := 44;  -- amount of items including empty lines:
                                             -- needs to be equal to the number of lines in OPTM_ITEMS and amount of items in OPTM_GROUPS
                                             -- IMPORTANT: If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and
                                             -- and re-distribute the config file. You can make a new one using M2M/tools/make_config.sh

-- Net size of the Options menu on the screen in characters (excluding the frame, which is hardcoded to two characters)
-- Without submenus: Use OPTM_SIZE as height, otherwise use the height of the largest menu view: count one line per
-- item that is visible at that level, including one line per submenu label, excluding the contents of submenus.
-- (A submenu view does NOT show its own label line - see _OPTM_STRUCT in M2M/rom/menu.asm.)
-- Main menu view = 11 lines, HDMI Settings submenu view = 11 lines,
-- HDMI Filter submenu view = 12 lines, VGA submenu view = 10 lines.
constant OPTM_DX           : natural := 23;
constant OPTM_DY           : natural := 12;

-- OSM bit positions (zero-based line numbers) are decoded in mega65.vhd via C_MENU_* constants:
--   line  7: 720p 50 Hz  /  8: 720p 60 Hz  /  9: 576p 50 4:3  / 10: 576p 50 5:4
--   line 11: 640x480 60  / 12: 720x480 59.94 / 13: 800x600 60
--   line 32: VGA Standard / 36: VGA 15 kHz with HS/VS / 37: VGA 15 kHz with CSYNC
-- Lines 19..26 (HDMI Filter radio) are NOT decoded in mega65.vhd: the firmware
-- dispatcher LOAD_HDMI_FILTER in CORE/m2m-rom/m2m-rom.asm reads them via
-- M2M$GET_SETTING and programs ascal directly (ASCAL_USAGE=1).
-- Line 2 (" ADF:%s") is a manual CRT/ROM load item handled by the Shell: it
-- opens the file browser and streams the .adf into the C_DEV_AMIGA_ADF device.
constant OPTM_ITEMS        : string :=

   " Amiga 500\n"           &    --  0: headline
   "\n"                     &    --  1: line

   " ADF:%s\n"              &    --  2: mount ADF disk image (df0:)
   "\n"                     &    --  3: line

   " HDMI: %s\n"            &    --  4: HDMI submenu
   " HDMI Settings\n"       &    --  5: headline
   "\n"                     &    --  6: line
   " 720p 50 Hz 16:9\n"     &    --  7
   " 720p 60 Hz 16:9\n"     &    --  8
   " 576p 50 Hz 4:3\n"      &    --  9
   " 576p 50 Hz 5:4\n"      &    -- 10
   " 640x480 60 Hz\n"       &    -- 11
   " 720x480 59.94 Hz\n"    &    -- 12
   " 800x600 60 Hz\n"       &    -- 13
   "\n"                     &    -- 14: line
   " Back to main menu\n"   &    -- 15: close submenu

   " HDMI: %s\n"            &    -- 16: HDMI Filter submenu, directly under HDMI Settings
   " HDMI Filter\n"         &    -- 17: headline
   "\n"                     &    -- 18: line
   " No Filter\n"           &    -- 19: ascal native NEAREST
   " Sharp Bilinear\n"      &    -- 20: ascal native SBILINEAR
   " Bicubic\n"             &    -- 21: ascal native BICUBIC
   " Smooth\n"              &    -- 22: polyphase
   " Lanczos\n"             &    -- 23: polyphase; default
   " Scanlines\n"           &    -- 24: polyphase; the former "CRT emulation" look
   " CRT (S-Video)\n"       &    -- 25: polyphase
   " CRT (Composite)\n"     &    -- 26: polyphase
   "\n"                     &    -- 27: line
   " Back to main menu\n"   &    -- 28: close submenu

   " VGA: %s\n"             &    -- 29: VGA (analog output) submenu
   " VGA Display Mode\n"    &    -- 30: headline
   "\n"                     &    -- 31: line
   " Standard\n"            &    -- 32: scandoubled 31.25 kHz; default
   "\n"                     &    -- 33: line
   " Retro 15 kHz mode\n"   &    -- 34: text (sub-headline for the two 15 kHz options)
   "\n"                     &    -- 35: line
   " 15 kHz with HS/VS\n"   &    -- 36: raw 15.625 kHz RGB, separate syncs
   " 15 kHz with CSYNC\n"   &    -- 37: raw 15.625 kHz RGB, composite sync (SCART)
   "\n"                     &    -- 38: line
   " Back to main menu\n"   &    -- 39: close submenu

   "\n"                     &    -- 40: line
   " About & Help\n"        &    -- 41: help
   "\n"                     &    -- 42: line
   " Close Menu\n";              -- 43: close

-- define your own constants here and choose meaningful names
-- make sure that your first group uses the value 1 (0 means "no menu item", such as text and line),
-- and be aware that you can only have a maximum of 254 groups (255 means "Close Menu");
-- also make sure that your group numbers are monotonic increasing (e.g. 1, 2, 3, 4, ...)
-- single-select items and therefore also drive mount items need to have unique identifiers
constant OPTM_G_ADF        : integer := 1;   -- mount ADF for df0 (manual CRT/ROM load 0)
constant OPTM_G_HDMI       : integer := 2;
constant OPTM_G_FILTER     : integer := 3;   -- HDMI Filter radio; mirrored as OPTM_G_FLT in CORE/m2m-rom/m2m-rom.asm
constant OPTM_G_VGA        : integer := 4;   -- VGA/analog output mode radio (Standard / 15 kHz HS+VS / 15 kHz CSYNC)
constant OPTM_G_About      : integer := 5;

-- !!! DO NOT TOUCH !!!
type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

-- define your menu groups: which menu items are belonging together to form a group?
-- where are separator lines? which items should be selected by default?
-- make sure that you have exactly the same amount of entries here than in OPTM_ITEMS and defined by OPTM_SIZE
constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --  0: Headline "Amiga 500"
                                             OPTM_G_LINE,                              --  1: Line

                                             OPTM_G_ADF + OPTM_G_LOAD_ROM
                                                        + OPTM_G_START,                --  2: mount ADF (df0:); cursor start
                                             OPTM_G_LINE,                              --  3: Line

                                             OPTM_G_SUBMENU,                           --  4: HDMI submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  5: Headline "HDMI Settings"
                                             OPTM_G_LINE,                              --  6: Line
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              --  7: 720p 50 Hz 16:9, default
                                             OPTM_G_HDMI,                              --  8: 720p 60 Hz 16:9
                                             OPTM_G_HDMI,                              --  9: 576p 50 Hz 4:3
                                             OPTM_G_HDMI,                              -- 10: 576p 50 Hz 5:4
                                             OPTM_G_HDMI,                              -- 11: 640x480 60 Hz
                                             OPTM_G_HDMI,                              -- 12: 720x480 59.94 Hz
                                             OPTM_G_HDMI,                              -- 13: 800x600 60 Hz
                                             OPTM_G_LINE,                              -- 14: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 15: Close submenu / back to main menu

                                             OPTM_G_SUBMENU,                           -- 16: HDMI Filter submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 17: Headline "HDMI Filter"
                                             OPTM_G_LINE,                              -- 18: Line
                                             OPTM_G_FILTER,                            -- 19: No Filter
                                             OPTM_G_FILTER,                            -- 20: Sharp Bilinear
                                             OPTM_G_FILTER,                            -- 21: Bicubic
                                             OPTM_G_FILTER,                            -- 22: Smooth
                                             OPTM_G_FILTER + OPTM_G_STDSEL,            -- 23: Lanczos (default)
                                             OPTM_G_FILTER,                            -- 24: Scanlines
                                             OPTM_G_FILTER,                            -- 25: CRT (S-Video)
                                             OPTM_G_FILTER,                            -- 26: CRT (Composite)
                                             OPTM_G_LINE,                              -- 27: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 28: Close submenu / back to main menu

                                             OPTM_G_SUBMENU,                           -- 29: VGA submenu block: "VGA: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 30: Headline "VGA Display Mode"
                                             OPTM_G_LINE,                              -- 31: Line
                                             OPTM_G_VGA + OPTM_G_STDSEL,               -- 32: Standard (default)
                                             OPTM_G_LINE,                              -- 33: Line
                                             OPTM_G_TEXT,                              -- 34: Text "Retro 15 kHz mode"
                                             OPTM_G_LINE,                              -- 35: Line
                                             OPTM_G_VGA,                               -- 36: 15 kHz with HS/VS
                                             OPTM_G_VGA,                               -- 37: 15 kHz with CSYNC
                                             OPTM_G_LINE,                              -- 38: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 39: Close submenu / back to main menu

                                             OPTM_G_LINE,                              -- 40: Line
                                             OPTM_G_About   + OPTM_G_HELP,             -- 41: About & Help (WHS(1))
                                             OPTM_G_LINE,                              -- 42: Line
                                             OPTM_G_CLOSE                              -- 43: Close Menu
                                           );

--------------------------------------------------------------------------------------------------------------------
-- !!! CAUTION: M2M FRAMEWORK CODE !!! DO NOT TOUCH ANYTHING BELOW THIS LINE !!!
--------------------------------------------------------------------------------------------------------------------

--------------------------------------------------------------------------------------------------------------------
-- Address Decoding
--------------------------------------------------------------------------------------------------------------------

begin

addr_decode : process(clk_i)
   -- return ASCII value of given string at the position defined by index (zero-based)
   pure function str2data(str : string; index : integer) return std_logic_vector is
   variable strpos : integer;
   begin
      strpos := index + 1;
      if strpos <= str'length then
         return std_logic_vector(to_unsigned(character'pos(str(strpos)), 16));
      else
         return X"0000"; -- zero terminated strings
      end if;
   end function str2data;

   -- return the dimensions of the Options menu
   pure function getDXDY(dx, dy, index: natural) return std_logic_vector is
   begin
      case index is
         when 0 => return std_logic_vector(to_unsigned(dx + 2, 16));
         when 1 => return std_logic_vector(to_unsigned(dy + 2, 16));
         when others => return X"0000";
      end case;
   end function getDXDY;

   -- convert bool to std_logic_vector
   pure function bool2slv(b: boolean) return std_logic_vector is
   begin
      if b then
         return x"0001";
      else
         return x"0000";
      end if;
   end function bool2slv;

   -- return the General Configuration settings
   function getGenConf(index: natural) return std_logic_vector is
   begin
      case index is
         when 1      => return std_logic_vector(to_unsigned(RESET_COUNTER, 16));
         when 2      => return bool2slv(OPTM_PAUSE);
         when 3      => return bool2slv(WELCOME_ACTIVE);
         when 4      => return bool2slv(WELCOME_AT_RESET);
         when 5      => return bool2slv(KEYBOARD_AT_RESET);
         when 6      => return bool2slv(JOY_1_AT_RESET);
         when 7      => return bool2slv(JOY_2_AT_RESET);
         when 8      => return bool2slv(KEYBOARD_AT_OSD);
         when 9      => return bool2slv(JOY_1_AT_OSD);
         when 10     => return bool2slv(JOY_2_AT_OSD);
         when 11     => return std_logic_vector(to_unsigned(ASCAL_USAGE, 16));
         when 12     => return std_logic_vector(to_unsigned(ASCAL_MODE, 16));
         when 13     => return std_logic_vector(to_unsigned(VD_ANTI_THRASHING_DELAY, 16));
         when 14     => return std_logic_vector(to_unsigned(VD_ITERATION_SIZE, 16));
         when 15     => return bool2slv(SAVE_SETTINGS);
         when others => return x"0000";
      end case;
   end function getGenConf;

   variable index           : integer;
   variable whs_page_index  : integer;
   variable whs_array_index : integer;

begin

   if falling_edge(clk_i) then

      index := to_integer(unsigned(address_i(11 downto 0)));
      whs_page_index  := to_integer(unsigned(address_i(19 downto 12)));
      whs_array_index := to_integer(unsigned(address_i(23 downto 20)));

      data_o <= x"EEEE";

      -----------------------------------------------------------------------------------
      -- Welcome & Help System: upper 4 bits of address equal SEL_WHS' upper 4 bits
      -----------------------------------------------------------------------------------

      if address_i(27 downto 24) = SEL_WHS(15 downto 12) then

         if  whs_array_index < WHS_RECORDS then
            if index = 4095 then
               data_o <= std_logic_vector(to_unsigned(WHS(whs_array_index).page_count, 16));
            else
               if index < WHS(whs_array_index).page_length(whs_page_index) then
                  data_o <= str2data(WHS_DATA, WHS(whs_array_index).page_start(whs_page_index) + index);
               else
                  data_o <= (others => '0'); -- zero-terminated strings
               end if;
            end if;
         end if;

      -----------------------------------------------------------------------------------
      -- All other selectors, which are 16-bit values
      -----------------------------------------------------------------------------------

      else

         case address_i(27 downto 12) is
            when SEL_GENERAL           => data_o <= getGenConf(index);
            when SEL_DIR_START         => data_o <= str2data(DIR_START, index);
            when SEL_CFG_FILE          => data_o <= str2data(CFG_FILE, index);
            when SEL_CORENAME          => data_o <= str2data(CORENAME, index);
            when SEL_OPTM_ITEMS        => data_o <= str2data(OPTM_ITEMS, index);
            when SEL_OPTM_MOUNT_STR    => data_o <= str2data(OPTM_S_MOUNT, index);
            when SEL_OPTM_CRTROM_STR   => data_o <= str2data(OPTM_S_CRTROM, index);
            when SEL_OPTM_SAVING_STR   => data_o <= str2data(OPTM_S_SAVING, index);
            when SEL_OPTM_GROUPS       => data_o <= std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15)) &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(14)) & "0" &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(12)) & "0000" &
                                                    std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(7 downto 0));
            when SEL_OPTM_STDSEL       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(8));
            when SEL_OPTM_LINES        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(9));
            when SEL_OPTM_START        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(10));
            when SEL_OPTM_MOUNT_DRV    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(11));
            when SEL_OPTM_HELP         => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(13));
            when SEL_OPTM_SINGLESEL    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15));
            when SEL_OPTM_CRTROM       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(16));
            when SEL_OPTM_ICOUNT       => data_o <= x"00" & std_logic_vector(to_unsigned(OPTM_SIZE, 8));
            when SEL_OPTM_DIMENSIONS   => data_o <= getDXDY(OPTM_DX, OPTM_DY, index);

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;
