; ****************************************************************************
; YOUR-PROJECT-NAME (GITHUB-REPO-SHORTNAME) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by TODO-ADD-NAME-OF-VHDL-FILE-HERE.
;
; The execution starts at the label START_FIRMWARE.
;
; done by YOURNAME in YEAR and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
#include "../../M2M/rom/main.asm"

; Only include the Shell, if you want to use the pre-build core automation
; and user experience. If you build your own, then remove this include and
; also remove the include "shell_vars.asm" in the variables section below.
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

                ; Run the Shell: This is where you could put your own system
                ; instead of the shell
START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the
; browser is only showing valid files and directories.
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: Context (see CTX_* in sysdef.asm)
;  R11: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering FILTER_FILES
; Output:
;   R8: 0=do not filter file, i.e. show file
FILTER_FILES    INCRB
                MOVE    R9, R0

                CMP     1, R9                   ; do not filter directories
                RBRA    _FFILES_RET_0, Z

                CMP     CTX_LOAD_ROM, R10       ; only filter in the ADF
                RBRA    _FFILES_RET_0, !Z       ; load context
                CMP     OPTM_G_ADF, R11         ; menu item " ADF:%s"?
                RBRA    _FFILES_RET_0, !Z

                MOVE    ADF_FILE_EXT, R9        ; only show .adf files
                RSUB    M2M$CHK_EXT, 1          ; preserves R8/R9/R10
                RBRA    _FFILES_RET_0, C        ; extension matched: show it

                MOVE    1, R8                   ; no match: filter it
                RBRA    _FFILES_RET, 1

_FFILES_RET_0   XOR     R8, R8                  ; R8 = 0 = do not filter file

_FFILES_RET     MOVE    R0, R9
                DECRB
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; The ADF is streamed into the C_DEV_AMIGA_ADF device, which bridges into a
; 4 MB HyperRAM region (see globals.vhd). We range-guard the file size to
; 160..166 tracks x 5632 bytes = 901,120..934,912 bytes BEFORE streaming, so
; an absurd (renamed) file can never stream past the region. The exact
; multiple-of-5632 validation happens in the core-side CSR responder
; (adf_mount_wrapper.vhd), which reports "Invalid ADF size" to the OSM.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: Context (see CTX_* in sysdef.asm)
;  R10: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering PREP_LOAD_IMAGE
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to  error msg string
PREP_LOAD_IMAGE INCRB

                CMP     CTX_LOAD_ROM, R9        ; only guard the ADF load
                RBRA    _PREP_LI_OK, !Z
                CMP     OPTM_G_ADF, R10
                RBRA    _PREP_LI_OK, !Z

                MOVE    R8, R0                  ; R0: file size low word
                MOVE    R8, R1                  ; R1: file size high word
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R0
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R1

                ; valid range: 901,120 (0x000DC000) .. 934,912 (0x000E4400).
                ; QNICE CMP sets N for UNSIGNED src>dst (V is the signed one),
                ; so plain compares would work for any value; the bit masks
                ; below are used purely for clarity/symmetry.
                CMP     0x000D, R1              ; high word 0x000D?
                RBRA    _PREP_LI_HID, Z
                CMP     0x000E, R1              ; high word 0x000E?
                RBRA    _PREP_LI_BAD, !Z

                ; high word 0x000E: low word must be <= 0x4400
                MOVE    R0, R2
                AND     0x8000, R2              ; lo >= 0x8000 can never be ok
                RBRA    _PREP_LI_BAD, !Z
                CMP     0x4400, R0              ; both positive: exact compare
                RBRA    _PREP_LI_OK, N          ; lo <  0x4400: OK
                RBRA    _PREP_LI_OK, Z          ; lo == 0x4400: OK
                RBRA    _PREP_LI_BAD, 1         ; lo >  0x4400: too big

                ; high word 0x000D: low word must be >= 0xC000
_PREP_LI_HID    MOVE    R0, R2
                AND     0xC000, R2              ; >= 0xC000 iff bits 15+14 set
                CMP     0xC000, R2
                RBRA    _PREP_LI_BAD, !Z

_PREP_LI_OK     XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                DECRB
                RET

