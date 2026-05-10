local plugin_label = 'magoogles_universal_rotation'

local spell_config = {}

local _elements = {}
local _buff_name_cache = {}
local _buff_state = {}

-- Per-spell rebuild generation.  Bumped by spell_config.apply so the next
-- get_elements call constructs fresh widgets whose hashes have never been
-- seen by the host before (no persisted state -> constructor default is
-- the value the user actually sees).  Stored per-spell so each import only
-- invalidates the widgets it actually touched.
local _gen = {}

-- Pending constructor defaults from the most recent apply.  get_elements
-- reads from this table when building a new widget set, so the imported
-- values become the visible UI values on the next render.  Cleared once
-- consumed.
local _pending = {}

-- AUTHORITATIVE per-spell config values.  spell_config.apply writes the
-- imported config here; spell_config.get reads from here in preference to
-- the widgets.  This guarantees the rotation engine always sees the
-- imported values immediately, even if the host's widget rebuild somehow
-- doesn't visually reflect them.
--
-- The render path syncs widget changes back to _value so user adjustments
-- (clicking and dragging a slider in the GUI) flow through to the rotation.
-- We use change-detection (last-seen widget value) instead of
-- "current frame is post-apply" flags, because that survives the case
-- where the host's slider widget renders a stale value after rebuild --
-- _value never gets corrupted by the stale read since the widget value
-- never CHANGED across frames, only differed from _value.
local _value = {}
local _last_widget = {}  -- per-spell, per-field value from prior render

local function _spell_gen(spell_id)
    return _gen[tostring(spell_id)] or 0
end

local function _bump_spell_gen(spell_id)
    local id = tostring(spell_id)
    _gen[id] = (_gen[id] or 0) + 1
    return _gen[id]
end

-- Chain state: [spell_id] = { chain_spell_id, chain_boost_amount, chain_duration }
-- These are plain numbers/values so we store them in a side table, not UI elements
local _chain_state = {}

-- Versioned cache for buff dropdown lists. The list is built ONCE per spell on
-- first render after a profile load or filter change, then reused. Bumping
-- _buff_list_version forces every spell to rebuild on its next render.
local _buff_list_version = 0
function spell_config.invalidate_buff_lists()
    _buff_list_version = _buff_list_version + 1
end


local buff_provider = require 'core.buff_provider'
local target_selector = require 'core.target_selector'

local TARGET_MODE_LABELS = { 'Priority', 'Closest', 'Lowest HP', 'Highest HP', 'Cleave Center', 'Cursor' }
local RESOURCE_MODE_LABELS = { 'Below %', 'Above %' }
local CAST_METHOD_LABELS = { 'Normal', 'Key Press', 'Force Stand Still + Key' }
local SKILL_SLOT_LABELS = { 'Slot 1', 'Slot 2', 'Slot 3', 'Slot 4', 'Slot 5', 'Slot 6' }
local EVADE_AIM_LABELS = { 'No Aim (cursor as-is)', 'Towards Next Enemy', 'Orbwalker Direction' }

-- Key press dropdown: labels shown to user, parallel VK code table
local KEY_PRESS_LABELS = { 'Space', 'E', 'Q', 'R', 'F', 'G', 'X', 'Z',
                            '1', '2', '3', '4', '5', '6',
                            'Shift', 'Ctrl', 'Alt',
                            'Mouse4', 'Mouse5' }
local KEY_PRESS_CODES  = { 0x20,   0x45, 0x51, 0x52, 0x46, 0x47, 0x58, 0x5A,
                            0x31,   0x32, 0x33, 0x34, 0x35, 0x36,
                            0x10,   0x11, 0x12,
                            0x05,   0x06 }

-- Hold/modifier key dropdown for Force Stand Still
local HOLD_KEY_LABELS = { 'Shift', 'Ctrl', 'Alt' }
local HOLD_KEY_CODES  = { 0x10,   0x11,  0x12 }

-- Expose tables so other modules can read actual VK codes / labels
spell_config.KEY_PRESS_CODES  = KEY_PRESS_CODES
spell_config.KEY_PRESS_LABELS = KEY_PRESS_LABELS
spell_config.HOLD_KEY_CODES   = HOLD_KEY_CODES
spell_config.HOLD_KEY_LABELS  = HOLD_KEY_LABELS

local function key(spell_id, suffix)
    return plugin_label .. '_spell_' .. tostring(spell_id) .. '_' .. suffix
end

local function _get_buff_state(spell_id)
    local k = tostring(spell_id)
    local st = _buff_state[k]
    if st then return st end
    st = { buff_hash = 0, buff_name = '', last_list_sig = nil }
    _buff_state[k] = st
    return st
end

-- Stack Priority buff state: separate from require_buff so they can track different buffs
local _stack_pri_buff_state = {}

local function _get_stack_pri_buff_state(spell_id)
    local k = tostring(spell_id)
    local st = _stack_pri_buff_state[k]
    if st then return st end
    st = { buff_hash = 0, buff_name = '', last_list_sig = nil }
    _stack_pri_buff_state[k] = st
    return st
end

local function _ensure_stack_pri_buff_combo(e, spell_id, stored_hash)
    stored_hash = stored_hash or 0
    if e.stack_pri_buff_combo and e._sp_buff_hash_for_combo == stored_hash then return end
    local default_idx = (stored_hash ~= 0) and 1 or 0
    e.stack_pri_buff_combo = combo_box:new(default_idx, get_hash(key(spell_id, 'stack_pri_buff_combo_' .. stored_hash)))
    e._sp_buff_hash_for_combo = stored_hash
    _get_stack_pri_buff_state(spell_id).last_list_sig = nil
end

local function _get_chain_state(spell_id)
    local k = tostring(spell_id)
    local cs = _chain_state[k]
    if cs then return cs end
    cs = { target_id = 0, boost = 3, duration = 5.0 }
    _chain_state[k] = cs
    return cs
end

