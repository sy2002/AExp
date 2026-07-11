# The Keyboard: Typing on the Amiga with your MEGA65

The MEGA65 and the Amiga 500 have almost the same keyboard — but not quite.
Both are classic full-travel keyboards with a similar layout, yet the keys are
lettered a little differently and a few caps sit in different places. AExp
bridges that gap for you, and it even lets you choose **how** it bridges it.

This guide explains, in plain terms, how the MEGA65 keyboard drives the Amiga,
how to type every Amiga character, and how to change the mapping to suit the way
you think about the keyboard.

If you only remember one sentence, make it this one:

> **In the default mode, you get exactly the character printed on the MEGA65
> keycap.** Press the key that shows `@`, and the Amiga receives `@`.

Everything below is detail on top of that promise.

---

## Two ways to map the keyboard

AExp offers **two keyboard modes**, and you pick the one that matches how you
think. You switch between them in the on-screen menu (press <kbd>Help</kbd>),
under the **Keyboard** section.

### MEGA65 mode — "the cap is law" (default)

This is the friendly default. **Whatever is printed on the MEGA65 key, that is
what the Amiga gets.** The MEGA65 keycaps carry up to three legends:

* the **main** legend (what you get on its own),
* the **upper** legend (what you get with <kbd>Shift</kbd>),
* the small **front-face** legend on the slanted front of the cap (what you get
  with the <kbd>MEGA</kbd> key — the Commodore/`C=` key).

AExp reproduces all three. So if the cap shows `{` on its front face, then
<kbd>MEGA</kbd> + that key types `{` on the Amiga — even though the Amiga's own
keyboard would make `{` a completely different way. You never have to learn the
Amiga's keyboard: you just read your MEGA65 caps.

This mode is the right choice for almost everyone, and especially if the MEGA65
is the keyboard you know.

### Amiga mode — "same position as a real Amiga"

This mode is **positional**. Each MEGA65 key sends the Amiga key code of the key
that sits in the **same place** on a real Amiga keyboard. The characters then
follow the *Amiga's* own labelling, not the MEGA65's.

The practical difference shows up on the shifted number row and a handful of
punctuation keys. On a real Amiga, <kbd>Shift</kbd>+<kbd>2</kbd> is `@` (not
`"`), <kbd>Shift</kbd>+<kbd>6</kbd> is `^`, <kbd>Shift</kbd>+<kbd>7</kbd> is `&`,
and so on. In Amiga mode you get those Amiga characters, because your fingers are
"standing on" the Amiga keys.

