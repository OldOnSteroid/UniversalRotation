# Universal Rotation

A dynamic, priority-based spell rotation engine for Diablo IV. Automatically selects and casts spells based on configurable priorities, targeting modes, buff requirements, resource thresholds, combo chains, and stack-building sequences.

## Features

- **Priority-Based Rotation** — Spells fire in configurable priority order (1 = highest). One cast per frame with global cooldown enforcement.
- **Stack Priority Mode** — Cast a spell at override priority for N casts to build stacks, then automatically revert to normal priority. Counter resets after a configurable idle window. Works universally — no buff selection required.
- **6 Targeting Modes** — Priority (Boss → Elite → Champion → Closest), Closest, Lowest HP, Highest HP, Cleave Center (most enemies in radius), and Cursor (cast at mouse position for transport skills).
- **3 Cast Methods** — Normal (spell API), Key Press (single VK code, for evade-replacement skills), Force Stand Still + Key (hold modifier + press skill slot, for ranged melee skills like Payback/Clash).
- **Evade Aim Direction** — Key Press casts can aim toward the nearest enemy, away from it (flee/orbwalker mode), or leave the cursor as-is.
- **Combo Chains** — Casting spell A temporarily boosts spell B's priority for a configurable duration, enabling skill combos (e.g. Clash → Evade → Clash loop).
- **Buff Requirements** — Restrict a spell to only fire when the player has a specific buff active, with a minimum stack count.
- **Resource Conditions** — Cast spells only when primary resource is above or below a configurable percentage threshold.
- **Multi-Charge Tracking** — Supports spells with multiple charges and independent cooldown tracking.
- **Global & Per-Spell Min Enemies** — Global minimum enemy count that applies to all spells. Per-spell overrides also available. Bosses and Champions always bypass these limits.
- **Virtual Evade Spell** — A special non-spell entry that presses Spacebar (or any key) on a configurable priority, fully integrated with aim direction and all rotation logic.
- **Multi-Profile System** — Multiple named profiles per class with dropdown switching, new profile creation, duplication, deletion, and rename. Profiles save all global and per-spell settings.
- **Cloud Sharing** — Upload your profile to get a short share code, browse community-shared profiles for your class from an in-menu dropdown, or import a friend's profile by pasting their code.
- **Persistent Buff History** — Previously seen buffs are retained in the profile even when inactive, shown as "(Not Active)" in dropdowns so they don't disappear between sessions.
- **Town Safety** — Rotation is fully suppressed in safe zones and town areas.
- **On-Screen Overlay** — Displays equipped spells in priority order, color-coded by status (green = ready, yellow = cooldown, red = unavailable). Shows cast method, target mode, and resource condition tags.
- **Auto Movement** — Moves toward melee targets that are out of range before casting.

## Project Structure

```
UniversalRotation/
├── main.lua                  # Entry point, main loop, multi-profile management
├── gui.lua                   # In-game menu UI rendering
├── core/
│   ├── rotation_engine.lua   # Core combat loop, spell execution, stack counters
│   ├── spell_config.lua      # Per-spell configuration & UI controls
│   ├── spell_tracker.lua     # Cooldown & charge tracking
│   ├── target_selector.lua   # Enemy selection algorithms
│   ├── buff_provider.lua     # Buff detection, name remapping, history persistence
│   ├── cloud_share.lua       # Cloud sharing client (HTTP + on-disk listing cache)
│   └── profile_io.lua        # JSON serialization (pure Lua)
├── API.md                    # _G.UNIVERSAL_ROTATION plugin API reference
├── openapi.yaml              # OpenAPI 3.1 spec for the cloud share server
└── *.json                    # Class profiles (auto-created per class/profile)
```

## Configuration

### Global Settings

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| Enable | Toggle | Off | Master on/off switch |
| Toggle Key | Keybind | Unbound | Optional keybind to toggle the rotation |
| Scan Range | 5–30 yds | 16.0 | Enemy detection radius |
| Animation Delay | 0.0–0.5s | 0.05 | Minimum delay between casts |
| Global Min Enemies | 0–15 | 0 | Minimum enemies required before any spell fires. Bosses/Champions bypass this. |
| Debug Mode | Toggle | Off | Print cast info to console |
| Overlay | Toggle | On | Show on-screen spell status |
| Overlay X / Y | 0–3000 px | 20 / 12 | Overlay screen position |
| Show Buff List | Toggle | Off | Display active buffs on overlay |

### Per-Spell Settings