_PREP_LI_BAD    MOVE    1, R8                   ; error: invalid size
                MOVE    WRN_ADF_SIZE, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
PREP_START      INCRB

                ; Apply the saved HDMI Filter selection. At this point the
                ; framework has already loaded its own default into the
                ; ascal polyphase RAM (LANCZOS2_12 + SCAN_BR_110_80 via
                ; M2M/rom/filters.asm:LOAD_ASCAL_FLT), and HELP_MENU_INIT has
                ; populated M2M$CFM_DATA from the saved SD config. We now
                ; overwrite the framework default with whatever the user
                ; chose -- before the core un-resets and the first frame
                ; reaches HDMI, so no glitch is visible. The default
                ; selection in config.vhd is "Lanczos" (LANCZOS2_12 on both
                ; axes), so for first-time users (or anyone with an empty
                ; config) this replaces the Scanlines-look preload of the
                ; framework before it ever reaches the screen.
                RSUB    LOAD_HDMI_FILTER, 1

                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
OSM_SEL_POST    INCRB

                ; HDMI Filter selection changed: re-push the matching (H, V)
                ; coefficient pair into the ascal polyphase RAM. NO core
                ; reset -- only the coefficient RAM content changes; the
                ; Amiga keeps running. The user sees the new filter from the
                ; next frame.
                CMP     OPTM_G_FLT, R8
                RBRA    _OSM_SEL_POST_R, !Z
                RSUB    LOAD_HDMI_FILTER, 1

_OSM_SEL_POST_R XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
OSM_SEL_PRE     INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      XOR     R8, R8
                RET              

; ----------------------------------------------------------------------------
; HDMI Filter dispatch
; (ported from C64MEGA65 V6, CORE/m2m-rom/m2m-rom.asm)
; ----------------------------------------------------------------------------

; LOAD_HDMI_FILTER: Read the saved HDMI Filter selection from M2M$CFM_DATA
; and configure ascal accordingly. Called from PREP_START (boot) and
; OSM_SEL_POST (runtime). Eight options, single-select: exactly one of the
; OSM_FLT_* bits is set at any time -- OPTM_G_STDSEL in config.vhd
; guarantees a default ("Lanczos") if the saved SD config file is missing
; or empty.
;
; Two execution shapes, both encoded in HDMI_FLT_TABLE rows
; (OSM_bit, ASCAL_MODE_word, H_label, V_label):
;
;   * Native modes (No Filter / Sharp Bilinear / Bicubic) -> write the
;                  matching mode word (NEAREST / SBILINEAR / BICUBIC) to
;                  M2M$ASCAL_MODE. The H/V labels are 0 sentinels: we skip
;                  the polyphase RAM write entirely and let ascal run its
;                  built-in scaler datapath.
;   * Polyphase modes (Smooth / Lanczos / Scanlines / CRT (S-Video) /
;                  CRT (Composite)) -> write POLYPHASE then push the
;                  (H_label, V_label) pair into the ascal polyphase RAM
;                  via M2M$LOAD_POLYPHASE.
;
; This routine assumes ASCAL_USAGE=1 (AUSE_CUSTOM) in config.vhd: ASCAL_INIT
; in M2M/rom/gencfg.asm always clears the M2M$CSR ascal-autosync bit first
; and only re-sets it for AUSE_AUTO, so with AUSE_CUSTOM the M2M$ASCAL_MODE
; register stays firmware-writable. If a future core sets ASCAL_USAGE back
; to 2 (AUSE_AUTO), the mode writes below silently no-op.
;
; Input:  None
; Output: R8 = 0, R9 = 0 on success
LOAD_HDMI_FILTER INCRB
                MOVE    HDMI_FLT_TABLE, R0
                MOVE    8, R1                   ; option count

