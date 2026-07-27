; ****************************************************************************
; Amiga for Mega65 (AExp) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
;
; The execution starts at the label START_FIRMWARE.
;
; done by sy2002 in 2026 and licensed under GPL v3
; ****************************************************************************

; NOTE on comment style: this file is fed to the C preprocessor (see the asm
; wrapper in M2M/QNICE/assembler, which runs cc -xc -E), so an apostrophe or a
; double-quote is tokenized even inside a ; comment. So, in comments:
;   * avoid genitive apostrophes; use an of-construction instead (the
;     sub-activity of the menu selection, not the possessive apostrophe-s form);
;   * never split a double-quoted string across two lines (keep it on one line;
;     a balanced pair on ONE line is fine).
; Either slip only yields a harmless missing-terminating preprocessor warning.

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

                ; Run the Shell and before that, initialize:
                ; a) ADF write-back state. It cannot live in PREP_START, as
                ;    HANDLE_CORE_IO can already be reached during boot
                ;    (HANDLE_IO is polled from boot-time wait loops), and RAM
                ;    variables are undefined at power-on.
                ; b) Screen-centering feature
                ; c) Real-Time-Clock connector
START_FIRMWARE  RSUB    ADF_WB_INIT, 1
                RSUB    SCR_INIT, 1
                RSUB    RTC_INIT, 1
                RBRA    START_SHELL, 1

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

                ; ADF context confirmed: BEFORE anything else, force-flush all
                ; unsaved writes of the currently mounted disk - the streaming
                ; that follows overwrites the HyperRAM image, and the Shell
                ; has already re-opened HANDLE_RM_FILE1 for the NEW file
                ; (which is exactly why the flush works from our own FDH
                ; snapshot, see FLUSH_ADF_STEP). Bounded to >4 full disks of
                ; chunks so an Amiga that re-dirties tracks forever cannot
                ; starve the OSM; in that case we bail out with a friendly,
                ; non-fatal message (the Shell re-opens the file browser).
                MOVE    R8, R3                  ; R3: handle of the new file
                MOVE    8192, R4                ; R4: chunk budget
_PREP_LI_FL     MOVE    1, R8                   ; forced step (ignore the
                RSUB    FLUSH_ADF_STEP, 1       ; anti-thrashing gate)
                CMP     0, R8                   ; clean and idle?
                RBRA    _PREP_LI_FLD, Z
                SUB     1, R4
                RBRA    _PREP_LI_FL, !Z
                MOVE    1, R8                   ; budget exhausted: bail out
                MOVE    WRN_ADF_BUSY, R9
                DECRB
                RET

                ; The mount flow OWNS the arm state: disarm the write-back
                ; here and let the PARSEST=READY of the NEW mount re-arm it
                ; with a fresh handle snapshot. HANDLE_CORE_IO alone cannot
                ; do that: the whole load runs without HANDLE_IO polling, so
                ; the READY -> LOADING -> READY transient of a re-mount is
                ; invisible to it - without this disarm, flushes after a disk
                ; swap would write the new disk into the OLD file.
