# Universal Rotation — Plugin API Reference

Other scripts can control Universal Rotation at runtime through the
`_G.UNIVERSAL_ROTATION` global table.  The table is populated when UR
loads, so guard any early-load calls with a nil-check:

```lua
if _G.UNIVERSAL_ROTATION then
    _G.UNIVERSAL_ROTATION.set_enabled(true)
end
```

---

## Toggle

### `set_enabled(value)`
Enable or disable the rotation.

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | `boolean` | `true` to enable, `false` to disable. |

```lua
_G.UNIVERSAL_ROTATION.set_enabled(true)
```

---

### `get_enabled()` → `boolean`
Returns `true` if the rotation is currently enabled (toggle checkbox is on).

```lua
local on = _G.UNIVERSAL_ROTATION.get_enabled()
```

---

## Profiles

### `get_active_profile()` → `string`
Returns the name of the currently loaded profile.

```lua
local name = _G.UNIVERSAL_ROTATION.get_active_profile()
-- e.g. "Default" or "Boss Farmer"
```

---

### `get_profile_names()` → `string[]`
Returns a copy of the ordered profile list for the current class.

```lua
for _, name in ipairs(_G.UNIVERSAL_ROTATION.get_profile_names()) do
    print(name)
end
```

---

### `set_profile(name)`
Switch to a named profile.  Saves the current profile to disk first,
then loads the target profile.  No-op if `name` is already active.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Exact profile name as it appears in `get_profile_names()`. |

```lua
_G.UNIVERSAL_ROTATION.set_profile('Boss Farmer')
```

---

### `save_profile()`
Force-export the active profile to disk immediately (normally happens
automatically on profile switch or class change).

```lua
_G.UNIVERSAL_ROTATION.save_profile()
```

---

### `load_profile()`
Force-reload the active profile from disk, discarding any unsaved
in-memory changes.

```lua
_G.UNIVERSAL_ROTATION.load_profile()
```

---

## Class & Spell Info

### `get_class_key()` → `string`
Returns the slug for the currently logged-in character class.

| Return value | Class |
|---|---|
| `"sorcerer"` | Sorcerer |
| `"barbarian"` | Barbarian |
| `"druid"` | Druid |
| `"rogue"` | Rogue |
| `"necromancer"` | Necromancer |
| `"spiritborn"` | Spiritborn |
| `"warlock"` | Warlock |
| `"paladin"` | Paladin |
| `"class_<n>"` | Unmapped class ID |

```lua
if _G.UNIVERSAL_ROTATION.get_class_key() == 'sorcerer' then
    -- sorcerer-specific logic
end
```

---

### `get_equipped_spell_ids()` → `number[]`
Returns a copy of the spell IDs currently detected on the skill bar.

```lua
local ids = _G.UNIVERSAL_ROTATION.get_equipped_spell_ids()
for _, id in ipairs(ids) do
    print(id)
end
```

---

## Global Settings

All setters write directly to the GUI element, so UR picks up the change
on its next `on_update` tick without a reload.

---

### `get_scan_range()` → `number`
### `set_scan_range(value)`
Enemy scan radius in yards.  Range: `5.0 – 30.0`.

```lua
_G.UNIVERSAL_ROTATION.set_scan_range(20.0)
local r = _G.UNIVERSAL_ROTATION.get_scan_range()
```

---

### `get_anim_delay()` → `number`
### `set_anim_delay(value)`
Global cast delay in seconds applied after every spell fires.  Range: `0.0 – 0.5`.

```lua
_G.UNIVERSAL_ROTATION.set_anim_delay(0.05)
```

---

### `get_global_min_enemies()` → `number`
### `set_global_min_enemies(value)`
Minimum enemy count required before any spell fires.  `0` = off.
Per-spell minimums also apply; whichever is higher wins.  Range: `0 – 15`.

```lua
_G.UNIVERSAL_ROTATION.set_global_min_enemies(3)
```

---

### `get_respect_orb()` → `boolean`
### `set_respect_orb(value)`
When `true`, UR only runs while the orbwalker is in clear or PvP mode
(or while the Hold-to-Cast key is held).

```lua
_G.UNIVERSAL_ROTATION.set_respect_orb(true)
```

---

### `get_allow_movement()` → `boolean`
### `set_allow_movement(value)`
When `true`, UR calls `pathfinder.request_move` to step into melee range.
Set `false` to let the orbwalker handle all movement.

```lua
_G.UNIVERSAL_ROTATION.set_allow_movement(false)
```

---

### `get_warmachine_override()` → `boolean`
### `set_warmachine_override(value)`
When `true`, UR only targets `_G.WARMACHINE_TARGET` and holds fire when
that global is nil.  When `false`, UR falls back to its own
priority-based target selector.  Enable when running WarMachine activities.

```lua
_G.UNIVERSAL_ROTATION.set_warmachine_override(true)
```

---

### `get_debug()` → `boolean`
### `set_debug(value)`
When `true`, cast info and API errors are printed to the console.

```lua
_G.UNIVERSAL_ROTATION.set_debug(true)
```

---

## Example — WarMachine integration snippet

```lua
-- When WarMachine starts an activity, hand targeting control to it
-- and disable movement so pathing decisions stay with WarMachine.
if _G.UNIVERSAL_ROTATION then
    _G.UNIVERSAL_ROTATION.set_warmachine_override(true)
    _G.UNIVERSAL_ROTATION.set_allow_movement(false)
    _G.UNIVERSAL_ROTATION.set_profile('WarMachine')
end

-- Restore defaults when the activity ends
if _G.UNIVERSAL_ROTATION then
    _G.UNIVERSAL_ROTATION.set_warmachine_override(false)
    _G.UNIVERSAL_ROTATION.set_allow_movement(true)
    _G.UNIVERSAL_ROTATION.set_profile('Default')
end
```