_LHF_LOOP       MOVE    @R0++, R8               ; R8 = OSM bit for this option
                RSUB    M2M$GET_SETTING, 1
                CMP     1, R9                   ; selected?
                RBRA    _LHF_FOUND, Z           ; yes -> apply this row
                ADD     3, R0                   ; no -> skip MODE, H, V
                SUB     1, R1
                RBRA    _LHF_LOOP, !Z

                ; Defensive fallback: no bit set. Force the Lanczos preset
                ; (polyphase mode + Lanczos2_12 on both axes), matching the
                ; config.vhd OPTM_G_STDSEL default.
                MOVE    M2M$ASCAL_MODE, R2
                MOVE    M2M$ASCAL_POLYPHASE, @R2
                MOVE    LANCZOS2_12,    R8
                MOVE    LANCZOS2_12,    R9
                RSUB    M2M$LOAD_POLYPHASE, 1
                RBRA    _LHF_RET, 1

_LHF_FOUND      MOVE    @R0++, R3               ; R3 = ASCAL_MODE word
                MOVE    M2M$ASCAL_MODE, R2
                MOVE    R3, @R2                 ; write mode register
                MOVE    @R0++, R8               ; R8 = H label (0 = sentinel)
                MOVE    @R0,   R9               ; R9 = V label (0 = sentinel)
                CMP     0, R8                   ; native-mode sentinel?
                RBRA    _LHF_RET, Z             ; yes -> done, no RAM write
                RSUB    M2M$LOAD_POLYPHASE, 1

_LHF_RET        XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; Filter table: (OSM_bit, ASCAL_MODE_word, H_label, V_label) per option, in
; OPTM_ITEMS display order. The first three rows use ascal native modes
; (NEAREST / SBILINEAR / BICUBIC); their H and V are 0 sentinels so the
; dispatcher skips the polyphase RAM write for them. The remaining five
; rows all select polyphase (mode 100) and provide real coefficient table
; labels.
;
; See CORE/m2m-rom/video_filters/README.md for per-blob notes and
; CORE/vhdl/config.vhd for the OPTM_ITEMS / OPTM_GROUPS structure.
HDMI_FLT_TABLE  .DW OSM_FLT_NO_FILTER,     M2M$ASCAL_NEAREST,   0,                   0
                .DW OSM_FLT_SHARP,         M2M$ASCAL_SBILINEAR, 0,                   0
                .DW OSM_FLT_BICUBIC,       M2M$ASCAL_BICUBIC,   0,                   0
                .DW OSM_FLT_SMOOTH,        M2M$ASCAL_POLYPHASE, GS_SHARPNESS_050,    GS_SHARPNESS_050
                .DW OSM_FLT_LANCZOS,       M2M$ASCAL_POLYPHASE, LANCZOS2_12,         LANCZOS2_12
                .DW OSM_FLT_SCANLINES,     M2M$ASCAL_POLYPHASE, LANCZOS2_12,         SCAN_BR_110_80

                ; Both CRT rows reuse SCAN_BR_110_80 as the V file (same as
                ; Scanlines mode). CRT_Sim_*_V is a deep ~40% mid-phase
                ; plateau designed to be combined with the MiSTer gamma LUT
                ; + shadow mask; M2M supports neither, so standalone the
                ; plateau crushes bright content into a dark band. The
                ; Composite vs S-Video character lives entirely in the H
                ; file (Composite has heavy horizontal blur, S-Video has
                ; mild softening), so swapping only the V file preserves the
                ; perceptual distinction while restoring near-unity mean
                ; brightness.
                .DW OSM_FLT_CRT_SVIDEO,    M2M$ASCAL_POLYPHASE, CRT_SIM_SVIDEO_H,    SCAN_BR_110_80
                .DW OSM_FLT_CRT_COMPOSITE, M2M$ASCAL_POLYPHASE, CRT_SIM_COMPOSITE_H, SCAN_BR_110_80

