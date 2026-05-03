local plugin_label   = 'magoogles_universal_rotation'
local plugin_version = '1.0.0'
console.print('Lua Plugin - Magoogles Universal Rotation - v' .. plugin_version)

local gui = {}

local _spell_trees = {}

local function _get_spell_tree(spell_id)
    local id = tostring(spell_id)
    if _spell_trees[id] then return _spell_trees[id] end
    local t = tree_node:new(2)
    _spell_trees[id] = t
    return t
end

local function _pretty_spell_name(raw)
    if not raw or raw == '' then return nil end
    raw = tostring(raw):gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local parts = {}
    for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
    if #parts >= 2 then table.remove(parts, 1) end -- drop class prefix
    local phrase = table.concat(parts, ' ')
    phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
    return phrase
end


local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end
local function sf(min, max, default, key)
    return slider_float:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

-- Sentinel ID for virtual evade spell (won't collide with real spell IDs)
gui.VIRTUAL_EVADE_ID = 999999999

gui.elements = {
    main_tree      = tree_node:new(0),
    enabled        = cb(false, 'enabled'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind        = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind')),

    -- Hold-to-cast: rotation only runs while this key is held
    use_hold_key   = cb(false, 'use_hold_key'),
    hold_keybind   = keybind:new(0x0A, false, get_hash(plugin_label .. '_hold_keybind')),

    global_tree    = tree_node:new(1),
    scan_range     = sf(5.0, 30.0, 16.0, 'scan_range'),
    anim_delay     = sf(0.0, 0.5,  0.05, 'anim_delay'),
    global_min_enemies = si(0, 15, 0, 'global_min_enemies'),
    allow_movement = cb(false, 'allow_movement'),       -- pathfinder.request_move for melee positioning
    respect_orb    = cb(true,  'respect_orb'),          -- only act when orbwalker is active or hold-key is held
    -- WarMachine override: when ON, UR's targeting becomes
    -- AUTHORITATIVE on _G.WARMACHINE_TARGET -- it casts only at
    -- WarMachine's pick (or holds fire if WarMachine has cleared
    -- the target).  When OFF (default), the WarMachine target is
    -- a HINT and UR falls back to its own target_selector when
    -- the hint is missing/invalid.  Turn ON when running
    -- WarMachine activities so combat doesn't pull the bot off
    -- its navigation goal -- WarMachine controls when to fight.
    warmachine_override = cb(false, 'warmachine_override'),
    debug_mode     = cb(false, 'debug_mode'),


    overlay_enabled = cb(true, 'overlay_enabled'),
    overlay_x       = si(0, 3000, 20, 'overlay_x'),
    overlay_y       = si(0, 3000, 20, 'overlay_y'),
    overlay_show_buffs = cb(false, 'overlay_show_buffs'),

    export_profile  = cb(false, 'export_profile'),
    import_profile  = cb(false, 'import_profile'),
    reload_json     = cb(false, 'reload_json'),

    -- Multi-profile controls
    profile_combo   = combo_box:new(0, get_hash(plugin_label .. '_profile_combo')),
    profile_rename  = input_text:new(get_hash(plugin_label .. '_profile_rename')),
    new_profile     = cb(false, 'new_profile'),
    delete_profile  = cb(false, 'delete_profile'),

    equipped_tree  = tree_node:new(1),
    inactive_tree  = tree_node:new(1),
    evade_tree     = tree_node:new(1),

    -- Buff filter checkboxes (controls which categories appear in buff dropdowns)
    buff_filter_tree    = tree_node:new(2),
    bf_paragon          = cb(false, 'bf_paragon'),
    bf_talent           = cb(false, 'bf_talent'),
    bf_item             = cb(false, 'bf_item'),
    bf_npc              = cb(false, 'bf_npc'),
    bf_bsk              = cb(false, 'bf_bsk'),
    bf_dungeon          = cb(false, 'bf_dungeon'),
    bf_passive          = cb(false, 'bf_passive'),
    bf_internal         = cb(false, 'bf_internal'),
}

gui.render = function(spell_config, equipped_ids, all_known_ids, profile_names, active_profile)
    if not gui.elements.main_tree:push('Magoogles Universal Rotation | v' .. plugin_version) then return end

    gui.elements.enabled:render('Enable', 'Enable the universal rotation')
    gui.elements.use_keybind:render('Use keybind', 'Toggle rotation on/off with a key')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind:render('Toggle Key', 'Key to toggle the rotation')
    end

    gui.elements.use_hold_key:render('Hold-to-Cast', 'Rotation only runs while this key is held — lets you move freely when not held. Stacks with Toggle Key (both must be active).')
    if gui.elements.use_hold_key:get() then
        gui.elements.hold_keybind:render('Hold Key', 'Press the key you want to hold to activate the rotation')
    end

    -- ---- Profile Selector ----
    if profile_names and #profile_names > 0 then
        gui.elements.profile_combo:render('Profile', profile_names, 'Switch between saved profiles for this class. Settings update immediately.')
        gui.elements.profile_rename:render('Rename Profile', 'Enter a new name for the active profile', true, 'Apply', 'Save the new profile name')
        gui.elements.new_profile:render('New Profile (copy current)', 'Create a new profile by copying all current settings')
        if #profile_names > 1 then
            gui.elements.delete_profile:render('Delete Current Profile', 'Permanently delete the active profile and switch to another')
        end
    end

    gui.elements.reload_json:render('Reload JSON from disk', 'Re-read the active profile\'s JSON file and apply it now. Use this after a friend shares a profile file — no Lua reload needed.')

    if gui.elements.global_tree:push('Global Settings') then
        gui.elements.scan_range:render('Scan Range (yds)', 'How far to scan for enemies', 1)
        gui.elements.anim_delay:render('Animation Delay (s)', 'Global animation delay after each cast', 2)
        gui.elements.global_min_enemies:render('Global Min Enemies', 'Minimum enemies required globally before any spell fires (0 = off). Per-spell min is also respected — whichever is higher wins.', 1)
        gui.elements.respect_orb:render('Respect Orbwalker', 'Only run the rotation while the orbwalker is in clear/pvp mode (or while Hold-to-Cast is held). Recommended ON to avoid fighting your orbwalker.')
        gui.elements.allow_movement:render('Allow Movement', 'Let the rotation move the character into melee range (pathfinder.request_move). Turn OFF if you want the orbwalker to handle ALL movement.')
        gui.elements.warmachine_override:render('WarMachine Targeting Override',
            'When ON, UR ONLY casts at the target WarMachine has picked '
            .. '(_G.WARMACHINE_TARGET).  No fallback to closest-mob '
            .. 'selection.  Hold fire when WarMachine clears the target. '
            .. 'Turn ON when running WarMachine activities so combat '
            .. 'follows WarMachine\'s priority model (pathing > '
            .. 'objectives > only-fight-when-interfering) instead of '
            .. 'auto-engaging every mob within scan range.')
        gui.elements.debug_mode:render('Debug Mode', 'Print cast info to console')

        gui.elements.overlay_enabled:render('Overlay', 'Show/hide the on-screen overlay')
        if gui.elements.overlay_enabled:get() then
            gui.elements.overlay_x:render('Overlay X', 'Overlay left position (px)', 1)
            gui.elements.overlay_y:render('Overlay Y', 'Overlay top position (px)', 1)
            gui.elements.overlay_show_buffs:render('Show Active Buff List', 'Show active buffs in the overlay')
        end

        gui.elements.export_profile:render('Export class profile', 'Write current settings to a JSON file for sharing')
        gui.elements.import_profile:render('Import class profile', 'Load settings from the class JSON file (overwrites current)')

        -- Buff dropdown filters
        if gui.elements.buff_filter_tree:push('Buff Dropdown Filters') then
            render_menu_header('Skill buffs are always shown. Toggle extra categories below.')
            gui.elements.bf_paragon:render('Show Paragon',         'Include paragon board buffs')
            gui.elements.bf_talent:render('Show Talent',           'Include talent tree buffs')
            gui.elements.bf_item:render('Show Item / Gear',        'Include gear slot and item affix buffs')
            gui.elements.bf_npc:render('Show NPC / Actor',         'Include NPC and actor buffs')
            gui.elements.bf_bsk:render('Show BSK / Horde',         'Include Infernal Horde (BSK) buffs')
            gui.elements.bf_dungeon:render('Show Dungeon Affix',   'Include dungeon affix buffs')
            gui.elements.bf_passive:render('Show Passives',        'Include passive effect buffs')
            gui.elements.bf_internal:render('Show Internal/Other', 'Include unnamed, hash-only, and engine-internal buffs')
            gui.elements.buff_filter_tree:pop()
        end

        gui.elements.global_tree:pop()
    end

    -- ---- Virtual Evade Spell ----
    if gui.elements.evade_tree:push('Evade Spell') then
        render_menu_header('Virtual spell that presses a key (spacebar by default). Participates in the rotation like any other spell.')
        spell_config.render(gui.VIRTUAL_EVADE_ID, 'Evade', equipped_ids, all_known_ids)
        gui.elements.evade_tree:pop()
    end

    local equipped_set = {}
    for _, id in ipairs(equipped_ids) do
        if id and id > 1 then equipped_set[id] = true end
    end

    if gui.elements.equipped_tree:push('Equipped Spells') then
        render_menu_header('These spells are currently on your skill bar.')
        local any = false
        for _, spell_id in ipairs(equipped_ids) do
            if spell_id and spell_id > 1 then
                any = true
                local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                local spell_tree = _get_spell_tree(spell_id)
                if spell_tree:push(name) then
                    spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                    spell_tree:pop()
                end
            end
        end
        if not any then
            render_menu_header('No spells detected on skill bar.')
        end
        gui.elements.equipped_tree:pop()
    end

    if all_known_ids and #all_known_ids > 0 then
        if gui.elements.inactive_tree:push('Other Known Spells') then
            render_menu_header('Spells detected previously but not currently on bar.')
            for _, spell_id in ipairs(all_known_ids) do
                if not equipped_set[spell_id] then
                    local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                    local spell_tree = _get_spell_tree(spell_id)
                    if spell_tree:push(name) then
                        spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                        spell_tree:pop()
                    end
                end
            end
            gui.elements.inactive_tree:pop()
        end
    end

    gui.elements.main_tree:pop()
end

return gui
