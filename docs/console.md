# The console

Programs see one terminal on file descriptors 0, 1, and 2. Under it are a serial port that always works, a framebuffer when the firmware provided one, and a single cooked input line fed by the keyboard and by the serial port.

## Output

`kernel/src/dev/serial.zig` is a 16550 at COM1, 115200 8N1. `main` initializes it before anything else, with port I/O only, so a panic in the rest of boot can still print. Kernel logs and panics go here and nowhere else. The loader used the same port, which is why a few firmware lines precede `zrno boot`.

The framebuffer comes from `BootInfo`: a physical address, width, height, pitch, and depth. `video.capture` copies those fields and turns the physical address into a higher-half pointer. The pixels were reserved in the memory map, and the direct map marks those pages write-combining. A missing buffer, or a depth other than 32 bits, leaves the machine on the serial port alone.

When a screen exists, a write to the terminal draws the glyph and sends the byte to the serial port. `kernel/src/dev/tty_screen.zig` paints glyphs from the font in `kernel/assets`. It erases the glyph under the cursor before drawing the next one. The screen counts soft wraps, so a backspace can climb back to the previous row. A newline or a carriage return resets the count. The screen scrolls when the cursor walks off the bottom.

A write does not block. If the UART cannot accept a byte, the call returns the count it managed to send.

## Input

Input is cooked. Keystrokes accumulate in a line, and a program's `read` sees nothing until Enter.

`kernel/src/dev/tty_input.zig` keeps the line being edited and a ring of committed bytes. The ring is 256 bytes. One slot stays empty so the ring can tell empty from full, and Enter appends a newline, so a line holds at most 254 bytes. A printable byte past that is ignored, and the line already typed still commits on Enter. Printable bytes, backspace, and newline are the only characters that enter the line. Backspace drops the last byte and echoes an erase. Enter commits the line into the ring and wakes anyone sleeping on it.

`read` on the terminal sleeps until the ring has bytes, the same way a pipe read does. It then copies out up to and including the newline. The next read takes the next line. A program that reads one byte at a time still receives the whole line, one byte per call. The shell does exactly that.

Ctrl-C is handled before the line is edited. It discards the partial line and stops the foreground process, which exits with status 130. [Processes and the scheduler](scheduler.md) describes how a `wait` chooses that process.

## Where the bytes come from

Two sources call the same `enqueue`.

The bootstrap processor's timer drains the UART, up to 16 bytes per tick. A carriage return becomes a newline. A newline that follows a carriage return is dropped, so a CRLF is one end of line. Delete (`0x7f`) becomes a backspace. Only that processor polls the port. The other cores' timers do not, so a byte is not delivered twice. See [Several CPUs](smp.md).

The keyboard comes in through the I/O APIC as vector 33, when the FADT says the machine has an 8042. `kernel/src/dev/ps2.zig` decodes the scan code. Backspace (scan `0x0e`) becomes the same erase the serial path uses. The interrupt is routed to the bootstrap processor. A machine without an 8042 skips the driver and is still usable from the serial port.

## Where to read

- `kernel/src/dev/tty.zig`, `kernel/src/dev/tty_input.zig`, `kernel/src/dev/tty_screen.zig`
- `kernel/src/dev/serial.zig`, `kernel/src/dev/video.zig`, `kernel/src/dev/ps2.zig`
- `kernel/src/dev/apic.zig` for the keyboard route