| Setting | Range | Description |
|---------|-------|-------------|
| Enable | Toggle | Include this spell in the rotation |
| Priority | 1–10 | Cast order — lower number fires first |
| Cast Method | Normal / Key Press / Force Stand Still + Key | How the spell is executed |
| Key (VK code) | 0x01–0xFF | Virtual-key code for Key Press method (default 0x20 = Spacebar) |
| Aim Direction | No Aim / Towards Enemy / Orbwalker Direction | Cursor movement before key press |
| Hold Key (VK code) | 0x01–0xFF | Modifier key for Force Stand Still (default 0x10 = Shift) |
| Skill Slot | Slot 1–6 | Which bar slot key to press for Force Stand Still |
| Self Cast | Toggle | Cast on player position — no target required |
| Spell Type | Auto / Melee / Ranged | Controls whether to move into range before casting |
| Spell Range | 1.0–30.0 yds | Maximum cast distance |
| Target Mode | 6 modes | Priority, Closest, Lowest HP, Highest HP, Cleave Center, Cursor |
| AOE Range | 1.0–20.0 yds | Radius for enemy count and cleave checks |
| Min Enemies | 0–15 | Minimum nearby enemies to trigger this spell (bypassed by bosses/champions) |
| Elite Only | Toggle | Only cast against elites and champions |
| Boss Only | Toggle | Only cast against bosses |
| Require Buff | Toggle | Only cast when player has a specific buff active |
| Buff / Min Stacks | Dropdown / 1–50 | Which buff and minimum stack count required |
| Resource Condition | Toggle | Gate cast on primary resource level |
| Resource Mode | Below % / Above % | Cast when resource is low or high |
| Resource Threshold | 1–100% | Percentage trigger point |
| Health Condition | Toggle | Gate cast on player health percentage |
| Health Mode | Below % / Above % | Below % for defensive cooldowns; Above % for offensive |
| Health Threshold | 1–100% | Percentage of max health trigger point |
| Stack Priority Mode | Toggle | Fire at override priority for N casts to build stacks, then revert |
| Casts Before Reverting | 1–20 | How many casts to use override priority before switching back |
| Override Priority | 1–10 | Priority used during the build phase |
| Counter Reset Window | 0.5–15s | Seconds without casting before the counter resets (out-of-combat reset) |
| Combo Chain | Toggle | After casting this spell, boost another spell's priority |
| Chain Target / Boost | Dropdown / 1–9 | Which spell to boost and by how much |
| Boost Duration | 0.5–10.0s | How long the priority boost lasts |
| Min Cooldown | 0.0–5.0s | Forced minimum cooldown between casts |
| Charges | 1–5 | Number of charges for multi-charge spells |

### Virtual Evade Spell

A special entry at the bottom of each spell list representing a raw key press (default: Spacebar). Fully supports priority, Stack Priority Mode, aim direction, and all other per-spell settings. Does not require a real spell ID and bypasses spell readiness checks.

## Multi-Profile System

Each class supports multiple named profiles. Profiles are stored as separate JSON files and tracked via a per-class manifest file.

- **Switch profiles** via the dropdown in the menu — settings update immediately
- **New Profile** — saves the current profile first, then copies all settings into a new profile
- **Delete Profile** — removes the active profile (disabled when only one profile exists)
- **Rename Profile** — type a new name and click Apply
- Profiles auto-save on class change and on profile switch
- All global settings (including overlay options) are saved and restored per profile

## Cloud Sharing

Profiles can be uploaded and downloaded directly from the in-game menu, so you can publish a build for the community or import one a friend sends you without ever touching a JSON file. All controls live under **Profiles → Cloud Sharing**.

### Sharing your profile

1. Open the active profile you want to publish.
2. Type a public name in the **Display Name** field (or leave it blank to reuse the local profile name).
3. Click **Share Profile**.
4. The menu now shows your **share code** (a short string like `FDHTM2`). Pass that code to anyone who wants your build.
5. Tweak the profile later? The button changes to **Update Cloud Profile** — clicking it re-uploads your latest settings to the same code, so people who already imported can just re-import to get the update.

### Browsing community profiles for your class

The **Cloud Profile** dropdown auto-populates with profiles other players have shared for your current class — you don't have to click anything to fetch the list. The list refreshes automatically:

- on script load,
- whenever your character class changes,
- and right after you share or update your own profile.

