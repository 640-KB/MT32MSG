# MT32MSG
Write text from DOS command line to a Roland MT-32's display using an MPU-401 compatible MIDI interface.

### Usage

`MT32MSG String To Write`

![image](https://github.com/user-attachments/assets/deafd088-f564-4b88-bd6d-f38ebb05f60a)

If no command line string, the MT-32 screen is reset to normal display.

### Requirements
- A PC running DOS (real mode) or emulator that includes MPU-401 support (DOSBox, 86Box).
- An MPU-401/UART mode compatible MIDI interface (Roland MPU, [Sound Blaster 16 or later](https://en.wikipedia.org/wiki/Sound_Blaster#Third_generation_Sound_Blasters,_16-bit_ISA_cards) or most 16-bit ISA sound interfaces with MIDI port) at I/O port 330h.
- A Roland MT-32, equivalent or emulator (mt32emu_qt/MUNT, etc).

### How to get
- Download [MT32MSG.COM](https://github.com/640-KB/MT32MSG/releases) from Releases.

### How to build from source
- Use MASM 5.x or 6.x to produce `MT32MSG.COM`:

```
MASM MT32MSG;
LINK MT32MSG;
EXE2BIN MT32MSG.EXE MT32MSG.COM
```

## License

- GNU General Public License v3.0. See [LICENSE](LICENSE).