local function _ensure_buff_combo(e, spell_id, stored_hash)
    stored_hash = stored_hash or 0
    if e.buff_combo and e._buff_hash_for_combo == stored_hash then return end
    local default_idx = (stored_hash ~= 0) and 1 or 0
    e.buff_combo = combo_box:new(default_idx, get_hash(key(spell_id, 'buff_combo_' .. stored_hash)))
    e._buff_hash_for_combo = stored_hash
    _get_buff_state(spell_id).last_list_sig = nil
end

local function _ensure_buff_search(e, spell_id)
    local gen = e._buff_search_gen or 0
    if e.buff_search and (e._buff_search_gen_at_create == gen) then return end
    e.buff_search = input_text:new(get_hash(key(spell_id, 'buff_search_' .. gen)))
    e._buff_search_gen_at_create = gen
end

local function _clear_buff_search(e)
    e._buff_search_gen = (e._buff_search_gen or 0) + 1
    e.buff_search = nil  -- recreated with new hash (no prior state) on next render
    e._last_search_text = ''
    e._search_confirmed = false
end

-- Sentinel ID for virtual evade spell
spell_config.VIRTUAL_EVADE_ID = 999999999

local function get_elements(spell_id)
    local id = tostring(spell_id)
    if _elements[id] then return _elements[id] end

    -- Virtual evade spell defaults: disabled, key press mode, spacebar, self-cast
    local is_virtual = (spell_id == spell_config.VIRTUAL_EVADE_ID)
    local default_enabled = not is_virtual  -- virtual starts disabled
    local default_cast_method = is_virtual and 1 or 0  -- 1=Key Press for virtual
    local default_self_cast = is_virtual  -- virtual is always self-cast style

    -- Hash suffix is salted with the per-spell rebuild generation, so each
    -- spell_config.apply (cloud-profile import or local profile switch)
    -- forces the host to construct fresh widget objects with no persisted
    -- state -- ensuring the constructor defaults below (which read from
    -- _pending[id]) are what the user sees on the next render.
    local gen = _spell_gen(spell_id)
    local function h(suffix)
        return get_hash(key(spell_id, suffix .. '_g' .. gen))
    end

    -- Pull constructor defaults from any pending apply.  When _pending[id]
    -- is set, every slider / checkbox / combo below is built with the
    -- imported value as its initial value.  When unset (cold start, first
    -- render of a spell), the hardcoded fallbacks below are used.
    local p = _pending[id] or {}
    local function pv(field, fallback)
        local v = p[field]
        if v == nil then return fallback end
        return v
    end

    local e = {
        enabled      = checkbox:new(pv('enabled', default_enabled), h('enabled')),
        priority     = slider_int:new(1, 10, pv('priority', 5), h('priority')),

        cooldown     = slider_float:new(0.0, 5.0, pv('cooldown', 0.4), h('cooldown')),
        charges      = slider_int:new(1, 5, pv('charges', 1), h('charges')),

        -- Target mode: 0=Priority, 1=Closest, 2=Lowest HP, 3=Highest HP, 4=Cleave Center
        target_mode  = combo_box:new(pv('target_mode', 0), h('target_mode')),

        spell_type   = combo_box:new(pv('spell_type', 0), h('spell_type')),

        range        = slider_float:new(1.0, 30.0, pv('range', 12.0), h('range')),
        aoe_range    = slider_float:new(1.0, 20.0, pv('aoe_range', 6.0),  h('aoe_range')),

        require_buff = checkbox:new(pv('require_buff', false), h('require_buff')),
        buff_combo   = nil,
        buff_search  = nil,
        buff_mode    = combo_box:new(pv('buff_mode', 0), h('buff_mode')),  -- 0=Active, 1=Missing
        buff_stacks  = slider_int:new(1, 50, pv('buff_stacks', 1), h('buff_stacks')),

        elite_only   = checkbox:new(pv('elite_only', false), h('elite_only')),
        boss_only    = checkbox:new(pv('boss_only', false), h('boss_only')),
        min_enemies  = slider_int:new(0, 15, pv('min_enemies', 0), h('min_enemies')),

        -- Self cast: cast on player position, no target needed
        self_cast    = checkbox:new(pv('self_cast', default_self_cast), h('self_cast')),

        -- Combo chain: after casting THIS spell, boost priority of another spell
        use_chain       = checkbox:new(pv('use_chain', false), h('use_chain')),
        chain_combo     = nil,   -- built lazily when equipped_ids list is available
        chain_boost     = slider_int:new(1, 9, pv('chain_boost', 3), h('chain_boost')),
        chain_duration  = slider_float:new(0.5, 10.0, pv('chain_duration', 3.0), h('chain_duration')),

        -- Resource condition
        use_resource      = checkbox:new(pv('use_resource', false), h('use_resource')),
        resource_override = checkbox:new(pv('resource_override', false), h('resource_override')),  -- bypasses all resource checks (assume full)
        resource_type     = combo_box:new(pv('resource_type', 0), h('resource_type')),  -- 0=Primary %, 1=Secondary count (combo points / Warlock 2nd resource)
        resource_mode     = combo_box:new(pv('resource_mode', 1), h('resource_mode')),  -- default: Above %
        resource_pct      = slider_int:new(1, 100, pv('resource_pct', 50), h('resource_pct')),

        -- Health condition
        use_health      = checkbox:new(pv('use_health', false), h('use_health')),
        health_mode     = combo_box:new(pv('health_mode', 0), h('health_mode')),  -- default: Below %
        health_pct      = slider_int:new(1, 100, pv('health_pct', 50), h('health_pct')),

        -- Stack Priority Mode: cast at override priority until condition met, then revert
        use_stack_pri        = checkbox:new(pv('use_stack_pri', false), h('use_stack_pri')),
        stack_pri_use_buff   = checkbox:new(pv('stack_pri_use_buff', false), h('stack_pri_use_buff')),
        stack_pri_buff_combo = nil,  -- built lazily
        stack_pri_count      = slider_int:new(1, 20, pv('stack_pri_count', 4),   h('stack_pri_count')),
        stack_pri_below_pri  = slider_int:new(1, 10, pv('stack_pri_below_pri', 1),   h('stack_pri_below_pri')),
        stack_pri_reset      = slider_float:new(0.5, 15.0, pv('stack_pri_reset', 4.0), h('stack_pri_reset')),
        stack_pri_targeted   = checkbox:new(pv('stack_pri_targeted', false), h('stack_pri_targeted')),

        -- Channeled: when active, rotation holds off so it doesn't interrupt the cast
        is_channeled    = checkbox:new(pv('is_channeled', false), h('is_channeled')),

        -- Use While Traveling: only meaningful for channeled key-press spells
        -- (Whirlwind, Flurry).  When ON, the channeled pipeline drops the
        -- enemy-count / boss-only / elite-only gates so the key stays held
        -- even with no enemies in range, AND skips the per-frame cursor warp
        -- so orbwalker's internal pathing OR your physical mouse drives the
        -- character's travel direction without interference.
        use_while_traveling = checkbox:new(pv('use_while_traveling', false), h('use_while_traveling')),

        -- Cast method: 0=Normal, 1=Key Press, 2=Force Stand Still + Key
        cast_method     = combo_box:new(pv('cast_method', default_cast_method), h('cast_method')),
        evade_key       = combo_box:new(pv('_evade_key_idx', 0), h('evade_key')),  -- index into KEY_PRESS_CODES; default 0 = Space

        -- Evade aim mode (only for Key Press method): 0=no aim, 1=towards enemy, 2=orbwalker direction
        evade_aim_mode  = combo_box:new(pv('evade_aim_mode', 0), h('evade_aim_mode')),

        -- Force Stand Still + Skill slot
        force_hold_key  = combo_box:new(pv('_force_hold_key_idx', 0), h('force_hold_key')),  -- index into HOLD_KEY_CODES; default 0 = Shift
        skill_slot      = combo_box:new(pv('skill_slot', 0), h('skill_slot')),  -- 0=Slot 1 (key '1'), etc.
    }

    _elements[id] = e
    _pending[id] = nil  -- one-shot: defaults consumed
    return e
