local cloud_share = {}

--[[
  Cloud Sharing Module — io.popen + curl (Windows 10 built-in)

  Expected Server API
  -------------------
  POST   /api/profiles
    Headers: Content-Type: application/json, X-API-Key: <key>
    Body:    { "class": "sorcerer", "name": "My Build", "data": "<profile json string>" }
    Returns: { "ok": true, "code": "ABC123", "creator_token": "xxxx" }
          or { "ok": false, "error": "..." }

  PATCH  /api/profiles/:code
    Headers: Content-Type: application/json, X-API-Key: <key>
    Body:    { "data": "<profile json string>", "creator_token": "xxxx" }
    Returns: { "ok": true }
          or { "ok": false, "error": "..." }

  GET    /api/profiles?class=sorcerer
    Headers: X-API-Key: <key>
    Returns: [ { "code": "ABC123", "name": "My Build", "updated_at": "..." }, ... ]

  GET    /api/profiles/:code
    Headers: X-API-Key: <key>
    Returns: { "code": "ABC123", "name": "My Build", "class": "sorcerer", "data": "<json>" }
          or { "ok": false, "error": "..." }
]]

-- ── Configuration ────────────────────────────────────────────────────────────
-- Server lives on the same on-prem box as the warmap server, in its own
-- container on port 8001 (warmap is on 8000).  Source is at /opt/rotation-share
-- on the host; see docker-compose.yml there.  Public-facing URL is fronted
-- by Cloudflare so off-LAN clients can reach it -- the prior LAN IP
-- (http://192.168.10.91:8001) only worked from inside the same network,
-- which is why uploads weren't visible from a different computer.
local BASE_URL = 'https://share.d4data.live'
-- Shared secret embedded in all requests — not real security, just gates access
-- to users who have the plugin. Must match ROTATION_SHARE_API_KEY on the server.
local API_KEY  = '818aa8b191d396da7523ea061076946d81a2d1e821fa3468b57e463057439adc'
-- ─────────────────────────────────────────────────────────────────────────────

local profile_io = require 'core.profile_io'

local _script_root = ''
local _index_path  = ''
-- Keyed by "class:profile_name" → { code, creator_token, display_name }
local _share_index = {}

local function _load_index()
    if _index_path == '' then return end
    local text = profile_io.read_file(_index_path)
    if not text then return end
    local data = profile_io.from_json(text)
    if type(data) == 'table' then _share_index = data end
end

local function _save_index()
    if _index_path == '' then return end
    profile_io.write_file(_index_path, profile_io.to_json(_share_index))
end

function cloud_share.init(script_root)
    _script_root = tostring(script_root or '')
    _index_path  = _script_root .. 'cloud_share_index.json'
    _load_index()
end

-- ── HTTP helpers (blocking — only call from user-triggered code) ──────────────

local function _run(cmd)
    local h = io.popen(cmd, 'r')
    if not h then return nil end
    local out = h:read('*a')
    h:close()
    return out
end

local _tmp_file = nil

local function _write_tmp(body_json)
    _tmp_file = _script_root .. '_cloud_tmp.json'
    return profile_io.write_file(_tmp_file, body_json)
end

local function _rm_tmp()
    if _tmp_file then
        pcall(function() os.remove(_tmp_file) end)
        _tmp_file = nil
    end
end

local function _post(path, body_json)
    if not _write_tmp(body_json) then return nil end
    local cmd = string.format(
        'curl -s -m 15 -X POST "%s%s" -H "Content-Type: application/json" -H "X-API-Key: %s" --data @"%s"',
        BASE_URL, path, API_KEY, _tmp_file
    )
    local out = _run(cmd)
    _rm_tmp()
    return out
end

local function _patch(path, body_json)
    if not _write_tmp(body_json) then return nil end
    local cmd = string.format(
        'curl -s -m 15 -X PATCH "%s%s" -H "Content-Type: application/json" -H "X-API-Key: %s" --data @"%s"',
        BASE_URL, path, API_KEY, _tmp_file
    )
    local out = _run(cmd)
    _rm_tmp()
    return out
end

-- GETs (listing + download) use a short timeout so an unreachable server
-- can't freeze the game thread for 15s on the auto-load path.  Bodies
-- are tiny (listing JSON or a single profile JSON) so 5s is generous.
local function _get(path)
    local cmd = string.format(
        'curl -s -m 5 "%s%s" -H "X-API-Key: %s"',
        BASE_URL, path, API_KEY
    )
    return _run(cmd)
end

-- ── Per-class listing cache (used by the auto-load path) ─────────────────────
-- Stored on disk as cloud_listing_<class>.json so the dropdown can render
-- instantly on script load even when the server is unreachable.

local function _listing_cache_path(class_key)
    return _script_root .. 'cloud_listing_' .. tostring(class_key) .. '.json'
end

function cloud_share.load_cached_listing(class_key)
    if not class_key or tostring(class_key) == '' then return nil end
    if _script_root == '' then return nil end
    local text = profile_io.read_file(_listing_cache_path(class_key))
    if not text then return nil end
    local data = profile_io.from_json(text)
    if type(data) == 'table' then return data end
    return nil
end

function cloud_share.save_cached_listing(class_key, profiles)
    if not class_key or tostring(class_key) == '' then return end
    if _script_root == '' then return end
    profile_io.write_file(
        _listing_cache_path(class_key),
        profile_io.to_json(profiles or {})
    )
end

-- ── Public API ────────────────────────────────────────────────────────────────

local function _idx_key(class_key, profile_name)
    return tostring(class_key) .. ':' .. tostring(profile_name)
end

-- Returns the stored share info for a local profile, or nil if never shared.
function cloud_share.get_share_info(class_key, profile_name)
    return _share_index[_idx_key(class_key, profile_name)]
end

-- Upload (create) or re-upload (update) a profile to the cloud.
-- profile_data_json : the full profile JSON string to store
-- display_name      : human-readable name shown on the listing (only used on create)
-- Returns: { ok=bool, code=string, updated=bool, error=string }
function cloud_share.share(class_key, profile_name, profile_data_json, display_name)
    local info = _share_index[_idx_key(class_key, profile_name)]

    if info and info.code and info.creator_token and info.creator_token ~= '' then
        -- UPDATE existing share
        local body = profile_io.to_json({
            data          = profile_data_json,
            creator_token = info.creator_token,
        })
        local resp = _patch('/api/profiles/' .. info.code, body)
        if not resp or resp == '' then
            return { ok = false, error = 'No response — is the server running?' }
        end
        local result = profile_io.from_json(resp)
        if type(result) == 'table' and result.ok then
            return { ok = true, code = info.code, updated = true }
        end
        -- "profile not found" recovery.  Local index can hold a code
        -- that doesn't exist on this server (e.g. LAN-only upload
        -- when the BASE_URL was the LAN IP, then the user switched
        -- to the public host -- different data store).  Clear the
        -- stale entry and fall through to the CREATE branch so the
        -- profile re-uploads cleanly with a fresh code.
        local err_text = (type(result) == 'table' and result.error) or resp or ''
        if type(err_text) == 'string' and err_text:lower():find('not found', 1, true) then
            _share_index[_idx_key(class_key, profile_name)] = nil
            _save_index()
            -- fall through to CREATE below
        else
            return { ok = false, error = err_text }
        end
    end

    do
        -- CREATE new share
        local body = profile_io.to_json({
            class = class_key,
            name  = display_name or profile_name,
            data  = profile_data_json,
        })
        local resp = _post('/api/profiles', body)
        if not resp or resp == '' then
            return { ok = false, error = 'No response — is the server running?' }
        end
        local result = profile_io.from_json(resp)
        if type(result) == 'table' and result.ok and result.code then
            _share_index[_idx_key(class_key, profile_name)] = {
                code          = result.code,
                creator_token = result.creator_token or '',
                display_name  = display_name or profile_name,
            }
            _save_index()
            return { ok = true, code = result.code, updated = false }
        end
        return { ok = false, error = (type(result) == 'table' and result.error) or resp }
    end
