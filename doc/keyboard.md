# Keyboard Mappings

AExp offers two keyboard mappings. Select **MEGA65** or **Amiga** in the
on-screen menu under **Keyboard**. You can change modes while software is
running: the next key press uses the new mapping; keys already held keep their
old mapping until released.

| Mode | How it works | Best choice when |
|------|--------------|------------------|
| **MEGA65** (default) | Types the character printed on the MEGA65 keycap | You want the simplest everyday typing |
| **Amiga** | Maps by physical position, like the keyboard in [deft's British A600 layout](assets/keyboard.png) | You know the Amiga layout, follow original Amiga instructions, or software expects Amiga key positions |

Start with **MEGA65 mode**. Switch to **Amiga mode** if a program needs the
original layout. Some games, including **Pinball Dreams**, need Amiga mode
because they do not work correctly with the MEGA65-mode function-key mapping.

## MEGA65 mode (default)

The rule is simple: **the cap is law**. A key's main legend is typed directly,
its upper legend with <kbd>Shift</kbd>, and its front-face legend with
<kbd>MEGA</kbd> (the Commodore/<kbd>C=</kbd> key).

Letters and unshifted digits work as printed. The tables below contain the keys
worth looking up.

### Number row

| MEGA65 key | Without <kbd>Shift</kbd> | With <kbd>Shift</kbd> |
|------------|:------------------------:|:---------------------:|
| <kbd>1</kbd> | `1` | `!` |
| <kbd>2</kbd> | `2` | `"` |
| <kbd>3</kbd> | `3` | `#` |
| <kbd>4</kbd> | `4` | `$` |
| <kbd>5</kbd> | `5` | `%` |
| <kbd>6</kbd> | `6` | `&` |
| <kbd>7</kbd> | `7` | `'` |
| <kbd>8</kbd> | `8` | `(` |
| <kbd>9</kbd> | `9` | `)` |
| <kbd>0</kbd> | `0` | nothing (the shifted cap legend is not an Amiga character) |

### Punctuation and symbols

| MEGA65 key | Key alone | With <kbd>Shift</kbd> | With <kbd>MEGA</kbd> |
|------------|:---------:|:---------------------:|:--------------------:|
| <kbd>,</kbd> | `,` | `<` | `~` |
| <kbd>.</kbd> | `.` | `>` | <code>&#124;</code> |
| <kbd>/</kbd> | `/` | `?` | `\` |
| <kbd>:</kbd> | `:` | `[` | `{` |
| <kbd>;</kbd> | `;` | `]` | `}` |
| <kbd>=</kbd> | `=` | `_` | `_` |
| <kbd>@</kbd> | `@` | nothing | `@` |
| <kbd>&larr;</kbd> (top-left symbol key) | `_` | <code>&#96;</code> | <code>&#96;</code> |
| <kbd>&uarr;</kbd> (symbol key) | `^` | nothing | nothing |
| <kbd>*</kbd> | `*` | nothing | nothing |

The four `nothing` entries in the shifted column correspond to graphic-only
MEGA65 legends that have no printable Amiga character. In particular, the
Amiga character set has no printable left arrow or `π`.

The remaining useful symbol keys are:

| MEGA65 key | Amiga result |
|------------|--------------|
| <kbd>+</kbd> | Keypad `+` |
| <kbd>&minus;</kbd> | `-` |
| <kbd>&pound;</kbd> | `\` on the default US Amiga keymap |
| <kbd>INST/DEL</kbd> | Backspace (delete left) |
| <kbd>CLR/HOME</kbd> | Delete (delete right) |

There are two ways to type a backslash: <kbd>MEGA</kbd>+<kbd>/</kbd> or the
dedicated <kbd>&pound;</kbd> key. The latter produces `\`, not `£`, because the
default US Amiga keymap has no pound-sign key. <kbd>Shift</kbd>+<kbd>&pound;</kbd>
produces <code>&#124;</code> with that keymap.

<kbd>MEGA</kbd> still works as **Left Amiga** whenever it is not being used for
a front-face symbol. This keeps Amiga shortcuts such as
<kbd>Left Amiga</kbd>+<kbd>N</kbd>/<kbd>M</kbd> working. Tapping <kbd>MEGA</kbd>
alone sends a normal Left Amiga tap.

Some printed characters require AExp to add or remove Amiga-side
<kbd>Shift</kbd> briefly. Normal Amiga software handles this correctly. A raw,
low-level keyboard diagnostic that bypasses `keyboard.device` may also display
those temporary modifier events.

### Function, modifier, and control keys

| MEGA65 key | Amiga function |
|------------|----------------|
| <kbd>F1</kbd>, <kbd>F3</kbd>, <kbd>F5</kbd>, <kbd>F7</kbd>, <kbd>F9</kbd> | F1, F3, F5, F7, F9 |
| <kbd>Shift</kbd> + one of those F-keys | F2, F4, F6, F8, F10 |
| <kbd>F11</kbd>, <kbd>F13</kbd> | No Amiga key; useful as clean menu keys |
| <kbd>Help</kbd> | Help |
| <kbd>Esc</kbd> | Esc |
| <kbd>MEGA</kbd> | Left Amiga, except while typing a front-face symbol |
| <kbd>RESTORE</kbd> | Right Amiga |
| <kbd>Alt</kbd> | Left Alt |
| <kbd>No Scroll</kbd> | Right Alt |
| <kbd>Caps Lock</kbd> | Amiga Caps Lock |
| <kbd>Ctrl</kbd>, <kbd>Tab</kbd>, both <kbd>Shift</kbd> keys, cursor keys | Same Amiga key |
| <kbd>Run/Stop</kbd> (hold) | Right mouse button |
| <kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd> | Warm reset |

The reset combination is the Amiga's familiar
<kbd>Ctrl</kbd>+<kbd>Left Amiga</kbd>+<kbd>Right Amiga</kbd> shortcut.

The MEGA65 has no numeric keypad or equivalent for the Amiga's international
keys. Most keypad keys are therefore unavailable; <kbd>+</kbd> and <kbd>*</kbd>
are the useful exceptions shown above.

### Mouse from the keyboard

| Mouse action | MEGA65-mode keys |
|--------------|------------------|
| Move pointer | <kbd>MEGA</kbd> + cursor keys |
| Move faster | <kbd>MEGA</kbd> + <kbd>Shift</kbd> + cursor keys |
| Left button | <kbd>MEGA</kbd> + <kbd>Alt</kbd> |
| Right button | Hold <kbd>Run/Stop</kbd> |

Pointer movement and the left-button shortcut are features of the Amiga
operating system. They work in Workbench and system-friendly applications, but
not in games or demos that take over the machine. Tap a cursor key for fine
movement or hold it to accelerate across the screen. The right-button shortcut
is provided directly by AExp.

## Amiga mode

Amiga mode is **positional**: each MEGA65 key sends the code of the key in the
same physical position on an Amiga. The MEGA65 legends no longer determine the
result, there is no <kbd>MEGA</kbd> symbol layer, and <kbd>Shift</kbd> passes
through normally.

Most letters, digits, cursor keys, and the <kbd>,</kbd> <kbd>.</kbd>
<kbd>/</kbd> cluster are already in the expected positions. The tables below
show what changes. They assume the US keymap built into Kickstart 1.3.

### Number row

| MEGA65 key | Key alone | With <kbd>Shift</kbd> |
|------------|:---------:|:---------------------:|
| <kbd>1</kbd> | `1` | `!` |
| <kbd>2</kbd> | `2` | `@` |
| <kbd>3</kbd> | `3` | `#` |
| <kbd>4</kbd> | `4` | `$` |
| <kbd>5</kbd> | `5` | `%` |
| <kbd>6</kbd> | `6` | `^` |
| <kbd>7</kbd> | `7` | `&` |
| <kbd>8</kbd> | `8` | `*` |
| <kbd>9</kbd> | `9` | `(` |
| <kbd>0</kbd> | `0` | `)` |

### Punctuation by position

| MEGA65 keycap | Amiga key in that position | Key alone | With <kbd>Shift</kbd> |
|---------------|----------------------------|:---------:|:---------------------:|
| <kbd>&larr;</kbd> (top-left symbol key) | <kbd>&#96;</kbd> | <code>&#96;</code> | `~` |
| <kbd>:</kbd> | <kbd>;</kbd> | `;` | `:` |
| <kbd>@</kbd> | <kbd>[</kbd> | `[` | `{` |
| <kbd>;</kbd> | <kbd>'</kbd> | `'` | `"` |
| <kbd>&pound;</kbd> | <kbd>\</kbd> | `\` | <code>&#124;</code> |
| <kbd>+</kbd> | <kbd>&minus;</kbd> | `-` | `_` |
| <kbd>&minus;</kbd> | <kbd>=</kbd> | `=` | `+` |
| <kbd>*</kbd> | <kbd>]</kbd> | `]` | `}` |

The [reference layout](assets/keyboard.png) is based on a **British** Amiga
A600, while an Amiga booted directly with Kickstart 1.3 uses its built-in
**US** keymap. The loaded Amiga keymap always has the final say: AExp sends key
positions, not characters.

To reproduce the British reference exactly—including `£` on
<kbd>Shift</kbd>+<kbd>3</kbd> and `@` on <kbd>Shift</kbd>+<kbd>;</kbd>—boot
Workbench and run **`SetMap gb`**. This requires `DEVS:Keymaps/gb`. A game or
demo that boots without Workbench remains on the US keymap. AExp cannot select
the Amiga keymap for the running software.

### Function, modifier, and control keys

The entire MEGA65 top row maps positionally across the Amiga's
<kbd>Esc</kbd> and <kbd>F1</kbd>–<kbd>F10</kbd> row:

| MEGA65 key | Amiga key |
|------------|-----------|
| <kbd>Run/Stop</kbd> | Esc |
| <kbd>Esc</kbd> | F1 |
| <kbd>Alt</kbd> | F2 |
| <kbd>Caps Lock</kbd> | F3 |
| <kbd>No Scroll</kbd> | F4 |
| <kbd>F1</kbd> | F5 |
| <kbd>F3</kbd> | F6 |
| <kbd>F5</kbd> | F7 |
| <kbd>F7</kbd> | F8 |
| <kbd>F9</kbd> | F9 |
| <kbd>F11</kbd> | F10 |
| <kbd>Help</kbd> | Help |
| <kbd>F13</kbd> | Left Alt |

Every Amiga function key therefore has its own key; do not use
<kbd>Shift</kbd> to select the even-numbered ones.

| MEGA65 key | Amiga function |
|------------|----------------|
| <kbd>MEGA</kbd> | Left Amiga |
| <kbd>=</kbd> | Right Amiga |
| <kbd>F13</kbd> | Left Alt |
| <kbd>RESTORE</kbd> | Right Alt |
| <kbd>INST/DEL</kbd> | Delete (delete right) |
| <kbd>CLR/HOME</kbd> | Backspace (delete left) |
| <kbd>Shift Lock</kbd> | Holds Left Shift |
| <kbd>Ctrl</kbd>, <kbd>Tab</kbd>, both <kbd>Shift</kbd> keys, cursor keys | Same Amiga key |
| <kbd>&uarr;</kbd> (symbol key, hold) | Right mouse button |
| <kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd> | Warm reset |

The left-arrow symbol shown on <kbd>CLR/HOME</kbd> in the reference layout is
the Amiga's Backspace symbol: it means "delete left" and is not a printable
left-arrow character.

The top-row <kbd>Caps Lock</kbd> acts as an ordinary momentary F3 key. Its LED
still toggles because the MEGA65 keyboard controller owns the latch and LED;
the light has no effect on the Amiga. A true Amiga Caps Lock is not available
in this mode: the MEGA65 hardware combines the home-row <kbd>Shift Lock</kbd>
and Left Shift signal, so <kbd>Shift Lock</kbd> can only hold Amiga Left Shift.
It capitalizes letters but also shifts the number row. Use MEGA65 mode when you
need genuine Amiga Caps Lock.

The MEGA65's shorter layout still has no numeric keypad or Amiga international
keys in this mode.

### Mouse from the keyboard

| Mouse action | Amiga-mode keys |
|--------------|-----------------|
| Move pointer | <kbd>MEGA</kbd> + cursor keys |
| Move faster | <kbd>MEGA</kbd> + <kbd>Shift</kbd> + cursor keys |
| Left button | <kbd>MEGA</kbd> + <kbd>F13</kbd> |
| Right button | Hold <kbd>&uarr;</kbd> (the symbol key left of <kbd>RESTORE</kbd>, not a cursor key) |

Here <kbd>MEGA</kbd> is Left Amiga and <kbd>F13</kbd> is Left Alt, so their
combination is the Amiga operating system's built-in left-click shortcut.
Pointer movement has the same Workbench-only caveat and acceleration behavior
described for MEGA65 mode. AExp moves its direct right-button shortcut to the
<kbd>&uarr;</kbd> symbol key because <kbd>Run/Stop</kbd> is Esc in this mode.

## Opening the menu — and freeing the Help key

By default, <kbd>Help</kbd> opens and closes the AExp on-screen menu, as it does
in other MEGA65 cores. Help is also a real Amiga key. To reserve it for Amiga
software, open **Keyboard** > **`OSM:`** ("key to open the menu") and select a
different opener:

| Menu opener | In MEGA65 mode | In Amiga mode |
|-------------|----------------|---------------|
| <kbd>Help</kbd> (default) | Also sends Amiga Help | Also sends Amiga Help |
| <kbd>F11</kbd> | Clean: sends nothing to the Amiga | Also sends F10 |
| <kbd>F13</kbd> | Clean: sends nothing to the Amiga | Also sends Left Alt |
| <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> | Amiga sees Left Amiga and the right mouse button | Amiga sees Left Amiga+Esc |

Choosing an alternative leaves <kbd>Help</kbd> available solely to the Amiga.
The selection is saved with the other settings and survives a restart.

In MEGA65 mode, <kbd>F11</kbd> or <kbd>F13</kbd> is the least intrusive choice
because neither key has an Amiga mapping. In Amiga mode every choice also has
an Amiga meaning, so choose the one least likely to disturb the software you
are running. The two-key option is most likely to clash with a real Amiga
shortcut or input.

The selected key also closes the menu; the
<kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> combination closes it symmetrically. While
inside the menu, <kbd>Run/Stop</kbd> on its own steps back or closes it, so you
cannot lock yourself out.