Choose this mode if you grew up on an Amiga and your muscle memory expects the
Amiga layout, or if you are following instructions written for a real Amiga
(some demos and old manuals assume the Amiga's own keymap).

> **Both modes are always faithful to a US/ANSI keyboard.** AExp assumes the
> Amiga's default American keymap, exactly as a real Amiga 500 running Kickstart
> 1.3 does. The two modes differ only in *which* physical key stands for *which*
> Amiga key — not in the underlying Amiga.

---

## Typing every symbol in MEGA65 mode

Because MEGA65 mode is the default and the one most people use, here is the
complete "how do I type that?" table. Read it as: *press these MEGA65 keys, get
this Amiga character.* Letters and the plain digits work exactly as printed, so
they are not repeated here.

### The shifted number row

| You press                                   | Amiga gets |
|---------------------------------------------|:----------:|
| <kbd>Shift</kbd>+<kbd>1</kbd>               | `!`        |
| <kbd>Shift</kbd>+<kbd>2</kbd>               | `"`        |
| <kbd>Shift</kbd>+<kbd>3</kbd>               | `#`        |
| <kbd>Shift</kbd>+<kbd>4</kbd>               | `$`        |
| <kbd>Shift</kbd>+<kbd>5</kbd>               | `%`        |
| <kbd>Shift</kbd>+<kbd>6</kbd>               | `&`        |
| <kbd>Shift</kbd>+<kbd>7</kbd>               | `'`        |
| <kbd>Shift</kbd>+<kbd>8</kbd>               | `(`        |
| <kbd>Shift</kbd>+<kbd>9</kbd>               | `)`        |

Every one of these is simply the symbol printed on the top of the MEGA65 key.
The cap is law.

### The punctuation and symbol keys

Several MEGA65 keys carry a front-face symbol. Hold <kbd>MEGA</kbd> to type it.

| MEGA65 key            | On its own | With <kbd>Shift</kbd> | With <kbd>MEGA</kbd> |
|-----------------------|:----------:|:---------------------:|:--------------------:|
| <kbd>,</kbd>          | `,`        | `<`                   | `~`                  |
| <kbd>.</kbd>          | `.`        | `>`                   | <code>&#124;</code>  |
| <kbd>/</kbd>          | `/`        | `?`                   | `\`                  |
| <kbd>:</kbd>          | `:`        | `[`                   | `{`                  |
| <kbd>;</kbd>          | `;`        | `]`                   | `}`                  |
| <kbd>=</kbd>          | `=`        | `_`                   | `_`                  |
| <kbd>@</kbd>          | `@`        | —                     | `@`                  |
| <kbd>&larr;</kbd> (top-left) | `_` | <code>&#96;</code>    | <code>&#96;</code>   |
| <kbd>&uarr;</kbd>     | `^`        | —                     | —                    |
| <kbd>*</kbd>          | `*`        | —                     | —                    |
| <kbd>+</kbd>          | `+`        |                       |                      |
| <kbd>&minus;</kbd>    | `-`        |                       |                      |
| <kbd>&pound;</kbd>    | `\`        |                       |                      |

A few friendly notes on this table:

* **Curly braces** are `{` = <kbd>MEGA</kbd>+<kbd>:</kbd> and `}` =
  <kbd>MEGA</kbd>+<kbd>;</kbd>, exactly as the little front-face legends show.
  **Square brackets** are the <kbd>Shift</kbd> legends on the same two keys:
  `[` = <kbd>Shift</kbd>+<kbd>:</kbd> and `]` = <kbd>Shift</kbd>+<kbd>;</kbd>.
* The **backslash** `\` can be typed two ways: <kbd>MEGA</kbd>+<kbd>/</kbd> (the
  front-face legend) or the dedicated <kbd>&pound;</kbd> key. Both give `\`,
  because the Amiga's US keymap has no `£`.
* The **underscore** `_` is <kbd>Shift</kbd>+<kbd>=</kbd> or
  <kbd>MEGA</kbd>+<kbd>=</kbd>, and it is also what the top-left
  <kbd>&larr;</kbd> key types on its own.
* The back-tick <code>&#96;</code> lives on the <kbd>&larr;</kbd> key
  (with <kbd>Shift</kbd> or <kbd>MEGA</kbd>).
* A dash `—` means the MEGA65 cap shows a graphic symbol there that the Amiga has
  no character for, so nothing is sent. A blank cell means the key has no such
  legend.

### The keys that were given a helpful job

A handful of MEGA65 keys have no exact Amiga twin, so AExp assigns them the most
natural Amiga meaning:

| MEGA65 key          | Amiga meaning        |
|---------------------|----------------------|
| <kbd>INST/DEL</kbd> | Backspace            |
| <kbd>CLR/HOME</kbd> | Delete               |
| <kbd>&pound;</kbd>  | `\` (backslash)      |
| <kbd>&uarr;</kbd>   | `^` (caret)          |

---

## The special keys (both modes)

These behave the same whichever mapping mode you choose.

| MEGA65 key                                            | Amiga function                          |
|-------------------------------------------------------|-----------------------------------------|
| <kbd>MEGA</kbd>                                       | **Left Amiga** key                      |
| <kbd>RESTORE</kbd>                                    | **Right Amiga** key                     |
| <kbd>Run/Stop</kbd>                                   | **Right mouse button** (hold it)        |
| <kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd>    | **Reset** (Ctrl+Left-Amiga+Right-Amiga) |
| <kbd>Esc</kbd> <kbd>Tab</kbd> <kbd>Caps Lock</kbd>    | Esc, Tab, Caps Lock (as expected)       |
| <kbd>Ctrl</kbd>                                       | Ctrl                                     |
| <kbd>Alt</kbd>                                        | Left Alt                                 |
| Cursor keys                                           | Cursor keys                             |

The famous Amiga three-finger salute — the warm reboot — is
<kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd> here, which is exactly the
Amiga's <kbd>Ctrl</kbd>+<kbd>Left&nbsp;Amiga</kbd>+<kbd>Right&nbsp;Amiga</kbd>.

### Function keys

A real Amiga has ten function keys, <kbd>F1</kbd> to <kbd>F10</kbd>. The MEGA65
keyboard prints only the odd ones and gets the even ones with <kbd>Shift</kbd> —
just as the MEGA65 caps show:

| You press                       | Amiga gets |
|---------------------------------|:----------:|
| <kbd>F1</kbd> … <kbd>F9</kbd> (odd) | F1, F3, F5, F7, F9 |
| <kbd>Shift</kbd>+<kbd>F1</kbd> … | F2, F4, F6, F8, F10 |

The MEGA65 keys past the Amiga's range — <kbd>F11</kbd> and <kbd>F13</kbd> — send
nothing to the Amiga by default. That makes them handy for a job of their own:
opening the AExp menu (see below).

### Amiga keys with no MEGA65 twin

The MEGA65 keyboard is a little shorter than an Amiga's on the right-hand side,
and it has no numeric keypad. In **MEGA65 mode** those Amiga-only keys simply
cannot be typed. In **Amiga mode** the mapping is positional, so all four Amiga
modifier keys become reachable: <kbd>MEGA</kbd> = Left Amiga, <kbd>RESTORE</kbd> =
Right Alt, <kbd>=</kbd> = Right Amiga, <kbd>Alt</kbd> = Left Alt.

---

## Opening the menu — and freeing the Help key

By default you open (and close) the AExp on-screen menu with the
<kbd>Help</kbd> key, exactly like every other MEGA65 core. That is the friendly,
familiar choice and it stays the default.

But on the Amiga, <kbd>Help</kbd> is a *real* key that Amiga software uses. If
you would rather send <kbd>Help</kbd> to the Amiga and open the menu another way,
AExp lets you choose. In the on-screen menu, under **Keyboard**, open the
**`OSM:`** submenu ("key to open the menu") and pick one of:

| Menu opens with          | Notes                                                         |
|--------------------------|--------------------------------------------------------------|
| <kbd>Help</kbd> (default)| The classic MEGA65 choice; <kbd>Help</kbd> also reaches the Amiga. |
| <kbd>F11</kbd>           | Clean: <kbd>F11</kbd> is not an Amiga key, so nothing leaks to the Amiga. |
| <kbd>F13</kbd>           | Clean, same as <kbd>F11</kbd>.                               |
| <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> | A two-key combo; see the caution below.          |

When you pick an alternative, **the <kbd>Help</kbd> key is freed** and goes
straight to the Amiga — which is the whole point. Your choice is saved with your
other settings, so it survives a restart.

<kbd>F11</kbd> and <kbd>F13</kbd> are the recommended alternatives: because they
have no meaning on the Amiga, using them to open the menu never disturbs the
running software. The <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> combo works too, but
both of those keys *are* live Amiga inputs (Left Amiga and the right mouse
button), so the Amiga briefly sees them as you reach for the menu, and the combo
can clash with genuine Amiga use. Prefer a function key unless you have a reason
not to.

However you open the menu, you can always **close** it with the same key, and
<kbd>Run/Stop</kbd> also steps back out of the menu — so you can never lock
yourself out.

---

## No mouse? Steer the pointer from the keyboard

Even without an Amiga mouse you can operate Workbench, because the Amiga's own
operating system can move the pointer from the keyboard. It works in Workbench
and other system-friendly programs (but not in games or demos that take over the
machine).

| Action                      | Keys                                                                   |
|-----------------------------|------------------------------------------------------------------------|
| Move the pointer            | <kbd>MEGA</kbd> + <kbd>&uarr;</kbd> <kbd>&darr;</kbd> <kbd>&larr;</kbd> <kbd>&rarr;</kbd> |
| Move the pointer **faster** | <kbd>MEGA</kbd> + <kbd>Shift</kbd> + arrows                             |
| **Left** mouse button       | <kbd>MEGA</kbd> + <kbd>Alt</kbd>                                        |
| **Right** mouse button      | <kbd>Run/Stop</kbd>                                                     |

<kbd>MEGA</kbd> is the Amiga's Left Amiga key and <kbd>Alt</kbd> is its Left Alt,
so <kbd>MEGA</kbd>+<kbd>Alt</kbd> is exactly the Amiga's built-in "left click".
The pointer keeps accelerating the longer you hold an arrow, so tap for fine
positioning and hold to cross the screen. There is more about the mouse — and a
simple DIY adapter for a real right mouse button — in [mouse.md](mouse.md).

---

## Frequently asked

**Which mode should I use?** Leave it on **MEGA65 mode** unless you specifically
want the Amiga's own key positions. MEGA65 mode means you never have to think:
type what the cap shows.

**I switched modes and a key changed.** That is expected on the shifted number
row and the `: ; @` cluster — those are the keys where the MEGA65 and the Amiga
disagree, and the mode chooses whose labelling wins. Everything else is
identical in both modes.

**Can I change the mode while a program is running?** Yes. The change takes
effect for the next key you press; keys you are already holding are unaffected.

**A shifted symbol didn't come out right in an old diagnostic tool.** A tiny
number of characters are produced by having AExp briefly press
<kbd>Shift</kbd> for you. Normal Amiga software (anything that uses the Amiga's
`keyboard.device`, which is essentially everything) handles this perfectly.
Only a raw, low-level keyboard diagnostic that bypasses the operating system may
notice — and those tools are not what you type documents in.

---

*Under the hood: AExp turns MEGA65 key presses into the Amiga's raw key codes
in* `CORE/vhdl/keyboard.vhd`*, and the Amiga's Kickstart resolves those codes to
characters with its US keymap — exactly the path a real Amiga and every
PS/2-to-Amiga adapter use. The engineering details live in the project's design
notes.*