end

-- List profiles available for a class.
-- Returns: array of { code, name, updated_at }, or nil + error_string.
-- updated_at is epoch seconds (number) — caller can os.date() it.
function cloud_share.list(class_key)
    -- Guard: server requires the class param.  Sending an empty value
    -- would 422 from the server but we'd surface a confusing error to
    -- the user; bail early with a clear message instead.
    if class_key == nil or tostring(class_key) == '' then
        return nil, 'class key is empty — cannot list cloud profiles'
    end
    local resp = _get('/api/profiles?class=' .. tostring(class_key))
    if not resp or resp == '' then
        return nil, 'No response — is the server running?'
    end
    local result = profile_io.from_json(resp)
    if type(result) == 'table' then
        -- Accept either a bare array or { profiles = [...] }
        if result[1] ~= nil or (type(result) == 'table' and next(result) == nil) then
            return result, nil
        end
        if type(result.profiles) == 'table' then
            return result.profiles, nil
        end
        if result.error then return nil, result.error end
    end
    return nil, 'Unexpected response format'
end

-- Download a profile by share code.
-- Returns: { ok=bool, data=json_string, name=string, class=string, error=string }
function cloud_share.download(code)
    local resp = _get('/api/profiles/' .. tostring(code))
    if not resp or resp == '' then
        return { ok = false, error = 'No response — is the server running?' }
    end
    local result = profile_io.from_json(resp)
    if type(result) == 'table' and result.data then
        return { ok = true, data = result.data, name = result.name, class = result.class }
    end
    return { ok = false, error = (type(result) == 'table' and result.error) or 'Unexpected response' }
end

return cloud_share
