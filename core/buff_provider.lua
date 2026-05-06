local buff_provider = {}

-- Persistent history of all buffs ever seen (survives buff expiration)
-- Keyed by hash: { [hash] = raw_name_string }
local _buff_history = {}

-- Snapshot of which buffs are currently active on the player. Refreshed only
-- by observe_player_buffs() on a slow tick — never read from a render frame.
-- Keyed by hash: { [hash] = true }
local _active_set = {}

-- Category filter: which categories are visible in dropdowns
-- "skill" is always shown; others default to hidden
local _category_filters = {
    skill    = true,
    paragon  = false,
    talent   = false,
    item     = false,
    npc      = false,
    bsk      = false,
    dungeon  = false,
    passive  = false,
    internal = false,
}

-- Spell-name remap table
local _name_overrides = {}

-- Cached dropdown payload (avoid rebuilding 60x/second while the menu is open)
local _choices_cache       = nil  -- { items, hashes, index_by_hash, filter_sig }
local _choices_cache_until = 0
local _CHOICES_TTL         = 1.0  -- seconds

-- Monotonic version counter -- bumps whenever the buff history changes
-- in a way that consumers (spell_config) need to invalidate their
-- cached dropdown items.  Clear-history bumps it; observing a never-
-- before-seen hash bumps it.  Consumers cache `last_seen_version`
-- and rebuild their items list when it diverges.
local _history_version = 0
local function _bump_version()
    _history_version = _history_version + 1
    _choices_cache = nil  -- always invalidate our own choices cache too
end