; ----------------------------------------------------------------------------
; M2M$LOAD_POLYPHASE  Load a (horizontal, vertical) filter pair into the
;                    ascal polyphase coefficient RAM. ASCAL_FILTER_LEN
;                    (= 0x100, defined in M2M/rom/filters.asm) words are
;                    copied into the H slot at M2M$ASCAL_PP_HORIZ and another
;                    0x100 words into the V slot at M2M$ASCAL_PP_VERT,
;                    through QNICE device M2M$ASCAL_PPHASE.
;
;                    Safe to call at boot or at runtime from a core OSM
;                    callback. Does NOT touch ascal mode bits, does NOT reset
;                    the core.
;
;                    BACKPORT from M2M V2.1 (M2M/rom/tools.asm): our M2M
;                    V2.0.1 framework does not ship this routine and M2M/rom
;                    firmware stays unmodified in this repo, so it lives here
;                    (the only sanctioned M2M/ change is the VHDL interlace
;                    feature, tagged M2M-UPSTREAM interlace). When the
;                    framework is upgraded to V2.1+, delete this copy -- the
;                    assembler will flag the duplicate label -- and re-apply
;                    or upstream the M2M-UPSTREAM interlace patch.
;
; Input:  R8 = pointer to a 256-word horizontal coefficient table
;         R9 = pointer to a 256-word vertical   coefficient table
; Output: -
; ----------------------------------------------------------------------------

M2M$LOAD_POLYPHASE  SYSCALL(enter, 1)

                ; select the ascal Polyphase RAM device
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    M2M$ASCAL_PPHASE, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0

                MOVE    ASCAL_FILTER_LEN, R10

                ; copy horizontal filter (R8 already = H label) to PP_HORIZ
                MOVE    R9, R0                  ; stash V pointer
                MOVE    M2M$RAMROM_DATA, R9
                ADD     M2M$ASCAL_PP_HORIZ, R9
                SYSCALL(memcpy, 1)

                ; copy vertical filter (R0 = stashed V label) to PP_VERT.
                MOVE    R0, R8
                MOVE    M2M$RAMROM_DATA, R9
                ADD     M2M$ASCAL_PP_VERT, R9
                SYSCALL(memcpy, 1)

                SYSCALL(leave, 1)
                RET

; Filter coefficient blobs for the polyphase-based options that the M2M
; framework does not already link: LANCZOS2_12 and SCAN_BR_110_80 come in
; via M2M/rom/filters.asm (included from M2M/rom/shell.asm); the three blobs
; below are core-local copies from C64MEGA65 V6 (see video_filters/README.md).
#include "video_filters/GS_Sharpness_050.asm"
#include "video_filters/CRT_Sim_Composite_H.asm"
#include "video_filters/CRT_Sim_SVideo_H.asm"

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; Menu group id of the " ADF:%s" mount item - MUST match OPTM_G_ADF in
; config.vhd (the Shell passes the plain group id to the callbacks)
OPTM_G_ADF      .EQU    1

; Menu group id of the HDMI Filter radio - MUST match OPTM_G_FILTER in
; config.vhd
OPTM_G_FLT      .EQU    3

; OSM bit positions (zero-based OPTM_ITEMS line numbers in config.vhd) of the
; eight HDMI Filter options - MUST match the OPTM_ITEMS layout
OSM_FLT_NO_FILTER     .EQU 20
OSM_FLT_SHARP         .EQU 21
OSM_FLT_BICUBIC       .EQU 22
OSM_FLT_SMOOTH        .EQU 23
OSM_FLT_LANCZOS       .EQU 24
OSM_FLT_SCANLINES     .EQU 25
OSM_FLT_CRT_SVIDEO    .EQU 26
OSM_FLT_CRT_COMPOSITE .EQU 27

; ADF file extension (needs to be upper case)
ADF_FILE_EXT    .ASCII_W ".ADF"

; Warning: file size out of the valid ADF range
WRN_ADF_SIZE    .ASCII_P "\n\nThis is not a valid ADF disk image:\n"
                .ASCII_P "the file size must be 901,120 bytes\n"
                .ASCII_P "(880 KB standard ADF; 81..83-track over-\n"
                .ASCII_P "dumps up to 934,912 bytes are accepted)."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; This needs to be the last thing before the "Variables" sections starts
END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

;
; add your own variables here
;

; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 29696, then you write 29696-1024=28672
; instead, but when doing the sanity check calculations, you use 29696
MENU_HEAP_SIZE  .EQU 1024

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 6144                       ; 7168 - 1024 = 6144
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 28672                      ; 29696 - 1024 = 28672
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 29696 words to HEAP which
; is currently 0xXXXX and subtract the result from 0xFEE0. This yields
; currently a stack size of more than 1.5k words, which is sufficient
; for this program.

                .ORG    0xFEE0                  ; TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
