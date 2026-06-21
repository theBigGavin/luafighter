# CPS1 Input Injection Limitation (SF2CE)

## Summary

CPS1 games (including SF2CE) have a custom I/O architecture that **prevents Lua read-tap based coin/start injection**. Player controls (joystick + buttons) CAN be injected via IN1 read taps, but system buttons (coin/start) on IN0 are ignored by the game during all observed attract states.

## Technical Analysis

### CPS1 I/O Architecture

CPS1 uses two custom chips for I/O:
- **CPS-A** (0x800000-0x8000FF): IN1 (player controls), IN0 (coin/start), DIP switches
- **CPS-B** (0x800140-0x80017F): Protection chip

The relevant memory map:
```
0x800000-0x800007 → portr("IN1")  – P1/P2 joystick + buttons (via cps1_input_r)
0x800018-0x80001F → r(FUNC(cps1_dsw_r)) – IN0 + DSW (via cps1_dsw_r)
0x800030-0x800037 → w(FUNC(cps1_coinctrl_w)) – Coin control (write only)
```

The `cps1_dsw_r` handler:
```cpp
uint16_t cps_state::cps1_dsw_r(offs_t offset) {
    int in = 0xff;
    switch (offset) {
        case 0: in = m_io_in[0]->read(); break;  // IN0
        case 1: in = m_dsw[0]->read(); break;    // DSWA
        case 2: in = m_dsw[1]->read(); break;    // DSWB
        case 3: in = m_dsw[2]->read(); break;    // DSWC
    }
    return (in << 8) | 0xff;
}
```

### What Was Tested (MAME 0.288)

| Method | IN0 Result | Game Reacts? |
|--------|-----------|-------------|
| Read tap 0x800018 modifying return value (0xFFFF → 0xE7FF) | ✅ Tap works, data modified | ❌ No |
| `field:set_value(1)` on IN0 coin/start | ❌ `port:read()` still 0xFF | ❌ No |
| `natkeyboard:post_utf8("5")` | ❌ IN0 unchanged | ❌ No |
| `natkeyboard:post_utf8("1")` | ❌ IN0 unchanged | ❌ No |
| Direct RAM credit write (14+ addresses) | N/A | ❌ No |
| Write to `0x800030` (cps1_coinctrl_w) | N/A | ❌ No |
| Constant IN0 modification (always clear coin+start bits) | ✅ Tap works | ❌ BREAKS attract cycle |

### Discovered Addresses (SF2CE)

| Purpose | Address | Notes |
|---------|---------|-------|
| P1 Health | `0xFF83E9` | Changes during attract fight (144→0) |
| P2 Health | `0xFF86E9` | Changes during attract fight (144→0) |
| Game State | `0xFF8ABF` | Tracks attract/demo states |
| State Values | 0x00=boot/attract, 0x3C=transition, 0x02/0x16=fight screens, 0x15=idle, 0x03/0x17=second attract |

### Attract Cycle Timeline (SF2CE World 920513)

```
F0-F2940:   state 0x00     (boot + Capcom logo + title + first attract demo intro)
F2940:      state 0x3C     (transition, health initializes to 144/144)
F3060-F4920: state 0x02↔0x16 (attract fight in progress, health decreases)
F4920-F7380: state 0x15     (idle/score display ~41 seconds)
F7380+:      state 0x3C then 0x17↔0x03 (second attract cycle)
```

### Root Cause

The game's VBLANK handler during attract mode **does not check IN0 for coin/start**. Even during non-attract states (0x15, 0x02, 0x16), the read-tap modified values have no effect. This suggests:

1. The game's coin/start detection path is separate from the memory-mapped IN0 read path
2. The CPS-A custom chip manages coin detection via a hardware mechanism (interrupt or direct register access) that the memory read tap can't touch
3. The `field:set_value()` doesn't affect `m_io_in[0]->read()` because CPS1 uses IP_ACTIVE_LOW which bypasses the digital value override

### Verified Working: IN1 Player Controls

Read taps on `0x800000-0x800007` (IN1) DO work for player controls:

```lua
sp:install_read_tap(0x800000, 0x800007, "luafighter_in1", function(off, data, mask)
    return data & ~0x0010  -- Clear P1 Button1 (active-low)
end)
```

Verification shows `IN1=0xFFFE` correctly when injecting P1 Right.

## Recommendations

For the luafighter project, CPS1 input can be handled with:

1. **IN1 (player controls)**: Use read-tap injection — WORKS, use for AI behavior during matches
2. **IN0 (coin/start)**: Currently NOT injectable via Lua API in MAME 0.288
3. **Path forward**: Either patch MAME source to add `coin_insert()` callable, or document CPS1 as a known limitation
4. **Non-CPS1 games**: The current architecture should work for standard MAME drivers

### MAME Source Patch (for future)

The proper fix requires modifying `cps1_dsw_r` in `src/mame/capcom/cps1.cpp`:

```cpp
// Add a Lua-triggered override
bool coin_inserted = false;
READ16_MEMBER(cps_state::cps1_dsw_r) {
    int in = 0xff;
    switch (offset) {
        case 0: 
            in = m_io_in[0]->read();
            if (coin_inserted) { in &= ~0x01; coin_inserted = false; }
            break;
        // ...
    }
    return (in << 8) | 0xff;
}
```

This would allow Lua to call `coin_inserted` to trigger a clean single-frame coin insertion.