local function safe_call(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

local function _now()
    if get_time_since_inject then return get_time_since_inject() end
    return 0
end

local function _filter_signature()
    return string.format('%s%s%s%s%s%s%s%s%s',
        _category_filters.skill    and '1' or '0',
        _category_filters.paragon  and '1' or '0',
        _category_filters.talent   and '1' or '0',
        _category_filters.item     and '1' or '0',
        _category_filters.npc      and '1' or '0',
        _category_filters.bsk      and '1' or '0',
        _category_filters.dungeon  and '1' or '0',
        _category_filters.passive  and '1' or '0',
        _category_filters.internal and '1' or '0')
end

-- Classify a raw buff name into a category
function buff_provider.categorize(raw_name)
    if not raw_name or raw_name == '' then return 'internal' end
    local s = tostring(raw_name)

    -- Hash-only / numeric-only → internal
    if s:match('^Buff #%d+$') or s:match('^%d+$') then return 'internal' end
    if #s <= 2 then return 'internal' end

    local lower = s:lower()

    -- BSK / Infernal Horde
    if lower:match('^bsk') or lower:match('_bsk') then return 'bsk' end

    -- Dungeon affixes
    if lower:match('^dungeon') or lower:match('^affix') or lower:match('dungeon_affix') then return 'dungeon' end

    -- Paragon
    if lower:match('^paragon') or lower:match('_paragon') then return 'paragon' end

    -- Talent
    if lower:match('^talent') or lower:match('_talent') then return 'talent' end

    -- NPC / Actor
    if lower:match('^npc') or lower:match('^actor') or lower:match('_npc_') or lower:match('_actor_') then return 'npc' end

    -- Item / gear slots
    if lower:match('^item_') or lower:match('^item%-') then return 'item' end
    local gear_keywords = { 'amulet', 'helm', 'chest', 'gloves', 'boots', 'pants', 'ring', 'weapon',
                            'offhand', 'shield', 'armor', 'belt', 'bracer', 'shoulder', 'leg_' }
    for _, kw in ipairs(gear_keywords) do
        if lower:match(kw) then return 'item' end
    end

    -- Passives
    if lower:match('^passive') or lower:match('_passive') then return 'passive' end

    -- Internal/engine patterns
    if lower:match('^generic') or lower:match('^world_') or lower:match('^global_')
        or lower:match('^power_') or lower:match('^trait_') then
        return 'internal'
    end

    -- Everything else is a skill/ability buff
    return 'skill'
end

-- Pretty-print a raw buff name: strip class prefix, replace underscores, title case
local function pretty_name(raw)
    if not raw or raw == '' then return raw end
    if _name_overrides[raw] then return _name_overrides[raw] end

    local s = tostring(raw)
    s = s:gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')

    local parts = {}
    for p in s:gmatch('[^_]+') do parts[#parts + 1] = p end

    local class_prefixes = {
        Barbarian = true, Barb = true,
        Druid = true,
        Necro = true, Necromancer = true,
        Paladin = true,
        Rogue = true,
        Sorc = true, Sorcerer = true, Sorceress = true,
        Spiritborn = true, SpiritBorn = true,
        Warlock = true,
    }

    if #parts >= 2 and class_prefixes[parts[1]] then
        table.remove(parts, 1)
    end

    for i, p in ipairs(parts) do
        parts[i] = p:sub(1, 1):upper() .. p:sub(2):lower()
    end

    return table.concat(parts, ' ')
end

-- Extract hash and raw name from a buff object
local function read_buff(b)
    local h = nil
    if type(b.name_hash) == 'number' then
        h = b.name_hash
    elseif type(b.get_name_hash) == 'function' then
        h = safe_call(b.get_name_hash, b)
    end
    if type(h) ~= 'number' or h == 0 then return nil, nil end

    local n = nil
    if type(b.name) == 'function' then
        n = safe_call(b.name, b)
    elseif type(b.get_name) == 'function' then
        n = safe_call(b.get_name, b)
    elseif type(b.name) == 'string' then
        n = b.name
    end
    n = tostring(n or ('Buff #' .. tostring(h)))

    return h, n
end

-- Strip display-only status tags from a name before storing it.
-- These tags ((Not Active), (missing), etc.) are appended at display
-- time; they must never be baked into the stored name or they will
-- be appended again on the next label rebuild, producing doubles.
local function strip_status_tags(name)
    if not name then return name end
    -- Remove everything from '(Not Active)' onward (covers '(Not Active) [cat]')
    local s = tostring(name):gsub('%s*%(Not Active%).*$', '')
    s = s:gsub('%s*%(missing%)%s*$', '')
    s = s:match('^%s*(.-)%s*$') or s  -- trim surrounding whitespace
    return s
end

-- Record a buff into the persistent history (stores everything, filtering is at display time)
local function remember_buff(hash, raw_name)
    if not hash or hash == 0 then return end
    local name = strip_status_tags(raw_name) or _buff_history[hash] or ('Buff #' .. tostring(hash))
    if name == '' then name = _buff_history[hash] or ('Buff #' .. tostring(hash)) end
    _buff_history[hash] = name
end

-- Check if a buff's category is currently visible
local function is_visible(raw_name)
    local cat = buff_provider.categorize(raw_name)
    return _category_filters[cat] or false
end

-- ---- Filter control (called from gui) ----
function buff_provider.set_filter(category, enabled)
    if _category_filters[category] ~= nil and _category_filters[category] ~= enabled then
        _category_filters[category] = enabled
        _choices_cache = nil  -- filter changed, invalidate cache
        return true
    end
    return false
end

function buff_provider.get_filter(category)
    return _category_filters[category] or false
end

function buff_provider.get_all_filters()
    return _category_filters
end

-- ---- Dropdown builders ----

function buff_provider.get_player_buff_choices()
    local now = _now()
    local sig = _filter_signature()
    if _choices_cache and _choices_cache.filter_sig == sig and now < _choices_cache_until then
        return _choices_cache.items, _choices_cache.hashes, _choices_cache.index_by_hash
    end

    local items  = { 'None' }
    local hashes = { 0 }
    local index_by_hash = { [0] = 0 }

    -- Read purely from cached state. The active set is refreshed on a slow
    -- tick by observe_player_buffs(); we do NOT touch live game data here,
    -- so a buff disappearing mid-render can't reach into this code path.
    local active_list = {}
    local inactive_list = {}

    for h, raw in pairs(_buff_history) do
        if is_visible(raw) then
            if _active_set[h] then
                active_list[#active_list + 1] = { name = raw, hash = h, active = true }
            else
                inactive_list[#inactive_list + 1] = { name = raw, hash = h, active = false }
            end
        end
    end

    table.sort(active_list, function(a, b) return a.name < b.name end)
    table.sort(inactive_list, function(a, b) return a.name < b.name end)

    for _, it in ipairs(active_list) do
        local label = pretty_name(it.name)
        items[#items + 1] = label
        hashes[#hashes + 1] = it.hash
        index_by_hash[it.hash] = #items - 1
    end

    for _, it in ipairs(inactive_list) do
        local label = pretty_name(it.name) .. ' (Not Active)'
        items[#items + 1] = label
        hashes[#hashes + 1] = it.hash
        index_by_hash[it.hash] = #items - 1
    end

    _choices_cache = { items = items, hashes = hashes, index_by_hash = index_by_hash, filter_sig = sig }
    _choices_cache_until = now + _CHOICES_TTL

    return items, hashes, index_by_hash
end

function buff_provider.get_available_buffs_and_missing(saved_hash, saved_name)
    local items, hashes, index_by_hash = buff_provider.get_player_buff_choices()

    if type(saved_hash) ~= 'number' then saved_hash = 0 end
    if saved_hash == 0 then
        return items, hashes
    end

    -- Always build a copy so we can reorder without touching the cache.
    -- The configured buff is ALWAYS pinned to position 2 (index 1, 0-based),
    -- right after "None". This makes desired_idx a stable invariant (always 1),
    -- so any stale persisted combo index from a prior session can't go
    -- out-of-range when the new widget is first rendered.
    local items_out  = {}
    local hashes_out = {}
    for i = 1, #items  do items_out[i]  = items[i]  end
    for i = 1, #hashes do hashes_out[i] = hashes[i] end

    local existing_idx = index_by_hash and index_by_hash[saved_hash]
    if existing_idx ~= nil then
        -- Buff is already visible — remove from its current sorted position
        -- so we can re-insert at position 2 below.
        local arr_idx = existing_idx + 1  -- convert 0-based to 1-based
        table.remove(items_out,  arr_idx)
        table.remove(hashes_out, arr_idx)
    end

    local raw_name = strip_status_tags(tostring(saved_name or ''))
    if raw_name == '' then
        raw_name = _buff_history[saved_hash] or ('Buff #' .. tostring(saved_hash))
    end

    remember_buff(saved_hash, raw_name)

    local cat = buff_provider.categorize(raw_name)
    local tag
    if _active_set[saved_hash] then
        tag = ''
    elseif is_visible(raw_name) then
        tag = ' (Not Active)'
    else
        tag = ' (Not Active) [' .. cat .. ']'
    end
    local label = pretty_name(raw_name) .. tag

    table.insert(items_out,  2, label)
    table.insert(hashes_out, 2, saved_hash)

    return items_out, hashes_out
end

-- Search all buff history for entries matching query (case-insensitive).
-- Ignores category filters — returns everything. Useful for discovering
-- buffs that are filtered out of the normal dropdown.
function buff_provider.search_buffs(query)
    if not query or query == '' then
        return { 'None' }, { 0 }
    end
    local q = query:lower()

    local active_list   = {}
    local inactive_list = {}

    for h, raw in pairs(_buff_history) do
        local pn = pretty_name(raw)
        if raw:lower():find(q, 1, true) or pn:lower():find(q, 1, true) then
            if _active_set[h] then
                active_list[#active_list + 1]   = { name = raw, hash = h }
            else
                inactive_list[#inactive_list + 1] = { name = raw, hash = h }
            end
        end
    end

    table.sort(active_list,   function(a, b) return a.name < b.name end)
    table.sort(inactive_list, function(a, b) return a.name < b.name end)

    local items  = { 'None' }
    local hashes = { 0 }

    for _, it in ipairs(active_list) do
        items[#items + 1]  = pretty_name(it.name)
        hashes[#hashes + 1] = it.hash
    end
    for _, it in ipairs(inactive_list) do
        items[#items + 1]  = pretty_name(it.name) .. ' (Not Active)'
        hashes[#hashes + 1] = it.hash
    end

    return items, hashes
end

function buff_provider.get_active_buffs()
    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return {} end

    local buffs = safe_call(player.get_buffs, player) or {}
    local out = {}
    for _, b in ipairs(buffs) do
        local h, n = read_buff(b)
        if h then
            remember_buff(h, n)

            local stacks = nil
            if type(b.stacks) == 'number' then
                stacks = b.stacks
            elseif type(b.get_stacks) == 'function' then
                stacks = safe_call(b.get_stacks, b)
            end
            stacks = tonumber(stacks) or 0

            local rem = nil
            if type(b.get_remaining_time) == 'function' then
                rem = safe_call(b.get_remaining_time, b)
            end
            out[#out + 1] = { name = pretty_name(n), hash = h, stacks = stacks, remaining = rem }
        end
    end
    table.sort(out, function(a, b)
        if a.stacks ~= b.stacks then return a.stacks > b.stacks end
        return a.name < b.name
    end)
    return out
end

-- Cheap periodic observation: scan current player buffs, refresh the cached
-- active-set, and remember any new hashes. This is the ONLY place where
-- player.get_buffs() is called for dropdown purposes — render frames never
-- touch live game data, so a buff disappearing mid-frame can't crash us.
-- Returns true iff a new hash was added to history (callers use that to
-- invalidate downstream dropdown caches).
function buff_provider.observe_player_buffs()
    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return false end

    local buffs = safe_call(player.get_buffs, player)
    if type(buffs) ~= 'table' then return false end

    local new_active = {}
    local added = false

    for _, b in ipairs(buffs) do
        local ok, h, n = pcall(read_buff, b)
        if ok and h then
            new_active[h] = true
            if not _buff_history[h] then
                _buff_history[h] = n or ('Buff #' .. tostring(h))
                added = true
            end
        end
    end

    _active_set = new_active

    if added then
        _bump_version()  -- new buff in history -> invalidate caches everywhere
    end
    return added
end

-- Import buff history from a profile (stores all, filtering at display)
function buff_provider.import_history(history_table)
    if type(history_table) ~= 'table' then return end
    for hash_str, raw_name in pairs(history_table) do
        local h = tonumber(hash_str)
        if h and h ~= 0 and type(raw_name) == 'string' then
            _buff_history[h] = raw_name
        end
    end
end

-- Export buff history for profile save
function buff_provider.export_history()
    local out = {}
    for h, raw_name in pairs(_buff_history) do
        out[tostring(h)] = raw_name
    end
    return out
end

-- Clear history (called on class change).  Bumps the history version
-- so consumers (spell_config) drop their cached items list -- otherwise
-- the GUI would still render with stale hashes that no longer have
-- entries in history, and the combo-box widget could end up with a
-- selected idx greater than the current item count (host-side crash
-- on render).
function buff_provider.clear_history()
    _buff_history = {}
    _active_set = {}
    _bump_version()
end

-- Public version counter for consumers to detect "history changed"
-- without poking at the cache directly.
function buff_provider.get_history_version()
    return _history_version
end

return buff_provider