A detail line under the dropdown shows the full code and last-updated timestamp for whichever entry is highlighted. Click **Import Selected** to download it; the profile is saved as a new local profile and switched to immediately.

### Importing a code from a friend

If a friend posts a code in chat (or shares one for a different class than the one you're playing), paste it into the **Share Code** field and click **Import Profile**. The downloaded profile is saved under the name the original author gave it.

### Offline / server-down behaviour

The dropdown is backed by a per-class on-disk cache (`cloud_listing_<class>.json` in the script folder), so:

- The most recently seen list is rendered immediately on startup, even before any network call returns.
- If the server is unreachable, the previously cached list stays visible and there is no console spam — you can still browse and import using whatever was cached, and uploads simply fail with a one-line console error.

## Stack Priority Mode — How It Works

Stack Priority Mode lets a spell "override" the normal rotation to build up resources or stacks before settling into steady-state behavior.

**Example — Clash/Resolve rotation:**

| Spell | Normal Priority | Stack Pri | Override Pri | Casts | Reset |
|-------|----------------|-----------|-------------|-------|-------|
| Arb | 1 | off | — | — | — |
| Buffs | 2–4 | off | — | — | — |
| Clash | 5 | ✓ | 1 | 4 | 4s |
| Evade | 6 | off | — | — | — |

- While Clash counter < 4: fires at priority 1 (overrides everything → builds stacks)
- After 4 casts: Clash reverts to priority 5
- Evade (priority 6) fires after Clash, then Combo Chain boosts Clash back to priority 1 — creating the **Clash → Evade → Clash → Evade** loop
- After 4 seconds without casting Clash (out of combat): counter resets, build phase restarts next pull

The cast counter and combo chain boost are independent — the chain boost from Evade does not reset or affect the stack counter.

## Boss & Champion Behavior

Bosses and Champions bypass **all** minimum enemy requirements (both global and per-spell). Every spell configured with `min_enemies > 0` will still fire normally against a boss or champion regardless of how many other enemies are present.

## Supported Classes

| ID | Class |
|----|-------|
| 0 | Sorcerer |
| 1 | Barbarian |
| 2 | Druid |
| 3 | Rogue |
| 6 | Necromancer |
| 7 | Spiritborn |
| 8 | Warlock |
| 9 | Paladin |

## Plugin API

Other scripts (e.g. WarMachine activities) can control UR at runtime through the `_G.UNIVERSAL_ROTATION` global table.  Full reference in [API.md](API.md).

**Quick reference:**

```lua
local UR = _G.UNIVERSAL_ROTATION
if not UR then return end

-- Toggle
UR.set_enabled(true)
UR.get_enabled()                -- → boolean

-- Profiles
UR.get_active_profile()         -- → "Default"
UR.get_profile_names()          -- → { "Default", "Boss Farmer", ... }
UR.set_profile("Boss Farmer")
UR.save_profile()
UR.load_profile()

-- Info
UR.get_class_key()              -- → "warlock", "sorcerer", etc.
UR.get_equipped_spell_ids()     -- → { 12345, 67890, ... }

-- Settings (all have matching get_* counterparts)
UR.set_scan_range(20.0)
UR.set_anim_delay(0.05)
UR.set_global_min_enemies(3)
UR.set_respect_orb(true)
UR.set_allow_movement(false)
UR.set_warmachine_override(true)
UR.set_debug(false)
```

## How It Works

1. **Spell Scanning** — Every 2 seconds, the equipped spell bar is scanned and spell configurations are initialised or loaded from the active profile.
2. **Rotation Tick** — Each frame, spells are sorted by effective priority (accounting for Stack Priority Mode counters and active combo chain boosts), then each spell is checked in order: cooldown, readiness, resource, health, buffs, enemy counts, and target availability. The first spell that passes all checks is cast.
3. **Stack Priority Mode** — Effective priority is recalculated every tick by comparing the spell's cast counter against the configured target. When below target the override priority is used; at or above it the normal priority applies.
4. **Combo Chains** — After a successful cast, if a combo chain is configured, the target spell's effective priority is temporarily reduced (boosted) for the configured duration.
5. **Profile Persistence** — On class change or profile switch, the current profile is saved and the new profile is loaded. All global settings and overlay options are included. Buff history is saved per-profile so previously seen buffs remain available in dropdowns.
6. **Class Change Reset** — When switching characters, all internal state is fully cleared: cooldown timers, charge tracking, chain boosts, and stack priority counters all reset so the new class starts from a clean state.

## License

This project is provided as-is for personal use.