_PREP_LI_FLD    MOVE    ADF_FDH_VALID, R4
                MOVE    0, @R4
                MOVE    ADF_MOUNT_SEEN, R4
                MOVE    0, @R4                  ; 0: a fresh READY may arm
                MOVE    ADF_FL_STATE, R4
                MOVE    0, @R4
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 0 until the new
                MOVE    AEXP_DEV_ADF, @R4       ; mount is complete
                MOVE    M2M$RAMROM_4KWIN, R4
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    0, @R4

                MOVE    R3, R8                  ; restore the file handle

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

                ; Apply the screen-centering offsets (HDMI ascal window) from
                ; /amiga/aexp_screen.cfg (zeros if absent) before the core
                ; un-resets so the first frame is already positioned.
                RSUB    LOAD_SCREEN_OFFSETS, 1

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

                ; issue #16: the sub-activity of the menu selection (file
                ; browser / help viewer) has returned - drop the gate-4 flag so
                ; SPACE-unmount works again. Reached on EVERY non-fatal path out
                ; of OPTM_CB_SEL (incl. the CLOSE early-out via _OPTMCB_RET), so
                ; the flag can never stick at 1. R8 (the selected group, used
                ; below) is untouched: R0 is bank-local after the INCRB.
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    0, @R0

                ; HDMI Filter selection changed: re-push the matching (H, V)
                ; coefficient pair into the ascal polyphase RAM. NO core
                ; reset -- only the coefficient RAM content changes; the
                ; Amiga keeps running. The user sees the new filter from the
                ; next frame.
                CMP     AEXP_OPTM_G_FILTER, R8
                RBRA    _OSM_SP_SCR, !Z
                RSUB    LOAD_HDMI_FILTER, 1
                RBRA    _OSM_SEL_POST_R, 1

                ; "Reload Screen Config" pressed. This is a MOMENTARY action,
                ; not an on/off toggle (issue #19): show <Loading Screen Config>
                ; on the line of the item for the ~1-2 s the SD re-mount +
                ; reload takes -- the OSM is frozen meanwhile because QNICE
                ; serves the menu synchronously -- then repaint the original
                ; label with no "=" checkmark left behind.
_OSM_SP_SCR     CMP     AEXP_OPTM_G_SCRRELOAD, R8
                RBRA    _OSM_SEL_POST_R, !Z

                ; Paint the "loading" label. OPTM_CUR_SEL is the flat index of
                ; the highlighted item; the menu is flat-indexed but on-screen
                ; rows collapse submenus, so translate to the visible row first
                ; (_OPTM_R_F2M_O is the same "from the outside" helper OPTM_SET
                ; / OPTM_SELECT use). Then print across the full content width
                ; at the left edge (x = OPTM_X+1, y = OPTM_Y+row+1).
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_F_MS_SLCT, R9      ; fatal-context (unused on OK)
                RSUB    _OPTM_R_F2M_O, 1        ; R8 = row; C=1 -> off this level
                RBRA    _OSP_SCR_RM, C          ; (defensive) skip paint if so
                MOVE    OPTM_Y, R10
                MOVE    @R10, R10
                ADD     R8, R10
                ADD     1, R10                  ; R10 = screen y (+1 for frame)
                MOVE    OPTM_X, R9
                MOVE    @R9, R9
                ADD     1, R9                   ; R9 = screen x (+1 for frame)
                MOVE    SCR_LOADING_STR, R8
                RSUB    SCR$PRINTSTRXY, 1

                ; The user may have pulled the SD card to write a new file with
                ; the python tool; the shared SD controller is then de-negotiated
                ; until a re-mount runs SD$RESET (and a same-slot tray swap does
                ; NOT reliably raise SD_CHANGED on R3, so we cannot gate on it).
                ; Re-mount CONFIG_DEVH here, mirroring the remount of the file
                ; browser, so the reload reads the CURRENT card and not the
                ; stale boot mount. Safe for config-save: write-back is gated on
                ; CONFIG_FILE (untouched), and re-mounting keeps the bookkeeping
                ; of CONFIG_DEVH consistent with the freshly reset controller.
_OSP_SCR_RM     MOVE    CONFIG_DEVH, R8
                CMP     0, @R8                  ; any SD device mounted at all?
                RBRA    _OSP_SCR_LOAD, Z        ; none -> let LOAD zero the table
                RSUB    WAIT1SEC, 1             ; debounce a just-reinserted card
                MOVE    CONFIG_DEVH, R8
                MOVE    1, R9                   ; partition #1 (framework-wide)
                SYSCALL(f32_mnt_sd, 1)          ; SD$RESET + re-read geometry;
                                                ; LOAD then re-checks status
_OSP_SCR_LOAD   RSUB    LOAD_SCREEN_OFFSETS, 1

                ; Momentary reset: clear the single-select state everywhere so
                ; no "=" ever sticks. M2M$FORCE_MENU clears the QNICE setting
                ; register bit AND the in-memory selection of the menu (and
                ; erases the on-screen marker); OPTM_SHOW then repaints every
                ; label (ours reverts to "Reload Screen Config", markerless) and
                ; OPTM_SELECT restores the cursor highlight. OPTM_CUR_SEL is
                ; untouched by these calls, so it still points at our item.
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                XOR     R9, R9                  ; 0 = unselected
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1
                RBRA    _OSM_SEL_POST_R, 1

                ; (the Configure Drives combo radio needs NO handling here:
                ; the HDL cold-boots the Amiga on its own, and the df0:/df1:
                ; labels of menu lines 2+3 are healed by HWF_LABEL_SYNC from
                ; HANDLE_CORE_IO, which also ticks inside the submenu's
                ; key-wait loop - see the routine's header)

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

                ; issue #16: a sub-activity of a menu selection is about to run
                ; (the file browser, its SD-mount retry / "press Space"
                ; acknowledgments, or the WHS help viewer) and it polls
                ; HANDLE_IO. Raise the gate-4 flag so HANDLE_UNMOUNT_KEY does
                ; not mistake a SPACE inside one of those sub-screens - e.g.
                ; Return-to-replace on the still-mounted ' ADF:' line - for an
                ; unmount request. Cleared again in OSM_SEL_POST, which brackets
                ; the whole select-callback body (options.asm OPTM_CB_SEL).
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    1, @R0

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
; ADF write-back: background flush of Amiga-written tracks to the SD card
;
; The track engine (CORE/vhdl/adf_track_engine.vhd) MFM-decodes Amiga writes
; and commits verified sectors into the ADF image in HyperRAM; the mount
; wrapper (CORE/vhdl/adf_mount_wrapper.vhd) collects the affected tracks in
; a dirty bitmap behind window ADF_WBC_4KWIN of device AEXP_DEV_ADF and runs
; the vdrives-style anti-thrashing countdown. The firmware side below mirrors
; the proven C64MEGA65 vdrives discipline (background flushing driven from
; HANDLE_IO, chunked to stay responsive, still-open FAT32 handle, errors are
; fatal) against our non-vdrives device. Full design:
; doc/floppy-adf.md
; ----------------------------------------------------------------------------

; ADF_WB_INIT: called once from START_FIRMWARE, before the Shell starts.
; Zero-initializes the write-back state and loads VD_ANTI_THRASHING_DELAY
; from config.vhd into the WBC hardware countdown register (mirrors the
; vdrives VD_INIT pattern, M2M/rom/vdrives.asm).
ADF_WB_INIT     INCRB

                MOVE    ADF_FDH_VALID, R0
                MOVE    0, @R0
                MOVE    ADF_MOUNT_SEEN, R0
                MOVE    0, @R0
                MOVE    ADF_FL_STATE, R0
                MOVE    0, @R0

                ; issue #16 unmount state: no SPACE seen yet and no menu
                ; sub-activity running. Seeded here (like the rest of the ADF
                ; state) because HANDLE_IO can poll HANDLE_UNMOUNT_KEY during
                ; boot wait loops, before RAM is otherwise written.
                MOVE    ADF_UNMNT_PREV, R0
                MOVE    0, @R0
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    0, @R0

                MOVE    M2M$RAMROM_DEV, R0      ; anti-thrashing delay (ms)
                MOVE    M2M$CONFIG, @R0         ; from config.vhd
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    M2M$CFG_GENERAL, @R0
                MOVE    M2M$CFG_VD_AT_DELAY, R0
                MOVE    @R0, R1

                MOVE    M2M$RAMROM_DEV, R0      ; ... into the WBC register
                MOVE    AEXP_DEV_ADF, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    ADF_WBC_4KWIN, @R0
                MOVE    ADF_WBC_ATDELAY, R0
                MOVE    R1, @R0

                DECRB
                RET

; SCR_INIT: called once from START_FIRMWARE, before the Shell starts. Puts the
; screen-centering runtime state (issue #5) into a safe boot state, so a
; DETECT_SCREEN_MODE poll from a boot-time wait loop (HANDLE_IO is polled before
; PREP_START runs LOAD_SCREEN_OFFSETS, and RAM is undefined at power-on) can never
; act on undefined state: the debounce latch says "nothing applied", and the table
; is inert (0,0,0,0 = no centering) until LOAD_SCREEN_OFFSETS reads the SD file.
SCR_INIT        INCRB
                MOVE    SCR_APPLIED_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0
                MOVE    SCR_TICK, R0
                MOVE    0, @R0
                MOVE    SCR_TABLE, R0
                MOVE    SCR_TABLE_WORDS, R1
_SCR_INIT_L     MOVE    0, @R0++
                SUB     1, R1
                RBRA    _SCR_INIT_L, !Z
                DECRB
                RET

; RTC_INIT: called once from START_FIRMWARE, before the Shell starts (like
; ADF_WB_INIT - RAM variables are undefined at power-on). Primes the minute-edge
; detector with a sentinel so the first minute change reseeds the Amiga clock.
RTC_INIT        INCRB
                MOVE    RTC_LAST_MIN, R0
                MOVE    0xFFFF, @R0
                DECRB
                RET

; RTC_STEP: one non-blocking step of the battery-RTC reseed (issue #13).
;
; The Minimig $DC0000 clock (minimig.v) advances minutes/hours/date only when the
; framework flips the RTC "new value" toggle, which it does when an external I2C
; RTC read completes (M2M/vhdl/i2c/rtc_controller.vhd). The framework issues that
; read only at reset, so the Amiga clock would freeze ~1 minute after the boot
; seed (minimig free-runs its seconds field but never carries into minutes). This
; re-issues the read once per real minute - aligned to the :00 boundary by
; edge-detecting the free-running internal-minute register - which reseeds
; minimig with fresh time and restarts its in-FPGA seconds counter from 0. This
; is the MiSTer "HPS resend once per minute" cadence.
;
; The minute register is read WITHOUT flipping the toggle (only a command-byte
; write does), so the common path is just a couple of cheap device reads. The
; command byte is accepted only while I2C is idle, so a still-running read (e.g.
; the boot read) simply defers to the next call.
;
; Expects the caller to tolerate a changed RAMROM device selection (HANDLE_CORE_IO
; saves and restores it around this call). Input/Output: none.
RTC_STEP        INCRB
                MOVE    M2M$RAMROM_DEV, R0      ; select the framework RTC device
                MOVE    AEXP_DEV_RTC, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    RTC_4KWIN, @R0

                MOVE    RTC_COMMAND, R0         ; defer while an I2C read runs
                MOVE    @R0, R1
                AND     1, R1
                RBRA    _RTC_RET, !Z

                MOVE    RTC_MINUTES, R0         ; free-running internal minute
                MOVE    @R0, R0                 ; (BCD, high byte already 0)
                MOVE    RTC_LAST_MIN, R1
                CMP     @R1, R0
                RBRA    _RTC_RET, Z             ; same minute: nothing to do

                MOVE    R0, @R1                 ; remember this minute
                MOVE    RTC_COMMAND, R0         ; reseed: stop, then read+restart
                MOVE    RTC_CMD_STOP, @R0       ; b3=0: stop the internal timer
                MOVE    RTC_CMD_RESYNC, @R0     ; b1=read + b3=run: the external
                                                ; read flips the toggle and
                                                ; minimig reseeds $DC0000

_RTC_RET        DECRB
                RET

; HANDLE_CORE_IO callback function:
;
; Called from HANDLE_IO in every iteration of the main loop and of all
; blocking wait loops - see the M2M-UPSTREAM core-io-hook contract in
; M2M/rom/shell.asm. AExp uses the time slice to run the ADF write-back:
;
;   1. SD-card-change guard: a swapped card invalidates the retained file
;      handle - disable write-back and discard the dirty state (the
;      ROSM_INTEGRITY precedent: never write to a card we did not open on).
;   2. Mount tracking: when a mount reaches PARSEST=READY, snapshot the
;      Shell handle HANDLE_RM_FILE1 into our own FDH (the Shell re-opens
;      that struct for the NEXT load before PREP_LOAD_IMAGE even runs!) and arm
;      the write-back: WBC WR_EN=1 makes the track engine announce df0 as
;      writable to the Amiga.
;   3. One background flush step (respects the anti-thrashing gate).
;
; Input/Output: none; all registers are preserved
HANDLE_CORE_IO  SYSCALL(enter, 1)

                ; ADF unmount with SPACE (issue #16): must run FIRST and on
                ; EVERY poll. HANDLE_IO calls us at the top of every OSM
                ; key-wait iteration, before the KEYB$SCAN of that loop - the
                ; ordering that lets us both suppress the SPACE of the menu (so
                ; it never becomes a mount) and, on a fresh press over the
                ; highlighted ' ADF:' line, eject the disk. Cheap in the common
                ; path (OSM closed) and RAMROM-transparent.
                RSUB    HANDLE_UNMOUNT_KEY, 1

                ; screen centering (issue #5): throttle the mode detector. A mode
                ; change only needs to be reacted to within a few ms, so run
                ; DETECT_SCREEN_MODE once every SCR_TICK_MASK+1 poll-loop
                ; iterations instead of every one -- the detector is ~80 instr
                ; and this callback is polled in the tightest loops (incl. the
                ; ADF write-back below). Skipped iterations pay only this
                ; ~4-instruction counter. On a change the detector re-centers
                ; within (SCR_DEBOUNCE+2) detects, i.e. a few tens of ms.
                MOVE    SCR_TICK, R4
                ADD     1, @R4
                MOVE    @R4, R5
                AND     SCR_TICK_MASK, R5
                RBRA    _HCIO_NODET, !Z
                RSUB    DETECT_SCREEN_MODE, 1     ; detect + apply on a mode change
                RSUB    HWF_LABEL_SYNC, 1         ; heal the df0:/df1: menu labels
                                                  ; (same 1/8 cadence; RAMROM-
                                                  ; transparent like the detector)

                ; be transparent about the active RAMROM device selection
_HCIO_NODET     MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R1
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3

                ; --- 1. SD guards: a shell-detected card change OR an
                ;        active-slot switch. The file browser F1/F3 switch
                ;        updates SD_ACTIVE WITHOUT raising SD_CHANGED, so the
                ;        slot the handle was snapshotted on is compared, too.
                MOVE    SD_CHANGED, R4
                CMP     1, @R4
                RBRA    _HCIO_KILL, Z
                MOVE    ADF_FDH_VALID, R4       ; slot check only when armed
                CMP     1, @R4
                RBRA    _HCIO_MOUNT, !Z
                MOVE    M2M$CSR, R4
                MOVE    @R4, R4
                AND     M2M$CSR_SD_ACTIVE, R4
                MOVE    ADF_SD_SLOT, R5
                CMP     @R5, R4
                RBRA    _HCIO_MOUNT, Z

_HCIO_KILL      MOVE    ADF_FDH_VALID, R4       ; already disabled: done
                CMP     0, @R4
                RBRA    _HCIO_RET, Z
                MOVE    0, @R4                  ; invalidate the FDH snapshot
                MOVE    ADF_MOUNT_SEEN, R4      ; 1: BLOCK re-arming from the
                MOVE    1, @R4                  ; STALE PARSEST=READY of the
                                                ; old mount - the next ADF
                                                ; load (PREP_LOAD_IMAGE)
                                                ; re-enables arming
                MOVE    ADF_FL_STATE, R4        ; abort a running session
                MOVE    0, @R4
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 0 (df0 reverts to
                MOVE    AEXP_DEV_ADF, @R4       ; write-protected) and wipe
                MOVE    M2M$RAMROM_4KWIN, R4    ; the whole dirty bitmap
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    0, @R4
                MOVE    ADF_WBC_DIRTY0, R4
                MOVE    11, R5
_HCIO_WIPE      MOVE    0xFFFF, @R4++           ; write-1-to-clear
                SUB     1, R5
                RBRA    _HCIO_WIPE, !Z
                RBRA    _HCIO_RET, 1

                ; --- 2. mount tracking (PARSEST=READY rising edge) ---
_HCIO_MOUNT     MOVE    AEXP_DEV_ADF, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1         ; R10: parse status
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _HCIO_NOMNT, !Z
                MOVE    ADF_MOUNT_SEEN, R4
                CMP     1, @R4
                RBRA    _HCIO_FLUSH, Z          ; this mount is already armed
                MOVE    1, @R4
                MOVE    HANDLE_RM_FILE1, R8     ; snapshot the file handle
                MOVE    ADF_FDH, R9
                MOVE    FAT32$FDH_STRUCT_SIZE, R10
                SYSCALL(memcpy, 1)
                MOVE    ADF_FDH_VALID, R4
                MOVE    1, @R4
                MOVE    ADF_FL_STATE, R4
                MOVE    0, @R4
                MOVE    M2M$CSR, R4             ; remember the active SD slot
                MOVE    @R4, R4                 ; the snapshot was taken on
                AND     M2M$CSR_SD_ACTIVE, R4   ; (see the SD guards above)
                MOVE    ADF_SD_SLOT, R5
                MOVE    R4, @R5
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 1
                MOVE    AEXP_DEV_ADF, @R4
                MOVE    M2M$RAMROM_4KWIN, R4
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    1, @R4
                RBRA    _HCIO_FLUSH, 1

_HCIO_NOMNT     MOVE    ADF_MOUNT_SEEN, R4      ; re-arm the edge detection
                MOVE    0, @R4                  ; for the next mount

                ; --- 3. one background flush step ---
_HCIO_FLUSH     XOR     R8, R8                  ; 0 = respect anti-thrashing
                RSUB    FLUSH_ADF_STEP, 1

                ; keep the Amiga battery clock live (issue #13): re-issue the
                ; framework RTC read once per minute so the Minimig $DC0000 clock
                ; advances instead of freezing after the boot seed
                RSUB    RTC_STEP, 1

_HCIO_RET       MOVE    R1, @R0                 ; restore RAMROM selection
                MOVE    R3, @R2
                SYSCALL(leave, 1)
                RET

; FLUSH_ADF_STEP: one resumable step of the ADF write-back
;
; Cooperative multitasking, mirroring the vdrives FLUSH_CACHE discipline
; (M2M/rom/shell.asm): one call does at most one of
;   * idle, dirty tracks pending, gate open (or forced): pick the LOWEST
;     dirty track, clear its bit FIRST (write-1-to-clear; a concurrent
;     re-write by the Amiga re-sets it, so the track is re-flushed - torn
;     reads self-heal), f32_fseek the retained handle to track * 5632
;   * active session: stream ADF_FLUSH_CHUNK bytes from the ADF byte window
;     to f32_fwrite, then f32_fflush the chunk; at track end close the session
;
; The chunk is 512 bytes and every track start is 512-aligned, so chunks
; never cross a 4k device window and cover exactly one FAT32 sector - and
; each chunk is EXPLICITLY flushed before returning: the SD controller has a
; single hardware sector buffer shared with every other SD user (the OSM
; settings save runs from the very wait loops that also poll us!), so no
; dirty buffered sector may ever survive across time slices. The explicit
; flush costs nothing: the sector is written exactly once either way.
; FAT32 errors are fatal - the C64MEGA65 FLUSH_CACHE policy; SD removal is
; pre-guarded by the SD-change check in HANDLE_CORE_IO.
;
; Expects the caller to tolerate a changed RAMROM device selection.
;
; Input:
;   R8: 0=respect the anti-thrashing gate (background), 1=force (flush now)
; Output:
;   R8: 0=clean and idle (nothing left to do), 1=dirty work remains
FLUSH_ADF_STEP  INCRB
                MOVE    R9, R0                  ; preserve R9..R12
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R8, R4                  ; R4: force flag

                MOVE    M2M$RAMROM_DEV, R8      ; select the WBC window
                MOVE    AEXP_DEV_ADF, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    ADF_WBC_4KWIN, @R8

                MOVE    ADF_FL_STATE, R8        ; session active?
                CMP     1, @R8
                RBRA    _FADF_CHUNK, Z

                MOVE    ADF_WBC_STAT, R8        ; idle: any dirty tracks?
                MOVE    @R8, R8
                AND     1, R8
                RBRA    _FADF_RET0, Z           ; clean and idle: done

                MOVE    ADF_FDH_VALID, R8       ; without a handle we can
                CMP     1, @R8                  ; never flush: discard (only
                RBRA    _FADF_DISCARD, !Z       ; reachable defensively)

                CMP     1, R4                   ; forced?
                RBRA    _FADF_PICK, Z
                MOVE    ADF_WBC_STAT, R8        ; anti-thrashing gate: only
                MOVE    @R8, R8                 ; start a track after the
                AND     2, R8                   ; hardware countdown expired
                RBRA    _FADF_RET1, Z           ; gated: work remains

                ; pick the lowest dirty track: first non-zero bitmap word,
                ; then its lowest set bit
_FADF_PICK      MOVE    ADF_WBC_DIRTY0, R5      ; R5: bitmap word address
                XOR     R6, R6                  ; R6: word index 0..10
_FADF_FWORD     CMP     0, @R5
                RBRA    _FADF_FBIT, !Z
                ADD     1, R5
                ADD     1, R6
                CMP     11, R6
                RBRA    _FADF_FWORD, !Z
                RBRA    _FADF_RET0, 1           ; raced to clean: done

_FADF_FBIT      MOVE    @R5, R7                 ; R7: bitmap word value
                MOVE    1, R8                   ; R8: bit mask
                XOR     R9, R9                  ; R9: bit index
_FADF_FBIT1     MOVE    R7, R10
                AND     R8, R10
                RBRA    _FADF_FOUND, !Z
                AND     0xFFFD, SR              ; clear X: shift in zeros
                SHL     1, R8
                ADD     1, R9
                RBRA    _FADF_FBIT1, 1

_FADF_FOUND     MOVE    R8, @R5                 ; W1C the bit FIRST
                MOVE    R6, R10                 ; track = word * 16 + bit
                AND     0xFFFD, SR
                SHL     4, R10
                ADD     R9, R10                 ; R10: track number

                XOR     R11, R11                ; byte addr = track * 5632
                XOR     R12, R12                ; (32 bit, iterative add -
                CMP     0, R10                  ; QNICE has no multiplier;
                RBRA    _FADF_SEEK, Z           ; <= 165 iterations)
_FADF_MUL       ADD     ADF_TRACK_BYTES, R11
                ADDC    0, R12
                SUB     1, R10
                RBRA    _FADF_MUL, !Z

_FADF_SEEK      MOVE    ADF_FL_BADDR_LO, R8     ; open the session
                MOVE    R11, @R8
                MOVE    ADF_FL_BADDR_HI, R8
                MOVE    R12, @R8
                MOVE    ADF_FL_REMAIN, R8
                MOVE    ADF_TRACK_BYTES, @R8
                MOVE    ADF_FDH, R8             ; seek to the track start
                MOVE    R11, R9                 ; (file offset = image offset)
                MOVE    R12, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                MOVE    ADF_FL_STATE, R8
                MOVE    1, @R8
                RBRA    _FADF_RET1, 1           ; chunks stream on later calls

                ; active session: stream one chunk. window = byte addr >> 12,
                ; offset = byte addr & 0xFFF (one file byte per window word)
_FADF_CHUNK     MOVE    ADF_FL_BADDR_HI, R8
                MOVE    @R8, R5
                AND     0xFFFD, SR              ; clear X: shift in zeros
                SHL     4, R5
                MOVE    ADF_FL_BADDR_LO, R8
                MOVE    @R8, R6                 ; R6: byte addr, low word
                MOVE    R6, R7
                AND     0xFFFB, SR              ; clear C: shift in zeros
                SHR     12, R7
                OR      R7, R5                  ; R5: 4k window number
                MOVE    M2M$RAMROM_4KWIN, R8    ; (device already selected)
                MOVE    R5, @R8
                MOVE    R6, R7
                AND     0x0FFF, R7
                ADD     M2M$RAMROM_DATA, R7     ; R7: source pointer
                MOVE    ADF_FLUSH_CHUNK, R5     ; R5: byte countdown
_FADF_WLOOP     MOVE    ADF_FDH, R8
                MOVE    @R7++, R9               ; one file byte per word
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                SUB     1, R5
                RBRA    _FADF_WLOOP, !Z

                ; persist the chunk NOW: the FAT32 hardware sector buffer is
                ; shared with every other SD user (e.g. the OSM settings
                ; save) - a dirty buffered sector left across time slices
                ; would be clobbered by them. This costs nothing: the chunk
                ; is exactly one sector, which gets written exactly once
                ; either way - just earlier.
                MOVE    ADF_FDH, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z

                MOVE    ADF_FL_BADDR_LO, R8     ; advance the byte address
                ADD     ADF_FLUSH_CHUNK, @R8
                MOVE    ADF_FL_BADDR_HI, R8
                ADDC    0, @R8
                MOVE    ADF_FL_REMAIN, R8
                SUB     ADF_FLUSH_CHUNK, @R8
                RBRA    _FADF_RET1, !Z          ; track not finished yet

                MOVE    ADF_FL_STATE, R8        ; track done: session closed
                MOVE    0, @R8
                MOVE    M2M$RAMROM_4KWIN, R8    ; more dirty tracks?
                MOVE    ADF_WBC_4KWIN, @R8
                MOVE    ADF_WBC_STAT, R8
                MOVE    @R8, R8
                AND     1, R8
                RBRA    _FADF_RET0, Z
                RBRA    _FADF_RET1, 1

_FADF_DISCARD   MOVE    ADF_WBC_DIRTY0, R5      ; drop unflushable dirty bits
                MOVE    11, R6
_FADF_DISC1     MOVE    0xFFFF, @R5++
                SUB     1, R6
                RBRA    _FADF_DISC1, !Z
                RBRA    _FADF_RET0, 1

_FADF_RET0      XOR     R8, R8
                RBRA    _FADF_RET, 1
_FADF_RET1      MOVE    1, R8
_FADF_RET       MOVE    R0, R9                  ; restore R9..R12
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

_FADF_FATAL     MOVE    ERR_ADF_FLUSH, R8       ; R9 holds the FAT32 error
                RBRA    FATAL, 1

; ----------------------------------------------------------------------------
; ADF unmount with SPACE (issue #16)
;
; Mirrors the C64 gesture: with the OSM open and the cursor on the ' ADF:'
; line, SPACE ejects the disk (df0 goes empty, the menu label reverts to
; "<Load>"). The framework has NO unmount path for CRT/ROM devices
; (HANDLE_MOUNTING always opens the browser for CRT/ROM mode, shell.asm) and
; M2M must not be modified, so we intercept the key core-side. HANDLE_IO calls
; HANDLE_CORE_IO - and thus HANDLE_UNMOUNT_KEY - at the TOP of every OSM
; key-wait iteration, BEFORE the KEYB$SCAN of that loop (options.asm). That
; ordering lets us both suppress the SPACE of the menu (so it never becomes a
; mount) and fire the eject ourselves. Full design + adversarial review:
; .research/INTEGRATION-SPEC-adf-unmount.md
;
; Five gates must all hold to act:
;   1  OSM open            M2M$CSR bit M2M$CSR_OSM (else SPACE is for the Amiga)
;   4  not a sub-activity  OSM_SUB_ACTIVE == 0 (the browser/help set it; this
;                          is what keeps a SPACE on a browser "press Space"
;                          screen reached via Return-to-replace from ejecting)
;   2  ' ADF:' highlighted OPTM_CUR_SEL == the flat menu index of the ADF item
;   3  ADF mounted         PARSEST == PT_OK (else let SPACE fall through and
;                          mount, matching the SPACE-on-empty-drive of the C64)
;   5  fresh SPACE edge    via the ADF_UNMNT_PREV latch (one act per press)
;
; Gates 1+4 read only absolute MMIO / RAM (no device window), so the common path
; (OSM closed) is cheap and leaves the RAMROM selection untouched. Only once we
; pass gate 4 do we snapshot RAMROM (R6/R7) and switch devices for gates 2/3 and
; the eject; _HUK_RET restores it so HANDLE_CORE_IO stays transparent to its
; caller. While gates 1-4 hold we suppress the SPACE of the menu EVERY iteration
; (race-free vs. the edge detector of KEYB$SCAN) and eject only on the gate-5
; rising edge.
;
; Input/Output: none. Bank-local R0-R7; clobbers global R8-R10 (HANDLE_CORE_IO
; has no live upper registers at its top and reloads them at first use).
; ----------------------------------------------------------------------------
HANDLE_UNMOUNT_KEY INCRB

                ; read current SPACE state (M2M$KEYBOARD is low-active) and
                ; update the edge latch UNCONDITIONALLY every call (OSM open or
                ; closed), so opening the OSM with SPACE held cannot fake an edge
                MOVE    M2M$KEYBOARD, R0
                MOVE    @R0, R0
                NOT     R0, R0                  ; low-active -> high-active
                AND     M2M$KEY_SPACE, R0
                MOVE    R0, R4                  ; R4 = 0x20 pressed / 0 released
                MOVE    ADF_UNMNT_PREV, R1
                MOVE    @R1, R5                 ; R5 = SPACE state last poll
                MOVE    R4, @R1                 ; latch := current

                ; --- gate 1: OSM open? (closed -> SPACE belongs to the Amiga)
                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_OSM, R0
                RBRA    _HUK_RET_NS, Z

                ; --- gate 4: inside a menu-item sub-activity (browser/help)? ---
                MOVE    OSM_SUB_ACTIVE, R0
                CMP     0, @R0
                RBRA    _HUK_RET_NS, !Z

                ; from here on we switch the RAMROM device; snapshot it first
                ; so _HUK_RET can hand HANDLE_CORE_IO back the selection intact
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R6
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    @R0, R7

                ; --- gate 2: is the ' ADF:' line highlighted? ---
                ; CRTROM_M_GI(R8=0) -> R9 = the flat menu index of the ADF item
                ; (Carry=1 if found); OPTM_CUR_SEL is the live highlight in the
                ; same flat coordinate. (CRTROM_M_GI selects M2M$CONFIG; gate 3
                ; re-selects, and _HUK_RET restores the selection of the
                ; caller.)
                XOR     R8, R8                  ; CRT/ROM id 0 = the ADF item
                RSUB    CRTROM_M_GI, 1
                RBRA    _HUK_RET, !C            ; no CRT/ROM item -> bail (defensive)
                MOVE    OPTM_CUR_SEL, R0
                CMP     @R0, R9                 ; highlighted item == ADF item?
                RBRA    _HUK_RET, !Z            ; other line -> bail

                ; --- gate 3: is the ADF mounted? PARSEST == PT_OK ---
                MOVE    AEXP_DEV_ADF, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1         ; R10 = parse status
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _HUK_RET, !Z            ; empty drive -> let SPACE mount

                ; in context: suppress the SPACE of the menu this iteration,
                ; BEFORE KEYB$SCAN runs. The rising edge of KEYB$SCAN is
                ; (pressed AND NOT KEYB_PRESSED), so pre-setting the SPACE bit
                ; kills the edge -> KEYB$GETKEY never returns SPACE ->
                ; OPTM_CB_SEL / HANDLE_MOUNTING never fire for it. Done on every
                ; in-context poll (not only our own edge), so it is immune to
                ; the read skew between our M2M$KEYBOARD read and the menu read.
                MOVE    KEYB_PRESSED, R0
                OR      M2M$KEY_SPACE, @R0

                ; --- gate 5: act once per physical press (rising edge) ---
                CMP     0, R4                   ; SPACE pressed now?
                RBRA    _HUK_RET, Z
                CMP     0, R5                   ; ..released last poll?
                RBRA    _HUK_RET, !Z            ; still held -> already handled
                RSUB    ADF_UNMOUNT, 1          ; eject + flush + disarm

_HUK_RET        MOVE    M2M$RAMROM_DEV, R0      ; restore the RAMROM selection
                MOVE    R6, @R0                 ; (keeps HANDLE_CORE_IO
                MOVE    M2M$RAMROM_4KWIN, R0    ;  transparent to its caller)
                MOVE    R7, @R0
_HUK_RET_NS     DECRB
                RET

; ADF_UNMOUNT: eject the mounted ADF, then flush + disarm the write-back.
;
; Order matters: eject FIRST so the Amiga sees df0 vanish and stops writing,
; THEN flush the already-committed dirty tracks (the eject leaves the HyperRAM
; image intact), THEN disarm. This mirrors the flush+disarm of PREP_LOAD_IMAGE;
; the disarm block is intentionally duplicated rather than shared, to keep the
; not-yet-HW-verified write path (PREP_LOAD_IMAGE) byte-identical for this
; milestone. Switches the RAMROM device; the caller (HANDLE_UNMOUNT_KEY)
; restores it.
;
; Input/Output: none. Bank-local R0; clobbers global R8-R10.
ADF_UNMOUNT     INCRB

                ; 1. eject: STATUS := ST_IDLE on the ADF device. The validator
                ; (adf_mount_wrapper.vhd p_validate, VS_DONE) sees req_status /=
                ; REQ_OK and drops disk_mounted; the track engine announces df0
                ; empty within ~1 ms. STATUS/PARSEST -> IDLE also makes the
                ; Shell revert the ' ADF:' menu label for free via
                ; CRTROM_MLST_GET (same mechanism as ST_LDNG at the start of
                ; every load).
                MOVE    AEXP_DEV_ADF, R8
                MOVE    CRTROM_CSR_STATUS, R9
                MOVE    CRTROM_CSR_ST_IDLE, R10
                RSUB    CRTROM_CSR_W, 1

                ; 2. force-flush all dirty tracks (bounded, ignore the anti-
                ;    thrashing gate). FLUSH_ADF_STEP streams from our own FDH
                ;    snapshot and does not depend on disk_mounted, so it still
                ;    works after the eject. On a clean/unarmed disk (the common
                ;    read-only case) the first step returns 0 at once. On budget
                ;    exhaustion we leave armed and let the background flush
                ;    finish later (benign: df0 already shows empty).
                ;
                ; First apply the SAME card-change guard that the SD guard of
                ; HANDLE_CORE_IO uses (SD_CHANGED, or an active-slot switch
                ; while armed): a swapped/pulled card makes the retained FDH
                ; stale, and flushing to it would write the old disk into the
                ; new card (the ROSM_INTEGRITY rule) - and the FAT32 errors of
                ; FLUSH_ADF_STEP are FATAL. We run BEFORE that SD guard (RSUB-ed
                ; first in HANDLE_CORE_IO), so an eject in the card-change
                ; window would otherwise crash. On a change, DISCARD the dirty
                ; bitmap (mirrors _HCIO_KILL) instead of flushing, then disarm.
                MOVE    SD_CHANGED, R0
                CMP     1, @R0
                RBRA    _ADF_UM_DROP, Z
                MOVE    ADF_FDH_VALID, R0       ; slot check only when armed
                CMP     1, @R0
                RBRA    _ADF_UM_FLUSH, !Z       ; not armed -> flush is a no-op
                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_SD_ACTIVE, R0
                MOVE    ADF_SD_SLOT, R1
                CMP     @R1, R0
                RBRA    _ADF_UM_FLUSH, Z        ; same slot -> safe to flush

_ADF_UM_DROP    MOVE    M2M$RAMROM_DEV, R0      ; card changed: drop the dirty
                MOVE    AEXP_DEV_ADF, @R0       ; bitmap (write-1-to-clear) so a
                MOVE    M2M$RAMROM_4KWIN, R0    ; later mount cannot flush stale
                MOVE    ADF_WBC_4KWIN, @R0      ; tracks into the new file, then
                MOVE    ADF_WBC_DIRTY0, R0      ; fall through to disarm
                MOVE    11, R1
_ADF_UM_WIPE    MOVE    0xFFFF, @R0++
                SUB     1, R1
                RBRA    _ADF_UM_WIPE, !Z
                RBRA    _ADF_UM_DIS, 1

_ADF_UM_FLUSH   MOVE    8192, R0                ; chunk budget (> 4 full disks)
_ADF_UM_FL      MOVE    1, R8                   ; forced step
                RSUB    FLUSH_ADF_STEP, 1
                CMP     0, R8                   ; clean and idle?
                RBRA    _ADF_UM_DIS, Z
                SUB     1, R0
                RBRA    _ADF_UM_FL, !Z
                RBRA    _ADF_UM_RET, 1          ; budget gone: leave armed

                ; 3. disarm the write-back (mirrors PREP_LOAD_IMAGE): the
                ; PARSEST=READY of a later genuine mount re-arms it with a fresh
                ; handle snapshot. PARSEST is IDLE now, so _HCIO_MOUNT will not
                ; re-arm regardless; ADF_MOUNT_SEEN:=0 is the correct clean
                ; state for the next mount.
_ADF_UM_DIS     MOVE    ADF_FDH_VALID, R0
                MOVE    0, @R0
                MOVE    ADF_MOUNT_SEEN, R0
                MOVE    0, @R0
                MOVE    ADF_FL_STATE, R0
                MOVE    0, @R0
                MOVE    M2M$RAMROM_DEV, R0      ; WR_EN := 0 (df0 write-protected)
                MOVE    AEXP_DEV_ADF, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    ADF_WBC_4KWIN, @R0
                MOVE    ADF_WBC_CTRL, R0
                MOVE    0, @R0

_ADF_UM_RET     DECRB
                RET

; ----------------------------------------------------------------------------
; Hardware Floppy: dynamic df0:/df1: labels (Configure Drives)
; ----------------------------------------------------------------------------

; HWF_LABEL_SYNC: menu lines 2 (the ADF mount item " df0:%s") and 3 (the
; hardware-role text " df1: Hardware Floppy") carry labels that depend on
; the selected Configure Drives combo. The menu STRUCTURE is fully static
; (config.vhd - reordering is impossible within the framework invariants,
; hardware-proven), so only two FIXED-WIDTH label fields are rewritten in
; the menu heap:
;   * the 4-char unit prefix of line 2: "df0:" / "df1:" / "ADF:"
;   * the 21-char text field of line 3
; HELP_MENU rebuilds the heap from the config ROM on EVERY menu open,
; wiping any patch - therefore this routine is SELF-HEALING: called from
; HANDLE_CORE_IO (which ticks inside all OSM wait loops), it compares the
; heap fields against the labels the current combo expects and, on a
; mismatch, patches the heap and - only when the main menu view is actually
; on screen (OSM visible, menu level 0, no browser/help sub-activity) -
; repaints the two lines. Every other draw (submenu exit, cursor moves)
; reads the freshly patched heap. Boot-safe: the combo is read straight
; from M2M$CFM_DATA (M2M$GET_SETTING would go FATAL before the menu system
; is initialized) and the line scan is bounded (the heap holds garbage
; before the first menu open; a patch into the reserved region is
; harmless). RAMROM-transparent (SCR$PRINTSTRXY changes the selection).
;
; Combo encoding (flat menu lines 7..10 = M2M$CFM_DATA bank 0 bits 7..10):
;   0 = df0: ADF      df1: Hardware  (default; bit 7 or no bit at all)
;   1 = df0: Hardware df1: ADF       (bit 8)
;   2 = df0: ADF      df1: Off       (bit 9)
;   3 = df0: Hardware df1: Off       (bit 10; no ADF drive - the mount
;                                     line reads " ADF:" then)
;
; Input:  none    Output: none    All registers preserved.
HWF_LABEL_SYNC  SYSCALL(enter, 1)

                ; be transparent about the active RAMROM device selection
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    @R1, R11
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    @R1, R12

                ; current combo -> R7 (plain CFM read; boot-safe)
                MOVE    M2M$CFM_ADDR, R0
                MOVE    0, @R0
                MOVE    M2M$CFM_DATA, R0
                MOVE    @R0, R0                 ; R0: CFM bank 0, bits 15..0
                XOR     R7, R7                  ; combo 0 (default)
                MOVE    R0, R1
                AND     0x0100, R1              ; bit 8: df0 HW, df1 ADF
                RBRA    _HWFS_CHK2, Z
                MOVE    1, R7
                RBRA    _HWFS_LOC, 1
_HWFS_CHK2      MOVE    R0, R1
                AND     0x0200, R1              ; bit 9: df0 ADF, df1 Off
                RBRA    _HWFS_CHK3, Z
                MOVE    2, R7
                RBRA    _HWFS_LOC, 1
_HWFS_CHK3      MOVE    R0, R1
                AND     0x0400, R1              ; bit 10: df0 HW, df1 Off
                RBRA    _HWFS_LOC, Z
                MOVE    3, R7

                ; locate heap line 2: skip two "\n" pairs in the items-string
                ; copy (bounded scan - garbage-safe before the first open)
_HWFS_LOC       MOVE    HEAP, R0
                ADD     OPTM_STRUCTSIZE, R0     ; R0: items string on the heap
                MOVE    2, R1                   ; newline pairs to skip
                MOVE    32, R2                  ; scan bound
_HWFS_SCAN      MOVE    @R0++, R3
                SUB     1, R2
                RBRA    _HWFS_RET, Z            ; bound hit: heap not built yet
                CMP     0x005C, R3              ; backslash ...
                RBRA    _HWFS_SCAN, !Z
                CMP     0x006E, @R0             ; ... followed by 'n'?
                RBRA    _HWFS_SCAN, !Z
                ADD     1, R0                   ; skip the 'n'
                SUB     1, R1
                RBRA    _HWFS_SCAN, !Z
                MOVE    R0, R6                  ; R6: line 2 start

                ; compare the line-2 prefix (4 chars after the leading space)
                MOVE    HWF_L2_TAB, R1
                ADD     R7, R1
                MOVE    @R1, R1                 ; R1: " df?:" table string
                MOVE    R6, R2
                ADD     1, R2
                MOVE    R1, R3
                ADD     1, R3
                MOVE    4, R4
                XOR     R5, R5                  ; R5: stale flag
_HWFS_C2        MOVE    @R3++, R8
                CMP     @R2++, R8
                RBRA    _HWFS_C2A, Z
                MOVE    1, R5
_HWFS_C2A       SUB     1, R4
                RBRA    _HWFS_C2, !Z

                ; locate line 3 (one more "\n" pair; R2 = behind the prefix)
                MOVE    R2, R0
                MOVE    16, R4                  ; scan bound (line-2 tail)
_HWFS_SCAN3     MOVE    @R0++, R3
                SUB     1, R4
                RBRA    _HWFS_RET, Z
                CMP     0x005C, R3
                RBRA    _HWFS_SCAN3, !Z
                CMP     0x006E, @R0
                RBRA    _HWFS_SCAN3, !Z
                ADD     1, R0                   ; R0: line 3 start

                ; compare the 21-char line-3 field
                MOVE    HWF_L3_TAB, R1
                ADD     R7, R1
                MOVE    @R1, R1                 ; R1: 23-char table string
                MOVE    R0, R2
                MOVE    R1, R3
                MOVE    21, R4
_HWFS_C3        MOVE    @R3++, R8
                CMP     @R2++, R8
                RBRA    _HWFS_C3A, Z
                MOVE    1, R5
_HWFS_C3A       SUB     1, R4
                RBRA    _HWFS_C3, !Z

                CMP     0, R5                   ; labels already correct?
                RBRA    _HWFS_RET, Z

                ; patch the heap: line-2 prefix (4 chars) ...
                MOVE    HWF_L2_TAB, R1
                ADD     R7, R1
                MOVE    @R1, R1
                ADD     1, R1                   ; skip the leading space
                MOVE    R6, R2
                ADD     1, R2
                MOVE    4, R4
_HWFS_P2        MOVE    @R1++, @R2++
                SUB     1, R4
                RBRA    _HWFS_P2, !Z

                ; ... and the line-3 field (21 chars incl. leading space)
                MOVE    HWF_L3_TAB, R1
                ADD     R7, R1
                MOVE    @R1, R1
                MOVE    R0, R2
                MOVE    21, R4
_HWFS_P3        MOVE    @R1++, @R2++
                SUB     1, R4
                RBRA    _HWFS_P3, !Z

                ; repaint - only when the MAIN menu view is on screen
                MOVE    M2M$CSR, R1
                MOVE    @R1, R1
                AND     M2M$CSR_OSM, R1
                RBRA    _HWFS_RET, Z            ; OSM not visible
                MOVE    OSM_SUB_ACTIVE, R1
                CMP     1, @R1
                RBRA    _HWFS_RET, Z            ; browser/help owns the screen
                MOVE    OPTM_MENULEVEL, R1
                CMP     0, @R1
                RBRA    _HWFS_RET, !Z           ; a submenu view is showing

                ; line 2: paint only the 5-char prefix (the %s-substituted
                ; filename right of it is prefix-independent). line 3: paint
                ; the full 23-char row (clears shorter texts).
                MOVE    2, R8
                MOVE    OPTM_F_MS_SLCT, R9      ; fatal context (unused on OK)
                RSUB    _OPTM_R_F2M_O, 1        ; R8 = row; C=1 -> off-level
                RBRA    _HWFS_RET, C
                RSUB    _HWFS_XY, 1             ; R9/R10 := screen x/y
                MOVE    HWF_L2_TAB, R8
                ADD     R7, R8
                MOVE    @R8, R8
                RSUB    SCR$PRINTSTRXY, 1

                MOVE    3, R8
                MOVE    OPTM_F_MS_SLCT, R9
                RSUB    _OPTM_R_F2M_O, 1
                RBRA    _HWFS_RET, C
                RSUB    _HWFS_XY, 1
                MOVE    HWF_L3_TAB, R8
                ADD     R7, R8
                MOVE    @R8, R8
                RSUB    SCR$PRINTSTRXY, 1

_HWFS_RET       MOVE    M2M$RAMROM_4KWIN, R1    ; restore the RAMROM selection
                MOVE    R12, @R1
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    R11, @R1
                SYSCALL(leave, 1)
                RET

; helper: R8 = menu row -> R9 = screen x (OPTM_X+1), R10 = screen y
; (OPTM_Y+row+1); preserves R8
_HWFS_XY        INCRB
                MOVE    OPTM_Y, R10
                MOVE    @R10, R10
                ADD     R8, R10
                ADD     1, R10
                MOVE    OPTM_X, R9
                MOVE    @R9, R9
                ADD     1, R9
                DECRB
                RET

; label tables: line-2 prefixes (5 chars incl. the leading space; the heap
; patch uses chars 1..4, the paint uses all 5) and line-3 fields (exactly
; 23 chars = the OSM content width; the heap patch uses chars 0..20)
HWF_L2_TAB      .DW     HWF_L2_A, HWF_L2_B, HWF_L2_C, HWF_L2_D
HWF_L3_TAB      .DW     HWF_L3_A, HWF_L3_B, HWF_L3_C, HWF_L3_D
HWF_L2_A        .ASCII_W " df0:"
HWF_L2_B        .ASCII_W " df1:"
HWF_L2_C        .ASCII_W " df0:"
HWF_L2_D        .ASCII_W " ADF:"
HWF_L3_A        .ASCII_W " df1: Hardware Floppy  "
HWF_L3_B        .ASCII_W " df0: Hardware Floppy  "
HWF_L3_C        .ASCII_W " df1: Off              "
HWF_L3_D        .ASCII_W " df0: Hardware Floppy  "

; ----------------------------------------------------------------------------
; HDMI Filter dispatch
; (ported from C64MEGA65 V6, CORE/m2m-rom/m2m-rom.asm)
; ----------------------------------------------------------------------------

; LOAD_HDMI_FILTER: Read the saved HDMI Filter selection from M2M$CFM_DATA
; and configure ascal accordingly. Called from PREP_START (boot) and
; OSM_SEL_POST (runtime). Eight options, single-select: exactly one of the
; AEXP_OSM_FLT_* bits is set at any time -- OPTM_G_STDSEL in config.vhd
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
HDMI_FLT_TABLE  .DW AEXP_OSM_FLT_NO_FILTER,     M2M$ASCAL_NEAREST,   0,                   0
                .DW AEXP_OSM_FLT_SHARP,         M2M$ASCAL_SBILINEAR, 0,                   0
                .DW AEXP_OSM_FLT_BICUBIC,       M2M$ASCAL_BICUBIC,   0,                   0
                .DW AEXP_OSM_FLT_SMOOTH,        M2M$ASCAL_POLYPHASE, GS_SHARPNESS_050,    GS_SHARPNESS_050
                .DW AEXP_OSM_FLT_LANCZOS,       M2M$ASCAL_POLYPHASE, LANCZOS2_12,         LANCZOS2_12
                .DW AEXP_OSM_FLT_SCANLINES,     M2M$ASCAL_POLYPHASE, LANCZOS2_12,         SCAN_BR_110_80

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
                .DW AEXP_OSM_FLT_CRT_SVIDEO,    M2M$ASCAL_POLYPHASE, CRT_SIM_SVIDEO_H,    SCAN_BR_110_80
                .DW AEXP_OSM_FLT_CRT_COMPOSITE, M2M$ASCAL_POLYPHASE, CRT_SIM_COMPOSITE_H, SCAN_BR_110_80

; ----------------------------------------------------------------------------
; LOAD_SCREEN_OFFSETS: screen adjustment (issue #5). Reads the per-Amiga-mode
; table of signed screen offsets (HDMI crop, analog overscan, analog pan) from
; /amiga/aexp_screen.cfg into RAM (SCR_TABLE). It does NOT push anything
; itself; DETECT_SCREEN_MODE (called from HANDLE_CORE_IO) watches the
; ascal-measured geometry + interlace flag, picks the matching row, and pushes
; it into the CFD gp_reg: HDMI crop to words 4..7 (ascal input crop
; himin/himax/vimin/vimax), analog overscan to words 0..3 (soft-blank) and
; analog pan to words 8..9 (analog_positioner sync phase), all M2M-UPSTREAM.
; On a missing/invalid file the table is zeroed (all 0 = no adjustment).
; Loading (re)arms the detector so the row of the current mode is re-pushed.
; Called from PREP_START (boot, before the core un-resets) and from
; OSM_SEL_POST on the "Reload screen cfg" item (live, no core reset / no
; re-synth -- the point of the SD-file tuning loop).
;
; File /amiga/aexp_screen.cfg (big-endian 16-bit words): "A","X", ver, count=4,
; then 4 rows in the fixed order lores-progressive, hires-progressive,
; lores-interlaced, hires-interlaced. A v4 row has 10 signed words:
; (himin_off, himax_off, vimin_off, vimax_off,   <- HDMI ascal input crop
;  os_l, os_r, os_t, os_b,                       <- analog overscan soft-blank
;  pan_x, pan_y)                                 <- analog position
; A legacy v3 row has only the first 8 words; the two pan words are zeroed on
; load, so existing v3 files keep working as overscan-only. The overscan four
; bias the analog soft-blank window; the pan pair drives the analog_positioner
; sync-phase shift (both M2M-UPSTREAM screen-center, applied in the framework
; av_pipeline). Only the low 12 bits of each word reach the core.
;
; Input:  None      Output: R8 = 0, R9 = 0
; ----------------------------------------------------------------------------
LOAD_SCREEN_OFFSETS INCRB

                MOVE    CONFIG_DEVH, R8         ; reuse the config device handle
                CMP     0, @R8                  ; valid? (set by HELP_MENU_INIT)
                RBRA    _LSO_ZERO, Z            ; no SD device -> zero table

                MOVE    SCR_FDH, R9        ; empty file handle struct
                MOVE    SCR_FILE_NAME, R10      ; "/amiga/aexp_screen.cfg"
                XOR     R11, R11                ; "/" path separator
                SYSCALL(f32_fopen, 1)
                CMP     0, R10                  ; open OK?
                RBRA    _LSO_ZERO, !Z           ; no -> zero table

                RSUB    _LSO_RDBYTE, 1          ; header byte 0: 'A'
                CMP     0, R10
                RBRA    _LSO_ZERO, !Z
                CMP     0x0041, R8
                RBRA    _LSO_ZERO, !Z
                RSUB    _LSO_RDBYTE, 1          ; header byte 1: 'X'
                CMP     0x0058, R8
                RBRA    _LSO_ZERO, !Z
                RSUB    _LSO_RDBYTE, 1          ; header byte 2: version 3 or 4
                MOVE    R8, R7                  ; R7: file version (banked reg)
                CMP     SCR_VER_V3, R8
                RBRA    _LSO_VEROK, Z
                CMP     SCR_VER_V4, R8
                RBRA    _LSO_ZERO, !Z
_LSO_VEROK      RSUB    _LSO_RDBYTE, 1          ; header byte 3: count = 4 modes
                CMP     SCR_MODES, R8
                RBRA    _LSO_ZERO, !Z

                MOVE    SCR_TABLE, R0           ; R0: table destination
                MOVE    SCR_MODES, R2           ; R2: row counter
_LSO_ROWLOOP    MOVE    SCR_V3_WORDS, R1        ; 8 words: HDMI + overscan
_LSO_RDLOOP     RSUB    _LSO_RDWORD, 1          ; R8 = 16-bit value, R10 status
                CMP     0, R10                  ; full word read?
                RBRA    _LSO_ZERO, !Z           ; truncated -> zero table
                MOVE    R8, @R0++               ; store into the RAM table
                SUB     1, R1
                RBRA    _LSO_RDLOOP, !Z
                CMP     SCR_VER_V4, R7          ; v4: two pan words follow
                RBRA    _LSO_PANZ, !Z
                MOVE    SCR_PAN_WORDS, R1
_LSO_PANLOOP    RSUB    _LSO_RDWORD, 1
                CMP     0, R10
                RBRA    _LSO_ZERO, !Z
                MOVE    R8, @R0++
                SUB     1, R1
                RBRA    _LSO_PANLOOP, !Z
                RBRA    _LSO_NXROW, 1
_LSO_PANZ       MOVE    0, @R0++                ; v3: pan_x = pan_y = 0
                MOVE    0, @R0++
_LSO_NXROW      SUB     1, R2
                RBRA    _LSO_ROWLOOP, !Z
                RBRA    _LSO_ARM, 1

_LSO_ZERO       MOVE    SCR_TABLE, R0      ; no/invalid file -> all zeros
                MOVE    SCR_TABLE_WORDS, R1      ; (0,0,0,0 = no centering)
_LSO_ZLOOP      MOVE    0, @R0++
                SUB     1, R1
                RBRA    _LSO_ZLOOP, !Z

                ; force the mode detector to (re-)push the row of the current
                ; mode by invalidating the applied-mode latch and restarting the
                ; debounce
_LSO_ARM        MOVE    SCR_APPLIED_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0

                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; read one byte from SCR_FDH -> R8 = byte, R10 = status (0 = OK). Shares the
; register bank of the caller (touches only R8/R9/R10).
_LSO_RDBYTE     MOVE    SCR_FDH, R8
                SYSCALL(f32_fread, 1)           ; R9 = byte, R10 = status
                MOVE    R9, R8
                RET

; read a big-endian 16-bit word -> R8 = value, R10 = status (0 = OK only if
; both bytes were read). Combines (hi << 8) | lo via SWAP.
_LSO_RDWORD     INCRB
                RSUB    _LSO_RDBYTE, 1          ; R8 = hi byte
                CMP     0, R10
                RBRA    _LSO_RDW_ERR, !Z
                MOVE    R8, R0
                SWAP    R0, R0                  ; R0 = hi << 8
                RSUB    _LSO_RDBYTE, 1          ; R8 = lo byte
                CMP     0, R10
                RBRA    _LSO_RDW_ERR, !Z
                OR      R8, R0
                MOVE    R0, R8                  ; R8 = (hi << 8) | lo
                XOR     R10, R10                ; status = OK
_LSO_RDW_RET    DECRB
                RET
_LSO_RDW_ERR    MOVE    1, R10                  ; status = error
                RBRA    _LSO_RDW_RET, 1

; push value R8 into CFD gp_reg word R9 (0..15). Fresh bank for the scratch.
_LSO_CFDW       INCRB
                MOVE    M2M$CFD_ADDR, R0
                MOVE    R9, @R0                 ; select 16-bit window
                MOVE    M2M$CFD_DATA, R0
                MOVE    R8, @R0                 ; write value into the window
                DECRB
                RET

; ----------------------------------------------------------------------------
; DETECT_SCREEN_MODE: screen adjustment (issue #5), the runtime half. Called
; from HANDLE_CORE_IO every main-loop / wait-loop iteration. Reads the
; ascal-measured input geometry (SYS_CORE_X/Y) and the interlace flag
; (SYS_CORE_FLAGS bit 0, M2M-UPSTREAM screen-center), classifies the Amiga
; graphics mode, debounces it, and on a stable CHANGE pushes the matching
; SCR_TABLE row into CFD gp_reg: HDMI crop into words 4..7, analog overscan
; into words 0..3, analog pan into words 8..9, and logs a MiSTer-style
; two-line (HDMI + Analog) trace to the serial UART. A mode outside the table
; (unexpected geometry) applies all zeros and logs "unsupported". Fully
; self-contained: own enter/leave and RAMROM device/window save/restore.
;
; Input/Output: none; all registers preserved
; ----------------------------------------------------------------------------
DETECT_SCREEN_MODE SYSCALL(enter, 1)

                ; --- read SYS_CORE geometry + interlace flag, transparently
                ; restoring the RAMROM device/window selection of the caller ---
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R1
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3
                MOVE    M2M$SYS_INFO, @R0
                MOVE    M2M$SYS_CORE, @R2
                MOVE    M2M$SYS_CORE_X, R4
                MOVE    @R4, R4                 ; R4 = hdmax (measured + 1)
                MOVE    M2M$SYS_CORE_Y, R5
                MOVE    @R5, R5                 ; R5 = vdmax
                MOVE    M2M$SYS_CORE_FLAGS, R6
                MOVE    @R6, R6                 ; R6 = flags (bit 0 = interlaced)
                MOVE    R1, @R0                 ; restore RAMROM selection
                MOVE    R3, @R2

                ; --- classify hdmax (OCS PAL is bimodal; the in_range_u syscall
                ;     tests the half-open window R9 <= R8 < R10) ---
                CMP     SCR_HDMAX_NOSIG, R4     ; hdmax < 200 -> no video yet
                RBRA    _DSM_RET, N             ;   (boot / mode change) -> skip
                MOVE    R4, R8                  ; R8 = hdmax for the range checks
                MOVE    SCR_LORES_LO, R9        ; lores window [367, 388)
                MOVE    SCR_LORES_HI, R10
                SYSCALL(in_range_u, 1)
                RBRA    _DSM_LORES, C
                MOVE    SCR_HIRES_LO, R9        ; hires window [744, 765)
                MOVE    SCR_HIRES_HI, R10       ; (R8 still = hdmax)
                SYSCALL(in_range_u, 1)
                RBRA    _DSM_HIRES, C
                RBRA    _DSM_UNK, 1             ; present but unrecognised

_DSM_LORES      XOR     R7, R7                  ; horizontal bit 0 = lores
                RBRA    _DSM_SCAN, 1
_DSM_HIRES      MOVE    SCR_HIRES_BIT, R7       ; horizontal bit 1 = hires
_DSM_SCAN       MOVE    R6, R0                  ; interlaced -> rows 2/3
                AND     M2M$SYS_CORE_FL_INT, R0
                RBRA    _DSM_DEB, Z
                ADD     SCR_LACE_ADD, R7
                RBRA    _DSM_DEB, 1
_DSM_UNK        MOVE    SCR_MODE_UNKNOWN, R7    ; = 4

                ; --- debounce: SCR_DEBOUNCE stable reads before acting ---
_DSM_DEB        MOVE    SCR_CAND_MODE, R0
                CMP     @R0, R7                 ; same as the candidate?
                RBRA    _DSM_SAME, Z
                MOVE    R7, @R0                 ; no: restart the candidate
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0
                RBRA    _DSM_RET, 1
_DSM_SAME       MOVE    SCR_CAND_CNT, R0
                CMP     SCR_DEBOUNCE, @R0       ; count < DEBOUNCE -> settling
                RBRA    _DSM_SETTLE, N
                MOVE    SCR_APPLIED_MODE, R0
                CMP     @R0, R7                 ; already the applied mode?
                RBRA    _DSM_RET, Z
                MOVE    R7, @R0                 ; latch the newly applied mode
                RBRA    _DSM_APPLY, 1
_DSM_SETTLE     MOVE    SCR_CAND_CNT, R0
                ADD     1, @R0
                RBRA    _DSM_RET, 1

                ; --- apply mode R7: push offsets to the CFD, then log ---
_DSM_APPLY      CMP     SCR_MODE_UNKNOWN, R7
                RBRA    _DSM_KNOWN, !Z
                MOVE    SCR_ROW_WORDS, R2       ; unknown: push 10 zeros = all off
                MOVE    SCR_CFD_VGA, R9         ; CFD words 0..9 (overscan 0..3,
_DSM_ZLOOP      XOR     R8, R8                  ;  HDMI 4..7, pan 8..9)
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_ZLOOP, !Z
                MOVE    MSG_SCR_UNSUP, R8
                SYSCALL(puts, 1)
                RBRA    _DSM_LOGGEO, 1

_DSM_KNOWN      MOVE    R7, R0                  ; row offset = mode * SCR_ROW_WORDS
                ADD     R0, R0                  ; (= *10: *2, keep, *8, add)
                MOVE    R0, R1                  ; R1 = mode * 2
                ADD     R0, R0
                ADD     R0, R0                  ; R0 = mode * 8
                ADD     R1, R0                  ; R0 = mode * 10
                ADD     SCR_TABLE, R0           ; R0 -> table row (10 words)
                MOVE    R0, R3                  ; keep the row ptr for the log
                ; push the HDMI half (row words 0..3) -> CFD words 4..7
                MOVE    SCR_HALF_WORDS, R2
                MOVE    SCR_CFD_HDMI, R9
_DSM_PLOOPH     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPH, !Z
                ; push the overscan half (row words 4..7) -> CFD words 0..3
                MOVE    SCR_HALF_WORDS, R2      ; R0 now points at the overscan half
                MOVE    SCR_CFD_VGA, R9
_DSM_PLOOPV     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPV, !Z
                ; push the pan pair (row words 8..9) -> CFD words 8..9
                MOVE    SCR_PAN_WORDS, R2
                MOVE    SCR_CFD_PAN, R9
_DSM_PLOOPP     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPP, !Z
                MOVE    MSG_SCR_PFX, R8         ; "Screen: Amiga mode "
                SYSCALL(puts, 1)
                MOVE    R7, R0                  ; LORES / HIRES
                AND     SCR_HIRES_BIT, R0
                RBRA    _DSM_LHIR, !Z
                MOVE    MSG_SCR_LORES, R8
                RBRA    _DSM_LHPUT, 1
_DSM_LHIR       MOVE    MSG_SCR_HIRES, R8
_DSM_LHPUT      SYSCALL(puts, 1)
                MOVE    R6, R0                  ; PROGRESSIVE / INTERLACED
                AND     M2M$SYS_CORE_FL_INT, R0
                RBRA    _DSM_LLAC, !Z
                MOVE    MSG_SCR_PROG, R8
                RBRA    _DSM_LSPUT, 1
_DSM_LLAC       MOVE    MSG_SCR_LACE, R8
_DSM_LSPUT      SYSCALL(puts, 1)

_DSM_LOGGEO     MOVE    MSG_SCR_GEO1, R8        ; "  (hdmax="
                SYSCALL(puts, 1)
                MOVE    R4, R8
                RSUB    _SCR_LOGDEC, 1
                MOVE    MSG_SCR_GEO2, R8        ; " vdmax="
                SYSCALL(puts, 1)
                MOVE    R5, R8
                RSUB    _SCR_LOGDEC, 1
                MOVE    MSG_SCR_GEO3, R8        ; ")"
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                CMP     SCR_MODE_UNKNOWN, R7    ; unknown: no offset lines
                RBRA    _DSM_RET, Z
                MOVE    R3, R0                  ; row ptr -> HDMI half then VGA half
                ; --- line "HDMI:": ascal input-crop offsets (row words 0..3) ---
                MOVE    MSG_SCR_HDMI, R8        ; "HDMI: himin="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF2, R8        ; " himax="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF3, R8        ; " vimin="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF4, R8        ; " vimax="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                SYSCALL(crlf, 1)
                ; --- line "Analog:": overscan (row words 4..7) + pan (8..9) ---
                MOVE    MSG_SCR_VGA, R8         ; "Analog: os_l="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF2, R8        ; " os_r="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF3, R8        ; " os_t="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF4, R8        ; " os_b="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF5, R8        ; " pan_x="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF6, R8        ; " pan_y="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                SYSCALL(crlf, 1)

_DSM_RET        SYSCALL(leave, 1)
                RET

; log the unsigned value in R8 as decimal on the serial UART
_SCR_LOGDEC     SYSCALL(enter, 1)
                XOR     R9, R9                  ; high word = 0
                SUB     11, SP                  ; scratch decimal-string buffer
                MOVE    SP, R10
                SYSCALL(h2dstr, 1)              ; R11 -> decimal string
                MOVE    R11, R8
                SYSCALL(puts, 1)
                ADD     11, SP
                SYSCALL(leave, 1)
                RET

; log the signed value in R8 as decimal with an explicit +/- sign
_SCR_LOGSDEC    SYSCALL(enter, 1)
                MOVE    R8, R0                  ; keep the value
                AND     0x8000, R8              ; negative?
                RBRA    _SLS_NEG, !Z
                MOVE    0x002B, R8              ; '+'
                SYSCALL(putc, 1)
                MOVE    R0, R8
                RBRA    _SLS_MAG, 1
_SLS_NEG        MOVE    0x002D, R8              ; '-'
                SYSCALL(putc, 1)
                MOVE    R0, R8
                XOR     0xFFFF, R8              ; magnitude = -value
                ADD     1, R8
_SLS_MAG        RSUB    _SCR_LOGDEC, 1
                SYSCALL(leave, 1)
                RET

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

; OSM menu constants are autogenerated by make_rom.sh (like in C64MEGA65):
; the AEXP_OSM_* line numbers are scraped from the C_MENU_* constants in
; ../vhdl/mega65.vhd and the AEXP_OPTM_G_* group ids from the OPTM_G_*
; constants in ../vhdl/config.vhd -- no hardcoded menu indexes here.
#include "osm_const.asm"

; ADF file extension (needs to be upper case)
ADF_FILE_EXT    .ASCII_W ".ADF"

; ADF write-back CSR (WBC): device AEXP_DEV_ADF (autogenerated into
; osm_const.asm from globals.vhd), 4k window 0xFFFE - register map defined
; in CORE/vhdl/adf_mount_wrapper.vhd (keep in sync!)
ADF_WBC_4KWIN   .EQU    0xFFFE              ; the write-back CSR window
ADF_WBC_CTRL    .EQU    0x7000              ; bit 0: WR_EN (df0 writable)
ADF_WBC_STAT    .EQU    0x7001              ; bit 0: any_dirty  bit 1: flush_start
ADF_WBC_ATDELAY .EQU    0x7002              ; anti-thrashing delay in ms
ADF_WBC_DIRTY0  .EQU    0x7010              ; ..0x701A: dirty bitmap, W1C
ADF_TRACK_BYTES .EQU    5632                ; 11 sectors x 512 bytes
ADF_FLUSH_CHUNK .EQU    512                 ; bytes per background time slice

; MEGA65 battery RTC (issue #13): framework device C_DEV_RTC (qnice_wrapper.vhd)
; exposing the QNICE date/time interface of M2M/vhdl/i2c/rtc_controller.vhd. The
; core reads the same time at $DC0000 (Minimig MSM6242B). The window offset
; equals the register address (keep in sync with rtc_controller.vhd).
AEXP_DEV_RTC    .EQU    0x0006              ; framework RTC device (C_DEV_RTC)
RTC_4KWIN       .EQU    0x0000              ; RTC decodes addr[7:0] only
RTC_MINUTES     .EQU    0x7002              ; internal timer: minutes (BCD, RO)
RTC_COMMAND     .EQU    0x7008              ; b0 busy(RO) b1 read b2 write b3 running
RTC_CMD_STOP    .EQU    0x0000              ; stop the internal timer
RTC_CMD_RESYNC  .EQU    0x000A              ; b1 read RTC->internal + b3 keep running

; Warning: file size out of the valid ADF range
WRN_ADF_SIZE    .ASCII_P "\n\nThis is not a valid ADF disk image:\n"
                .ASCII_P "the file size must be 901,120 bytes\n"
                .ASCII_P "(880 KB standard ADF; 81..83-track over-\n"
                .ASCII_P "dumps up to 934,912 bytes are accepted)."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; Warning: could not write back the current disk before mounting a new one
WRN_ADF_BUSY    .ASCII_P "\n\nUnsaved changes on the current disk\n"
                .ASCII_P "could not be written back because the\n"
                .ASCII_P "Amiga keeps writing to the drive.\n"
                .ASCII_P "Stop the disk activity, then try again."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; Fatal: SD card write failed during the ADF write-back
ERR_ADF_FLUSH   .ASCII_W "ADF write-back: writing to the SD card failed.\n"

; Screen centering (issue #5): per-Amiga-mode HDMI input-crop + VGA soft-blank table.
; File name, table geometry, mode indices and the serial-log strings. The four
; rows (lores-prog, hires-prog, lores-lace, hires-lace) default to all zeros
; (no centering) until /amiga/aexp_screen.cfg provides tuned values.
SCR_FILE_NAME     .ASCII_W "/amiga/aexp_screen.cfg"

; Momentary "Reload Screen Config" busy label (issue #19). SCR$PRINTSTR renders
; the < > as the arrow glyphs of the framework (same look as <Mount>/<Load>). It
; is exactly OPTM_DX (23) characters, so printed at the left edge of the content
; it fills the whole width; it is shown while the SD re-mount + reload runs and
; then OPTM_SHOW repaints it away.
SCR_LOADING_STR   .ASCII_W "<Loading Screen Config>"

SCR_MODES         .EQU 4                  ; table rows (file "count" byte)
SCR_TABLE_WORDS   .EQU 40                 ; 4 rows x 10 words (HDMI 4 + overscan 4 + pan 2)
SCR_MODE_UNKNOWN  .EQU 4                  ; detected mode outside the table
SCR_MODE_NONE     .EQU 0xFFFF             ; "nothing applied yet" latch value
SCR_DEBOUNCE      .EQU 3                  ; stable detects before a mode change
                                          ; (detect is throttled, so these span
                                          ; frames -- keep it small)
SCR_TICK_MASK     .EQU 0x00FF             ; run DETECT_SCREEN_MODE every 256th poll

SCR_CFD_HDMI      .EQU 4                  ; HDMI-offset CFD gp_reg words (4..7)
SCR_CFD_VGA       .EQU 0                  ; analog-overscan CFD gp_reg words (0..3)
SCR_CFD_PAN       .EQU 8                  ; analog-pan CFD gp_reg words (8..9)
SCR_ROW_WORDS     .EQU 10                 ; words per mode row (HDMI 4 + overscan 4 + pan 2)
SCR_HALF_WORDS    .EQU 4                  ; edge offsets per output group
SCR_V3_WORDS      .EQU 8                  ; row words shared by v3 and v4 (before pan)
SCR_PAN_WORDS     .EQU 2                  ; pan words per row (v4 only)
SCR_VER_V3        .EQU 3                  ; legacy file: no pan words (pan = 0)
SCR_VER_V4        .EQU 4                  ; current file: overscan + pan per row
SCR_HIRES_BIT     .EQU 1                  ; mode bit 0: 1 = hires horizontal
SCR_LACE_ADD      .EQU 2                  ; mode += 2 when interlaced (rows 2/3)

; hdmax (ascal-measured, +1) classification. OCS PAL geometry is deterministic
; (fixed Agnus beam constants: lores ~377/378, hires ~754/755, only +/-1..2
; ce-phase rounding), so the windows are tight (+/-~10 px). An unexpected geometry
; (a genuinely new/unknown mode) is thus flagged "unsupported" rather than forced
; into lores/hires. The raw hdmax is always logged, so if a board ever measures
; outside a window it is a one-line retune (the logged value +/-10). Windows are
; half-open [lo, hi) to match MTH$IN_RANGE_U.
SCR_HDMAX_NOSIG   .EQU 200                ; hdmax < 200: no video yet -> skip
SCR_LORES_LO      .EQU 367                ; lores hdmax window [367, 388) (~377/378)
SCR_LORES_HI      .EQU 388
SCR_HIRES_LO      .EQU 744                ; hires hdmax window [744, 765) (~754/755)
SCR_HIRES_HI      .EQU 765

; serial-terminal (UART) log strings, MiSTer-style "new mode detected" trace
MSG_SCR_PFX       .ASCII_W "Screen: Amiga mode "
MSG_SCR_LORES     .ASCII_W "LORES"
MSG_SCR_HIRES     .ASCII_W "HIRES"
MSG_SCR_PROG      .ASCII_W " PROGRESSIVE"
MSG_SCR_LACE      .ASCII_W " INTERLACED"
MSG_SCR_GEO1      .ASCII_W "  (hdmax="
MSG_SCR_GEO2      .ASCII_W " vdmax="
MSG_SCR_GEO3      .ASCII_W ")"
MSG_SCR_HDMI      .ASCII_W "  HDMI: himin="
MSG_SCR_OFF2      .ASCII_W " himax="
MSG_SCR_OFF3      .ASCII_W " vimin="
MSG_SCR_OFF4      .ASCII_W " vimax="
MSG_SCR_VGA       .ASCII_W "  Analog: os_l="
MSG_SCR_VOF2      .ASCII_W " os_r="
MSG_SCR_VOF3      .ASCII_W " os_t="
MSG_SCR_VOF4      .ASCII_W " os_b="
MSG_SCR_VOF5      .ASCII_W " pan_x="
MSG_SCR_VOF6      .ASCII_W " pan_y="
MSG_SCR_UNSUP     .ASCII_W "screen: unsupported mode, adjustments disabled"

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

; ADF write-back state (see HANDLE_CORE_IO / FLUSH_ADF_STEP)
ADF_FDH         .BLOCK FAT32$FDH_STRUCT_SIZE    ; our own snapshot of the
                                                ; mounted ADF file handle:
                                                ; HANDLE_RM_FILE1 is re-opened
                                                ; by the Shell for the NEXT
                                                ; load, the snapshot stays
                                                ; valid until SD-card change
ADF_FDH_VALID   .BLOCK 1                        ; 1: ADF_FDH is usable
ADF_SD_SLOT     .BLOCK 1                        ; active SD slot at arm time
ADF_MOUNT_SEEN  .BLOCK 1                        ; 1: armed or blocked; 0: a
                                                ; fresh PARSEST=READY may arm
ADF_FL_STATE    .BLOCK 1                        ; 0: idle  1: track session
ADF_FL_REMAIN   .BLOCK 1                        ; bytes left in session track
ADF_FL_BADDR_LO .BLOCK 1                        ; session byte address within
ADF_FL_BADDR_HI .BLOCK 1                        ; image and file (32 bit)

; ADF unmount-with-SPACE state (issue #16, see HANDLE_UNMOUNT_KEY)
ADF_UNMNT_PREV  .BLOCK 1                        ; SPACE state last poll (edge)
OSM_SUB_ACTIVE  .BLOCK 1                        ; 1 while the sub-activity of a
                                                ; menu selection (browser/help)
                                                ; runs: gate 4 for the unmount

; Screen adjustment (issue #5): file handle for /amiga/aexp_screen.cfg
SCR_FDH    .BLOCK FAT32$FDH_STRUCT_SIZE
; per-Amiga-mode table (loaded by LOAD_SCREEN_OFFSETS, applied by
; DETECT_SCREEN_MODE): 4 rows x 10 signed words = HDMI crop
; (himin,himax,vimin,vimax), analog overscan (os_l,os_r,os_t,os_b),
; analog pan (pan_x,pan_y)
SCR_TABLE        .BLOCK 40                       ; 4 mode rows x 10 words (HDMI 4 + overscan 4 + pan 2)
SCR_APPLIED_MODE .BLOCK 1                        ; 0..3 row / 4 unknown / NONE
SCR_CAND_MODE    .BLOCK 1                        ; debounce candidate mode
SCR_CAND_CNT     .BLOCK 1                        ; debounce counter
SCR_TICK         .BLOCK 1                        ; detector throttle counter

; Battery-RTC reseed state (see HANDLE_CORE_IO / RTC_STEP, issue #13)
RTC_LAST_MIN    .BLOCK 1                        ; last internal minute seen by
                                                ; RTC_STEP; 0xFFFF = none yet

; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 30208, then you write 30208-1920=28288
; instead, but when doing the sanity check calculations, you use 30208
;
; Budget (HELP_MENU in M2M/rom/options.asm, checked at runtime by LOG_HEAP1/
; LOG_HEAP2): the 124 menu items are a 1245-character string plus the 19-word
; menu structure plus three per-item arrays = 19 + 1245 + 1 + 3 x 124 + 1 =
; 1638 words; on top of that, OPTM_HEAP needs one (OPTM_DX + 2)-wide buffer
; per submenu (8), manual ROM (1) and vdrive (0) plus one scratch buffer =
; 10 x 25 = 250 words. Total demand is 1888 words, rounded up to the next
; 128-word boundary: 1920 words, leaving 32 words headroom. Do not reserve a
; large safety margin here: every word is taken directly from the file-browser
; heap. Whenever OPTM_SIZE, OPTM_ITEMS, OPTM_DX, or the submenu/drive/
; manual-ROM counts grow, recalculate both budgets and rebalance the
; HEAP_SIZE constants below by the same delta.
MENU_HEAP_SIZE  .EQU 1920

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 5248                       ; 7168 - 1920 = 5248
HEAP            .BLOCK 1

; in RELEASE mode: 28.375k of heap for folders with many files
#else

HEAP_SIZE       .EQU 28288                      ; 30208 - 1920 = 28288
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 30208 words to HEAP which
; is currently 0x8220 and subtract the result from 0xFEE0. This yields
; 1728 stack words, 192 more than STACK_SIZE. Recheck the HEAP and
; VAR$STACK_START addresses in m2m-rom.lis whenever variables are added.

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