end

local function _hash_list_sig(hashes)
    if type(hashes) ~= 'table' then return '' end
    local out = {}
    for i = 1, #hashes do
        out[#out + 1] = tostring(hashes[i] or 0)
    end
    return table.concat(out, ',')
end

-- Build the chain spell combo box items from equipped_ids + all_known_ids
-- Returns items (strings), ids (spell_id numbers)
local function _build_chain_items(spell_id, equipped_ids, all_known_ids)
    local items = { 'None' }
    local ids   = { 0 }
    local seen  = {}
    local all   = {}

    local function add_list(list)
        for _, sid in ipairs(list or {}) do
            if sid and sid > 1 and not seen[sid] and sid ~= spell_id then
                seen[sid] = true
                all[#all + 1] = sid
            end
        end
    end
    add_list(equipped_ids)
    add_list(all_known_ids)

    for _, sid in ipairs(all) do
        local raw = get_name_for_spell and get_name_for_spell(sid) or tostring(sid)
        -- pretty-print same as gui.lua does
        if raw then
            raw = tostring(raw):gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
            local parts = {}
            for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
            if #parts >= 2 then table.remove(parts, 1) end
            local phrase = table.concat(parts, ' ')
            phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
            raw = phrase
        end
        items[#items + 1] = raw or tostring(sid)
        ids[#ids + 1] = sid
    end

    return items, ids
end

-- Lazy-build (or rebuild) the chain combo for a spell, given available spell lists
local function _ensure_chain_combo(e, spell_id, equipped_ids, all_known_ids)
    -- Always rebuild so new spells appear; we track by spell list signature
    local sig_parts = {}
    for _, sid in ipairs(equipped_ids or {}) do sig_parts[#sig_parts+1] = tostring(sid) end
    local sig = table.concat(sig_parts, ',')

    if e.chain_combo and e._chain_sig == sig then return end

    local cs = _get_chain_state(spell_id)
    e._chain_sig = sig

    -- Build list
    local items, ids = _build_chain_items(spell_id, equipped_ids, all_known_ids)

    -- Determine current index from saved target_id
    local cur_idx = 0
    if cs.target_id and cs.target_id ~= 0 then
        for i, sid in ipairs(ids) do
            if sid == cs.target_id then cur_idx = i - 1; break end
        end
    end

    e.chain_combo = combo_box:new(cur_idx, get_hash(key(spell_id, 'chain_combo')))
    e._chain_ids  = ids
    e._chain_items = items
end

function spell_config.render(spell_id, display_name, equipped_ids, all_known_ids)
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)
    local id = tostring(spell_id)

    e.enabled:render('Enable', 'Enable this spell in the rotation')

    -- Sync the Enable toggle BEFORE the early-return below; otherwise a
    -- user disabling a spell wouldn't propagate to _value (the rest of
    -- the sync block at the bottom of the function never runs in the
    -- disabled branch).
    do
        if not _last_widget[id] then _last_widget[id] = {} end
        if not _value[id] then _value[id] = {} end
        local cur = e.enabled:get()
        if _last_widget[id].enabled ~= nil and _last_widget[id].enabled ~= cur then
            _value[id].enabled = cur
        end
        _last_widget[id].enabled = cur
    end

    if not e.enabled:get() then return end

    e.priority:render('Priority (1=highest)', 'Lower number = cast first')

    -- Cast Method
    e.cast_method:render('Cast Method', CAST_METHOD_LABELS, 'Normal = spell API. Key Press = send a key (evade/spacebar). Force Stand Still + Key = hold modifier + press skill slot key (for ranged melee like Payback, Clash)')
    local cast_method = e.cast_method:get() or 0
    if cast_method == 1 then
        e.evade_key:render('Key', KEY_PRESS_LABELS, 'Key to press (for evade-replacement skills, spacebar, etc.)', 1)
        e.evade_aim_mode:render('Aim Direction', EVADE_AIM_LABELS, 'Where to aim before pressing the key. "Towards Enemy" moves cursor to closest target. "Orbwalker" respects current orb mode (clear=toward, flee=away)', 1)
    elseif cast_method == 2 then
        e.force_hold_key:render('Hold Modifier', HOLD_KEY_LABELS, 'Modifier key to hold while pressing the skill slot key. Cursor moves to selected target before casting.', 1)
        e.skill_slot:render('Skill Slot', SKILL_SLOT_LABELS, 'Which skill bar slot key to press (1-6)', 1)
    end

    -- Self Cast
    e.self_cast:render('Self Cast', 'Cast on yourself — no target required (useful for buffs, movement, and AoE centered on player)')
    e.is_channeled:render('Channeled Spell', 'When this spell is actively channeling, the rotation holds off and lets it run. When the channel ends it re-casts automatically. Use for Incinerate, Flurry, and any hold-to-cast skill.')

    -- Use While Traveling: surfaced whenever Channeled Spell is on so the
    -- option is discoverable without users having to flip cast_method
    -- first.  Only actually does something when paired with Cast Method =
    -- Key Press (which is what holds the skill-bar key down for
    -- Whirlwind / Flurry); the tooltip spells that out.
    if e.is_channeled:get() then
        e.use_while_traveling:render('Use While Traveling',
            'For hold-to-cast channels like Whirlwind / Flurry.  Keep the channel running even when no enemies are in range -- resource and health gates still apply, so the channel pauses when you run out of fury / mana.  REQUIRES Cast Method = Key Press with the skill-bar key for the channel selected; the rotation only holds keys, not Normal-API casts.  Pair with Aim Direction = No Aim (cursor as-is) for orbwalker / manual travel; pick Towards Enemy or Orbwalker Direction if you want auto-aim while channeling.')
        -- Inline warning when the user has the option on but the rest of
        -- the config doesn't actually engage the channeled key-hold
        -- pipeline -- by far the most common setup mistake (the spell
        -- silently spam-casts via Normal API instead).
        if e.use_while_traveling:get() and (cast_method or 0) ~= 1 then
            render_menu_header(
                '!! Use While Traveling has no effect: Cast Method must be set to '
                .. '"Key Press" with the skill-bar key selected.  Currently using '
                .. '"' .. (CAST_METHOD_LABELS[(cast_method or 0) + 1] or '?') .. '".')
        end
    end

    local is_self = e.self_cast:get()

    -- Spell type & range only relevant for non-self casts
    if not is_self then
        e.spell_type:render('Spell type', { 'Auto', 'Melee', 'Ranged' }, 'Auto = default; Melee will move into range before casting')

        local stype = e.spell_type:get() or 0
        local range_label = (stype == 1) and 'Engage range (yds)' or 'Spell range (yds)'
        local range_tip = (stype == 1) and 'Melee: will move toward the closest valid enemy until within this range' or 'Skip this spell if no valid enemy is within this range'
        e.range:render(range_label, range_tip, 1)

        -- Target mode
        e.target_mode:render('Target Mode', TARGET_MODE_LABELS, 'How to select which enemy to target for this spell. Cursor = cast at mouse cursor position (for Teleport, Advance, etc.)')

        local tmode = e.target_mode:get() or 0
        if tmode == 5 then
            -- Cursor mode: no aoe/cleave settings needed, just range
        elseif tmode == target_selector.MODE_CLEAVE then
            e.aoe_range:render('Cleave radius (yds)', 'Picks the enemy with the most others within this radius', 1)
        else
            e.aoe_range:render('AOE check radius (yds)', 'Count enemies within this radius of your character (used for Min enemies)', 1)
        end
    else
        -- For self-cast, still show aoe range for min_enemies check
        e.aoe_range:render('AOE check radius (yds)', 'Count enemies within this radius of your character (used for Min enemies)', 1)
    end

    e.min_enemies:render('Min enemies near you', 'Minimum enemies within AOE check radius (0 = always)', 2)

    -- ---- Buff Condition (Require / Missing) ----
    e.require_buff:render('Buff Condition', 'Gate this spell on a buff being active OR missing on you. Use "Missing" mode to cast a spell to apply/refresh a buff.')
    if e.require_buff:get() then
        local stored_hash = st.buff_hash or 0
        local stored_name = st.buff_name
        if (not stored_name or stored_name == '') then
            stored_name = _buff_name_cache[tostring(spell_id)] or ''
        end

        -- Search input sits directly below the Buff Condition checkbox.
        -- When non-empty the main buff combo shows search results instead
        -- of the normal filtered list, so the user can find any buff by
        -- name without adjusting category filters.
        _ensure_buff_search(e, spell_id)
        pcall(function()
            e.buff_search:render('Search Buffs', 'Type to filter the buff list below by name (searches all categories)', false, '', '')
        end)
        local search_text = ''
        pcall(function() search_text = e.buff_search:get() or '' end)

        -- When search text changes, clear confirmed state and force the
        -- normal-mode sig to re-fire set(desired_idx) on re-entry.
        if not e._last_search_text then e._last_search_text = '' end
        if search_text ~= e._last_search_text then
            e._search_confirmed = false
            st.last_list_sig = nil
            e._last_search_text = search_text
        end

        local in_search = (#search_text > 0) and not e._search_confirmed

        if in_search then
            -- ---- Search mode ----
            local s_items, s_hashes = buff_provider.search_buffs(search_text)

            -- Tie the combo widget to the exact query string.  Each distinct
            -- query gets its own hash, so changing the text (including
            -- backspace) always creates a fresh widget starting at index 0.
            -- A stale index from a prior query can never auto-apply a wrong buff.
            local s_combo = combo_box:new(0, get_hash(key(spell_id, 'buff_search_' .. search_text)))

            local cur = s_combo:get()
            if type(cur) == 'number' and cur >= #s_items then
                pcall(s_combo.set, s_combo, 0)
            end
            local rok = pcall(function()
                s_combo:render('Buff', s_items,
                    'Search results — select a buff to configure it as the buff condition.')
            end)
            if not rok then pcall(s_combo.set, s_combo, 0) end

            local sel = s_combo:get()
            if type(sel) ~= 'number' then sel = 0 end
            local sel_hash = s_hashes[sel + 1] or 0
            if sel_hash ~= 0 then
                local label = tostring(s_items[sel + 1] or ''):gsub('%s*%(Not Active%)%s*$', '')
                st.buff_hash = sel_hash
                st.buff_name = label
                _buff_name_cache[tostring(spell_id)] = label
                e._buff_items = nil
                e._buff_hashes = nil
                e._buff_list_v = nil
                -- Clear the search box and switch back to normal mode
                _clear_buff_search(e)
            end
        else
            -- ---- Normal mode ----
            -- Combo widget is keyed to the stored buff hash; changing which
            -- buff is configured creates a fresh widget (no stale persisted index).
            _ensure_buff_combo(e, spell_id, stored_hash)

            -- get_available_buffs_and_missing always places the saved buff at
            -- position 2 (index 1, 0-based), making desired_idx a stable invariant.
            if e._buff_list_v ~= _buff_list_version or not e._buff_items then
                e._buff_items, e._buff_hashes = buff_provider.get_available_buffs_and_missing(stored_hash, stored_name)
                e._buff_list_v = _buff_list_version
            end
            local items, hashes = e._buff_items, e._buff_hashes

            local desired_idx = 0
            if stored_hash ~= 0 then
                for i = 1, #hashes do
                    if hashes[i] == stored_hash then
                        desired_idx = i - 1
                        break
                    end
                end
            end

            local sig = tostring(desired_idx) .. '|' .. _hash_list_sig(hashes)
            if st.last_list_sig ~= sig then
                if type(e.buff_combo.set) == 'function' then
                    pcall(e.buff_combo.set, e.buff_combo, desired_idx)
                end
                st.last_list_sig = sig
            else
                local cur = e.buff_combo:get()
                if type(cur) == 'number' then
                    local cur_hash = hashes[cur + 1] or 0
                    if cur_hash ~= stored_hash then
                        if type(e.buff_combo.set) == 'function' then
                            pcall(e.buff_combo.set, e.buff_combo, desired_idx)
                        end
                    end
                end
            end

            local cur = e.buff_combo:get()
            if type(cur) == 'number' and cur >= #items then
                if type(e.buff_combo.set) == 'function' then
                    pcall(e.buff_combo.set, e.buff_combo, 0)
                end
            end
            local rok = pcall(function()
                e.buff_combo:render('Buff', items,
                    'Buff must be active on you to cast. Previously seen buffs are retained even when inactive.')
            end)
            if not rok and type(e.buff_combo.set) == 'function' then
                pcall(e.buff_combo.set, e.buff_combo, 0)
            end

            local sel = e.buff_combo:get()
            if type(sel) ~= 'number' then sel = 0 end
            local sel_hash = hashes[sel + 1] or 0

            st.buff_hash = sel_hash

            if sel_hash ~= 0 then
                local label = items[sel + 1] or ''
                label = tostring(label)
                    :gsub('%s*%(Not Active%)%s*$', '')
                    :gsub('%s*%(missing%)%s*$', '')
                _buff_name_cache[tostring(spell_id)] = label
                st.buff_name = label
            end
        end

        e.buff_mode:render('Mode', { 'Active (have buff)', 'Missing (need buff)' },
            'Active = only cast when buff is on you with at least Min stacks. Missing = only cast when buff is absent or below Min stacks (use to apply/refresh the buff).')
        local mode = e.buff_mode:get() or 0
        if mode == 0 then
            e.buff_stacks:render('Min stacks', 'Minimum buff stacks required to cast', 1)
        else
            e.buff_stacks:render('Cast if below stacks', 'Cast if buff is missing OR has fewer than this many stacks', 1)
        end
    end

    -- ---- Resource Condition ----
    e.use_resource:render('Resource Condition', 'Only cast when a resource meets a threshold')
    if e.use_resource:get() then
        e.resource_override:render('Override (assume full)', 'Bypass the resource check entirely — always treats the resource as if it is full/maxed. Use when the resource API is broken or unavailable for your class.')
        if not e.resource_override:get() then
        e.resource_type:render('Resource',
            { 'Primary % (mana / fury / spirit)', 'Secondary count (raw)', 'Secondary % (ratio)' },
            'Primary uses get_primary_resource_current/max. Secondary count uses get_secondary_resource_current (falls back to get_rogue_combo_points). Secondary % uses get_secondary_resource_ratio.')
        local rtype = e.resource_type:get() or 0
        if rtype == 0 then
            e.resource_mode:render('Mode', RESOURCE_MODE_LABELS,
                'Below %: cast when resource is low. Above %: cast when resource is high (e.g. spenders)')
            e.resource_pct:render('Threshold %',
                'Percentage of max resource (1-100). Skipped gracefully if API returns 0.')
        elseif rtype == 1 then
            e.resource_mode:render('Mode', { 'Below count', 'At or above count' },
                'Below: cast when count is under the threshold. At/above: cast when count has reached the threshold (e.g. spenders).')
            e.resource_pct:render('Threshold (count)',
                'Raw secondary-resource count (e.g. Warlock essence, Rogue combo points). Set the cutoff here.')
        else
            e.resource_mode:render('Mode', RESOURCE_MODE_LABELS,
                'Below %: cast when secondary resource is low. Above %: cast when secondary resource is high.')
            e.resource_pct:render('Threshold %',
                'Percentage of max secondary resource (1-100). Uses get_secondary_resource_ratio.')
        end
        end  -- end if not resource_override
    end

    -- ---- Health Condition ----
    e.use_health:render('Health Condition', 'Only cast when your health meets a threshold (e.g. defensive cooldowns below 40%, execute spells above 80%)')
    if e.use_health:get() then
        e.health_mode:render('Mode', RESOURCE_MODE_LABELS, 'Below %: cast when health is low (defensive). Above %: cast when healthy (offensive)')
        e.health_pct:render('Threshold %', 'Percentage of max health (1-100)')
    end

    -- ---- Stack Priority Mode ----
    e.use_stack_pri:render('Stack Priority Mode', 'Override this spell\'s priority during a build phase. Build phase ends when a buff reaches target stacks OR after N casts.')
    if e.use_stack_pri:get() then
        e.stack_pri_use_buff:render('Monitor Buff Stacks', 'Use a real buff\'s stack count to control the build phase instead of counting casts. Enable this for abilities like Clash that build Resolve Stacks.')
        if e.stack_pri_use_buff:get() then
            -- Buff-based: show buff picker and target stacks slider
            local sps = _get_stack_pri_buff_state(spell_id)
            local stored_hash = sps.buff_hash or 0
            local stored_name = sps.buff_name or ''
            _ensure_stack_pri_buff_combo(e, spell_id, stored_hash)

            -- Build once per version bump, then reuse
            if e._sp_buff_list_v ~= _buff_list_version or not e._sp_buff_items then
                e._sp_buff_items, e._sp_buff_hashes = buff_provider.get_available_buffs_and_missing(stored_hash, stored_name)
                e._sp_buff_list_v = _buff_list_version
            end
            local items, hashes = e._sp_buff_items, e._sp_buff_hashes

            local desired_idx = 0
            if stored_hash ~= 0 then
                for i = 1, #hashes do
                    if hashes[i] == stored_hash then desired_idx = i - 1; break end
                end
            end

            local sig = tostring(desired_idx) .. '|' .. _hash_list_sig(hashes)
            if sps.last_list_sig ~= sig then
                if type(e.stack_pri_buff_combo.set) == 'function' then
                    pcall(e.stack_pri_buff_combo.set, e.stack_pri_buff_combo, desired_idx)
                end
                sps.last_list_sig = sig
            end

            -- Clamp + pcall, same defensive pattern as buff_combo above.
            local sp_cur = e.stack_pri_buff_combo:get()
            if type(sp_cur) == 'number' and sp_cur >= #items then
                if type(e.stack_pri_buff_combo.set) == 'function' then
                    pcall(e.stack_pri_buff_combo.set, e.stack_pri_buff_combo, 0)
                end
            end
            local sp_rok = pcall(function ()
                e.stack_pri_buff_combo:render('Buff to Monitor', items,
                    'Select the buff whose stacks determine the build phase')
            end)
            if not sp_rok and type(e.stack_pri_buff_combo.set) == 'function' then
                pcall(e.stack_pri_buff_combo.set, e.stack_pri_buff_combo, 0)
            end

            local sel = e.stack_pri_buff_combo:get()
            if type(sel) ~= 'number' then sel = 0 end
            local sel_hash = hashes[sel + 1] or 0
            sps.buff_hash = sel_hash
            if sel_hash ~= 0 then
                local label = tostring(items[sel + 1] or '')
                    :gsub('%s*%(Not Active%)%s*$', ''):gsub('%s*%(missing%)%s*$', '')
                sps.buff_name = label
            end

            e.stack_pri_count:render('Target Stack Count', 'Build phase is active while buff stacks are BELOW this value. Set to your desired max stacks (gear dependent).', 1)
        else
            -- Cast-counter based
            e.stack_pri_count:render('Casts before reverting', 'How many times to cast at the override priority before switching back to normal priority', 1)
            e.stack_pri_reset:render('Counter reset window (s)', 'If this spell hasn\'t been cast within this many seconds, the counter resets and the build phase starts again', 1)
        end
        e.stack_pri_below_pri:render('Override priority', 'Priority used during the build phase (1 = fires before everything else)', 1)
        e.stack_pri_targeted:render('Force targeted cast while building', 'During the build phase use a Normal targeted cast (hits the enemy) regardless of the Cast Method setting above. Useful when the spell must land on a target to generate stacks.', 1)
    end

    -- ---- Combo Chain ----
    e.use_chain:render('Combo Chain', 'After casting this spell, temporarily boost another spell\'s priority')
    if e.use_chain:get() then
        _ensure_chain_combo(e, spell_id, equipped_ids or {}, all_known_ids or {})

        if e.chain_combo and e._chain_items then
            e.chain_combo:render('Chain to Spell', e._chain_items, 'The spell whose priority will be boosted after casting this one')

            -- Sync target_id from combo selection
            local sel = e.chain_combo:get() or 0
            local cs = _get_chain_state(spell_id)
            cs.target_id = (e._chain_ids and e._chain_ids[sel + 1]) or 0
        end

        e.chain_boost:render('Priority Boost', 'How much to reduce the target spell\'s priority number (e.g. 3 = drop from 5 to 2)', 1)
        e.chain_duration:render('Boost Duration (s)', 'How long the priority boost lasts after this spell is cast', 2)
    end

    -- ---- Cooldown / Charges ----
    e.cooldown:render('Min cooldown (s)', 'Minimum seconds between casts once charges are spent', 3)
    e.charges:render('Charges', 'Casts allowed before cooldown applies (1 = normal)', 3)

    -- ---- Filters ----
    if not is_self then
        e.elite_only:render('Elite / Champion only', 'Only cast against elites and champions')
        e.boss_only:render('Boss only', 'Only cast against bosses')
    end

    -- ---- Sync widget changes back into _value ----
    -- spell_config.get reads from _value when present; this loop catches
    -- the user clicking / dragging a slider or toggling a checkbox in the
    -- GUI and writes the new value through.  We use change-detection
    -- (compared against _last_widget) instead of unconditional writes so
    -- a stale widget read on the first post-apply render never overwrites
    -- _value with an old value -- the widget would have to actually CHANGE
    -- across two renders for sync to fire, which only happens when the
    -- user moves it.
    do
        -- id, _last_widget[id], and _value[id] were already initialized in
        -- the enabled-sync block at the top of this function.
        local lw = _last_widget[id]
        local v  = _value[id]

        local function sync(field, cur)
            if lw[field] ~= nil and lw[field] ~= cur then
                v[field] = cur
            end
            lw[field] = cur
        end

        -- enabled is synced earlier in the function so it propagates
        -- through the disabled-spell early-return branch too.
        sync('priority',   e.priority:get())
        sync('cooldown',   e.cooldown:get())
        sync('charges',    e.charges:get())
        sync('spell_type', e.spell_type:get())
        sync('target_mode',e.target_mode:get())
        sync('range',      e.range:get())
        sync('aoe_range',  e.aoe_range:get())
        sync('elite_only', e.elite_only:get())
        sync('boss_only',  e.boss_only:get())
        sync('min_enemies',e.min_enemies:get())
        sync('self_cast',  e.self_cast:get())
        sync('require_buff', e.require_buff:get())
        sync('buff_mode',  e.buff_mode:get())
        sync('buff_stacks',e.buff_stacks:get())
        sync('use_resource',     e.use_resource:get())
        sync('resource_override',e.resource_override:get())
        sync('resource_type',    e.resource_type:get())
        sync('resource_mode',    e.resource_mode:get())
        sync('resource_pct',     e.resource_pct:get())
        sync('use_health', e.use_health:get())
        sync('health_mode',e.health_mode:get())
        sync('health_pct', e.health_pct:get())
        sync('use_chain',     e.use_chain:get())
        sync('chain_boost',   e.chain_boost:get())
        sync('chain_duration',e.chain_duration:get())
        sync('use_stack_pri',     e.use_stack_pri:get())
        sync('stack_pri_use_buff',e.stack_pri_use_buff:get())
        sync('stack_pri_count',   e.stack_pri_count:get())
        sync('stack_pri_below_pri',e.stack_pri_below_pri:get())
        sync('stack_pri_reset',   e.stack_pri_reset:get())
        sync('stack_pri_targeted',e.stack_pri_targeted:get())
        sync('is_channeled', e.is_channeled:get())
        if e.use_while_traveling then sync('use_while_traveling', e.use_while_traveling:get()) end
        sync('cast_method',  e.cast_method:get())
        sync('evade_aim_mode', e.evade_aim_mode:get())
        sync('skill_slot',   e.skill_slot:get())

        -- evade_key / force_hold_key store VK codes in _value but the
        -- widget is a combo with index 0..N.  Sync by translating index
        -- back to VK via the parallel tables.
        local ek_idx = e.evade_key:get() or 0
        local ek_vk  = KEY_PRESS_CODES[ek_idx + 1] or 0x20
        sync('evade_key', ek_vk)
        local fh_idx = e.force_hold_key:get() or 0
        local fh_vk  = HOLD_KEY_CODES[fh_idx + 1] or 0x10
        sync('force_hold_key', fh_vk)
    end
end

function spell_config.get(spell_id)
    local id = tostring(spell_id)
    local e  = get_elements(spell_id)
    local st = _get_buff_state(spell_id)
    local cs = _get_chain_state(spell_id)

    -- Read chain combo selection live (combo widgets DO have :set on this
    -- host, so they reflect imported values correctly without our bypass)
    if e.use_chain and e.use_chain:get() and e.chain_combo and e._chain_ids then
        local sel = e.chain_combo:get() or 0
        cs.target_id = e._chain_ids[sel + 1] or 0
    end

    -- Helper: prefer the authoritative _value entry over the widget read.
    -- _value gets written by spell_config.apply on profile import / switch
    -- AND by the render-time sync when the user adjusts a widget.  Widget
    -- reads are the fallback for spells that have never been through apply
    -- (cold start, never had a saved profile).
    local v = _value[id]
    local function pick(field, widget_val)
        if v ~= nil and v[field] ~= nil then return v[field] end
        return widget_val
    end

    -- evade_key / force_hold_key are stored as VK codes in _value (that's
    -- what the JSON has) but as combo indices in the widget.  When pulling
    -- from _value we want the raw VK; from the widget we have to translate.
    local evade_key_vk
    if v ~= nil and v.evade_key ~= nil then
        evade_key_vk = v.evade_key
    else
        evade_key_vk = KEY_PRESS_CODES[(e.evade_key:get() or 0) + 1] or 0x20
    end
    local force_hold_key_vk
    if v ~= nil and v.force_hold_key ~= nil then
        force_hold_key_vk = v.force_hold_key
    else
        force_hold_key_vk = HOLD_KEY_CODES[(e.force_hold_key:get() or 0) + 1] or 0x10
    end

    return {
        enabled         = pick('enabled',     e.enabled:get()),
        priority        = pick('priority',    e.priority:get()),
        cooldown        = pick('cooldown',    e.cooldown:get()),
        charges         = pick('charges',     e.charges:get()),
        spell_type      = pick('spell_type',  e.spell_type:get()),
        target_mode     = pick('target_mode', e.target_mode:get()),
        range           = pick('range',       e.range:get()),
        aoe_range       = pick('aoe_range',   e.aoe_range:get()),
        elite_only      = pick('elite_only',  e.elite_only:get()),
        boss_only       = pick('boss_only',   e.boss_only:get()),
        min_enemies     = pick('min_enemies', e.min_enemies:get()),
        self_cast       = pick('self_cast',   e.self_cast:get()),

        require_buff    = pick('require_buff', e.require_buff:get()),
        buff_hash       = st.buff_hash or 0,
        buff_name       = (st.buff_name ~= '' and st.buff_name) or (_buff_name_cache[tostring(spell_id)] or ''),
        buff_mode       = pick('buff_mode',   e.buff_mode:get()),     -- 0=Active, 1=Missing
        buff_stacks     = pick('buff_stacks', e.buff_stacks:get()),

        use_resource      = pick('use_resource',      e.use_resource:get()),
        resource_override = pick('resource_override', e.resource_override:get()),
        resource_type     = pick('resource_type',     e.resource_type:get()),
        resource_mode     = pick('resource_mode',     e.resource_mode:get()),
        resource_pct      = pick('resource_pct',      e.resource_pct:get()),

        use_health      = pick('use_health',  e.use_health:get()),
        health_mode     = pick('health_mode', e.health_mode:get()),
        health_pct      = pick('health_pct',  e.health_pct:get()),

        use_chain       = pick('use_chain',      e.use_chain:get()),
        chain_target_id = cs.target_id or 0,
        chain_boost     = pick('chain_boost',    e.chain_boost:get()),
        chain_duration  = pick('chain_duration', e.chain_duration:get()),

        use_stack_pri        = pick('use_stack_pri',        e.use_stack_pri:get()),
        stack_pri_use_buff   = pick('stack_pri_use_buff',   e.stack_pri_use_buff:get()),
        stack_pri_buff_hash  = _get_stack_pri_buff_state(spell_id).buff_hash or 0,
        stack_pri_buff_name  = _get_stack_pri_buff_state(spell_id).buff_name or '',
        stack_pri_count      = pick('stack_pri_count',      e.stack_pri_count:get()),
        stack_pri_below_pri  = pick('stack_pri_below_pri',  e.stack_pri_below_pri:get()),
        stack_pri_reset      = pick('stack_pri_reset',      e.stack_pri_reset:get()),
        stack_pri_targeted   = pick('stack_pri_targeted',   e.stack_pri_targeted:get()),

        is_channeled    = pick('is_channeled', e.is_channeled:get()),
        use_while_traveling = pick('use_while_traveling', e.use_while_traveling and e.use_while_traveling:get()),
        cast_method     = pick('cast_method',  e.cast_method:get()),
        evade_key       = evade_key_vk,
        evade_aim_mode  = pick('evade_aim_mode', e.evade_aim_mode:get()),
        force_hold_key  = force_hold_key_vk,
        skill_slot      = pick('skill_slot',     e.skill_slot:get()),
    }
end

local function _set_element(el, val)
    if not el then return end
    if type(el.set) == 'function' then
        pcall(el.set, el, val)
        return
    end
    if type(el.set_value) == 'function' then
        pcall(el.set_value, el, val)
        return
    end
end

function spell_config.apply(spell_id, cfg)
    if type(cfg) ~= 'table' then return end
    local id = tostring(spell_id)
    local st = _get_buff_state(spell_id)
    local cs = _get_chain_state(spell_id)

    -- Strategy: stash the imported config in _pending[id], destroy the
    -- existing widget set, and bump the spell's hash generation.  The next
    -- get_elements() call (triggered by the next render or rotation tick)
    -- builds a fresh widget set whose every hash is one the host has never
    -- seen -- no persisted state -- with the imported values supplied as
    -- constructor defaults.  This sidesteps the host-side slider widget's
    -- lack of a :set method (the previous "rebuild the one slider" approach
    -- in v1.0.12 wasn't taking effect for users; rebuilding the entire set
    -- with a fresh generation is the bigger hammer that actually works).
    --
    -- Two values need to be remapped from VK code (stored in the JSON) back
    -- to combo index (what combo_box:new wants).  We stash them in _pending
    -- under sentinel keys so get_elements can read them as constructor args.
    local p = {}
    for k, v in pairs(cfg) do p[k] = v end

    if type(cfg.evade_key) == 'number' then
        for i, code in ipairs(KEY_PRESS_CODES) do
            if code == cfg.evade_key then p._evade_key_idx = i - 1; break end
        end
    end
    if type(cfg.force_hold_key) == 'number' then
        for i, code in ipairs(HOLD_KEY_CODES) do
            if code == cfg.force_hold_key then p._force_hold_key_idx = i - 1; break end
        end
    end

    _pending[id] = p
    _bump_spell_gen(spell_id)
    _elements[id] = nil   -- force lazy rebuild on next get_elements

    -- Authoritative copy: spell_config.get reads from here.  Even if the
    -- host's slider rebuild doesn't visually pick up the new defaults, the
    -- rotation engine still sees the imported values.
    _value[id] = p
    _last_widget[id] = nil  -- next render's sync starts fresh; no false-positive sync

    -- Side-table state (buff hash/name, chain target, stack-pri buff) lives
    -- outside the widget set so it survives the rebuild, but we still need
    -- to update it from the imported cfg.
    if type(cfg.stack_pri_buff_hash) == 'number' then
        local sps = _get_stack_pri_buff_state(spell_id)
        sps.buff_hash = cfg.stack_pri_buff_hash
    end
    if type(cfg.stack_pri_buff_name) == 'string' then
        local sps = _get_stack_pri_buff_state(spell_id)
        sps.buff_name = cfg.stack_pri_buff_name:gsub('%s*%(Not Active%).*$', ''):match('^%s*(.-)%s*$') or cfg.stack_pri_buff_name
        sps.last_list_sig = nil
    end

    if type(cfg.buff_hash) == 'number' then st.buff_hash = cfg.buff_hash end
    if type(cfg.buff_name) == 'string' then
        local clean = cfg.buff_name:gsub('%s*%(Not Active%).*$', ''):match('^%s*(.-)%s*$') or cfg.buff_name
        st.buff_name = clean
        if clean ~= '' then _buff_name_cache[tostring(spell_id)] = clean end
    end

    if type(cfg.chain_target_id) == 'number' then cs.target_id = cfg.chain_target_id end

    st.last_list_sig = nil
end

function spell_config.is_virtual(spell_id)
    return spell_id == spell_config.VIRTUAL_EVADE_ID
end

return spell_config
