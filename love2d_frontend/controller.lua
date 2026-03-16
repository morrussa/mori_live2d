local M = {}

local function clamp(x, a, b)
  if x < a then
    return a
  end
  if x > b then
    return b
  end
  return x
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function exp_smooth(current, target, dt, tau)
  if tau == nil or tau <= 0.0 then
    return target
  end
  if dt == nil or dt <= 0.0 then
    return current
  end
  local a = 1.0 - math.exp(-dt / tau)
  return current + (target - current) * a
end

local function noise01(t)
  if _G.love and love.math and love.math.noise then
    return love.math.noise(t)
  end
  -- Fallback: deterministic-ish wobble.
  return (math.sin(t) + 1.0) * 0.5
end

local function find_param(by_name, keywords, opts)
  opts = opts or {}
  local req_vec2 = opts.require_vec2

  local best = nil
  local best_len = 1e9
  for name, p in pairs(by_name or {}) do
    if req_vec2 == nil or (not not p.is_vec2) == (not not req_vec2) then
      local lower = string.lower(name)
      local ok = true
      for _, kw in ipairs(keywords) do
        if not string.find(lower, kw, 1, true) then
          ok = false
          break
        end
      end
      if ok then
        local l = #name
        if l < best_len then
          best = p
          best_len = l
        end
      end
    end
  end
  return best
end

local function find_any(by_name, tries)
  for _, t in ipairs(tries or {}) do
    local p = find_param(by_name, t.keywords or {}, t.opts)
    if p then
      return p
    end
  end
  return nil
end

local function resolve_param(param_by_name, configured_name)
  if not (param_by_name and configured_name and configured_name ~= "") then
    return nil
  end
  if param_by_name[configured_name] then
    return param_by_name[configured_name]
  end
  local want = string.lower(configured_name)
  for name, p in pairs(param_by_name) do
    if string.lower(name) == want then
      return p
    end
  end
  for name, p in pairs(param_by_name) do
    local lower = string.lower(name)
    if string.find(lower, want, 1, true) then
      return p
    end
  end
  return nil
end

local function parse_kv_mapping(path)
  local f = io.open(path, "rb")
  if not f then
    return {}
  end
  local raw = f:read("*a") or ""
  f:close()

  local overrides = {}
  for line in string.gmatch(raw, "([^\r\n]+)") do
    local s = tostring(line)
    -- Trim
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and not s:match("^#") and not s:match("^;") then
      local k, v = s:match("^([%w_%.%-]+)%s*=%s*(.-)%s*$")
      if k and v and k ~= "" then
        -- Strip optional quotes
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if (v:sub(1, 1) == '"' and v:sub(-1, -1) == '"') or (v:sub(1, 1) == "'" and v:sub(-1, -1) == "'") then
          v = v:sub(2, -2)
        end
        local invert = false
        if v:sub(1, 1) == "!" then
          invert = true
          v = v:sub(2)
        end
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" then
          overrides[k] = { name = v, invert = invert }
        end
      end
    end
  end
  return overrides
end

local function try_load_overrides(path)
  if not path or path == "" then
    return {}
  end
  if not file_exists(path) then
    return {}
  end
  -- Optional: allow lua table config.
  if path:sub(-4):lower() == ".lua" then
    local ok, obj = pcall(dofile, path)
    if ok and type(obj) == "table" then
      local out = {}
      for k, v in pairs(obj.mapping or obj) do
        if type(k) == "string" and type(v) == "string" then
          local invert = false
          local name = v
          if name:sub(1, 1) == "!" then
            invert = true
            name = name:sub(2)
          end
          out[k] = { name = name, invert = invert }
        elseif type(k) == "string" and type(v) == "table" and type(v.name) == "string" then
          out[k] = { name = v.name, invert = not not v.invert }
        end
      end
      return out
    end
    return {}
  end
  return parse_kv_mapping(path)
end

local function auto_mapping_path(puppet_path)
  if not puppet_path or puppet_path == "" then
    return nil
  end
  local base = tostring(puppet_path)
  local no_ext = base:gsub("%.[^%.%/\\]+$", "")
  local candidates = {
    base .. ".mori-map",
    no_ext .. ".mori-map",
    no_ext .. ".mori.lua",
  }
  for _, p in ipairs(candidates) do
    if file_exists(p) then
      return p
    end
  end
  return nil
end

local function wrap_param(p, meta)
  if not p then
    return nil
  end
  local w = { param = p }
  if meta then
    for k, v in pairs(meta) do
      w[k] = v
    end
  end
  return w
end

function M.make_mapping(param_by_name, opts)
  opts = opts or {}
  local puppet_path = opts.puppet_path or ""
  local mapping_path = opts.mapping_path or ""

  if mapping_path == "" then
    mapping_path = auto_mapping_path(puppet_path) or ""
  end
  local overrides = try_load_overrides(mapping_path)

  local function auto_invert(key, param)
    if not (key and param and param.name) then
      return false
    end
    if key == "eye_open" or key == "eye_open_l" or key == "eye_open_r" then
      local lower = string.lower(tostring(param.name))
      -- Many puppets expose a "Blink" parameter where 0=open and 1=closed; our controller drives
      -- an "eye_open" semantic (1=open), so auto-invert when we end up mapping to Blink.
      if string.find(lower, "blink", 1, true) and not string.find(lower, "open", 1, true) then
        return true
      end
    end
    return false
  end

  local function pick(key, fallback_tries, meta)
    local ov = overrides[key]
    if ov and type(ov.name) == "string" and ov.name ~= "" then
      local p = resolve_param(param_by_name, ov.name)
      if p then
        local m = {}
        if meta then
          for kk, vv in pairs(meta) do
            m[kk] = vv
          end
        end
        m.invert = not not ov.invert
        m.source = "config"
        return wrap_param(p, m)
      end
    end
    local p = find_any(param_by_name, fallback_tries)
    if p then
      local m = {}
      if meta then
        for kk, vv in pairs(meta) do
          m[kk] = vv
        end
      end
      m.invert = auto_invert(key, p)
      m.source = "fuzzy"
      return wrap_param(p, m)
    end
    return nil
  end

  local m = {}
  m.__mapping_path = mapping_path

  -- Prefer combined vec2 params when available (common in Inochi2D payloads).
  m.head = pick(
    "head",
    {
      { keywords = { "head", "yaw" }, opts = { require_vec2 = true } },
      { keywords = { "head", "pitch" }, opts = { require_vec2 = true } },
      { keywords = { "head" }, opts = { require_vec2 = true } },
    },
    { mode = "vec2_signed" }
  )

  m.body = pick(
    "body",
    {
      { keywords = { "body", "yaw" }, opts = { require_vec2 = true } },
      { keywords = { "body", "pitch" }, opts = { require_vec2 = true } },
      { keywords = { "body" }, opts = { require_vec2 = true } },
    },
    { mode = "vec2_signed" }
  )

  m.head_roll = pick(
    "head_roll",
    {
      { keywords = { "head", "roll" }, opts = { require_vec2 = false } },
      { keywords = { "angle", "z" }, opts = { require_vec2 = false } },
      { keywords = { "rotation", "z" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.head_pitch = pick(
    "head_pitch",
    {
      { keywords = { "head", "pitch" }, opts = { require_vec2 = false } },
      { keywords = { "head", "tilt" }, opts = { require_vec2 = false } },
      { keywords = { "angle", "x" }, opts = { require_vec2 = false } },
      { keywords = { "rotation", "x" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.head_yaw = pick(
    "head_yaw",
    {
      { keywords = { "head", "yaw" }, opts = { require_vec2 = false } },
      { keywords = { "head", "turn" }, opts = { require_vec2 = false } },
      { keywords = { "angle", "y" }, opts = { require_vec2 = false } },
      { keywords = { "rotation", "y" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )

  m.body_roll = pick(
    "body_roll",
    {
      { keywords = { "body", "roll" }, opts = { require_vec2 = false } },
      { keywords = { "body", "angle", "z" }, opts = { require_vec2 = false } },
      { keywords = { "body", "rotation", "z" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.body_pitch = pick(
    "body_pitch",
    {
      { keywords = { "body", "pitch" }, opts = { require_vec2 = false } },
      { keywords = { "body", "tilt" }, opts = { require_vec2 = false } },
      { keywords = { "body", "angle", "x" }, opts = { require_vec2 = false } },
      { keywords = { "body", "rotation", "x" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.body_yaw = pick(
    "body_yaw",
    {
      { keywords = { "body", "yaw" }, opts = { require_vec2 = false } },
      { keywords = { "body", "turn" }, opts = { require_vec2 = false } },
      { keywords = { "body", "angle", "y" }, opts = { require_vec2 = false } },
      { keywords = { "body", "rotation", "y" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )

  m.mouth_open = pick(
    "mouth_open",
    {
      { keywords = { "mouth", "open" }, opts = { require_vec2 = false } },
      { keywords = { "jaw", "open" }, opts = { require_vec2 = false } },
      { keywords = { "mouthopen" }, opts = { require_vec2 = false } },
      { keywords = { "mouth" }, opts = { require_vec2 = false } },
    },
    { mode = "01" }
  )

  m.eye_ball = pick(
    "eye_ball",
    {
      { keywords = { "eye", "ball" }, opts = { require_vec2 = true } },
      { keywords = { "eye", "look" }, opts = { require_vec2 = true } },
      { keywords = { "gaze" }, opts = { require_vec2 = true } },
      { keywords = { "look" }, opts = { require_vec2 = true } },
    },
    { mode = "vec2_signed" }
  )
  m.eye_ball_x = pick(
    "eye_ball_x",
    {
      { keywords = { "eye", "ball", "x" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "look", "x" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "x" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.eye_ball_y = pick(
    "eye_ball_y",
    {
      { keywords = { "eye", "ball", "y" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "look", "y" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "y" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )

  -- Some puppets expose per-eye scalar movement parameters instead of a single vec2 "look" param.
  m.eye_move_l = pick(
    "eye_move_l",
    {
      { keywords = { "eye", "left", "move" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "l", "move" }, opts = { require_vec2 = false } },
      { keywords = { "eyel", "move" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.eye_move_r = pick(
    "eye_move_r",
    {
      { keywords = { "eye", "right", "move" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "r", "move" }, opts = { require_vec2 = false } },
      { keywords = { "eyer", "move" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )
  m.eye_move = pick(
    "eye_move",
    {
      { keywords = { "eye", "move" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )

  m.eye_open_l = pick(
    "eye_open_l",
    {
      { keywords = { "eye", "left", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "l", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eyel", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "lopen" }, opts = { require_vec2 = false } },
      { keywords = { "blink", "left" }, opts = { require_vec2 = false } },
      { keywords = { "blink", "l" }, opts = { require_vec2 = false } },
    },
    { mode = "01" }
  )
  m.eye_open_r = pick(
    "eye_open_r",
    {
      { keywords = { "eye", "right", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "r", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eyer", "open" }, opts = { require_vec2 = false } },
      { keywords = { "eye", "ropen" }, opts = { require_vec2 = false } },
      { keywords = { "blink", "right" }, opts = { require_vec2 = false } },
      { keywords = { "blink", "r" }, opts = { require_vec2 = false } },
    },
    { mode = "01" }
  )
  m.eye_open = pick(
    "eye_open",
    {
      { keywords = { "eye", "open" }, opts = { require_vec2 = false } },
      { keywords = { "blink" }, opts = { require_vec2 = false } },
    },
    { mode = "01" }
  )

  m.breath = pick(
    "breath",
    {
      { keywords = { "breath" }, opts = { require_vec2 = false } },
      { keywords = { "breathe" }, opts = { require_vec2 = false } },
      { keywords = { "chest" }, opts = { require_vec2 = false } },
    },
    { mode = "signed" }
  )

  return m
end

local function unwrap(entry)
  if not entry then
    return nil
  end
  if entry.name then
    return entry
  end
  if entry.param then
    return entry.param
  end
  return nil
end

local function entry_invert(entry)
  if not entry then
    return false
  end
  if entry.invert ~= nil then
    return not not entry.invert
  end
  return false
end

local function set_scalar_signed(api, entry, v_signed)
  if not (api and api.set_param) then
    return
  end
  local p = unwrap(entry)
  if not p then
    return
  end
  local vv = clamp(v_signed or 0.0, -1.0, 1.0)
  if entry_invert(entry) then
    vv = -vv
  end
  local xmin = tonumber(p.xmin) or -1.0
  local xmax = tonumber(p.xmax) or 1.0
  if xmin == xmax then
    xmin, xmax = -1.0, 1.0
  end
  local x = xmin + (vv + 1.0) * 0.5 * (xmax - xmin)
  api.set_param(p.name, x, 0.0)
end

local function set_scalar_01(api, entry, v01)
  if not (api and api.set_param) then
    return
  end
  local p = unwrap(entry)
  if not p then
    return
  end
  local vv = clamp(v01 or 0.0, 0.0, 1.0)
  if entry_invert(entry) then
    vv = 1.0 - vv
  end
  local xmin = tonumber(p.xmin) or 0.0
  local xmax = tonumber(p.xmax) or 1.0
  if xmin == xmax then
    xmin, xmax = 0.0, 1.0
  end
  local x = xmin + vv * (xmax - xmin)
  api.set_param(p.name, x, 0.0)
end

local function set_vec2_signed(api, entry, x_signed, y_signed)
  if not (api and api.set_param) then
    return
  end
  local p = unwrap(entry)
  if not p then
    return
  end
  local xx = clamp(x_signed or 0.0, -1.0, 1.0)
  local yy = clamp(y_signed or 0.0, -1.0, 1.0)
  if entry and entry.invert_x then
    xx = -xx
  end
  if entry and entry.invert_y then
    yy = -yy
  end
  if entry_invert(entry) then
    -- For vec2 signed, treat "invert" as both-axis inversion.
    xx = -xx
    yy = -yy
  end

  local xmin = tonumber(p.xmin) or -1.0
  local xmax = tonumber(p.xmax) or 1.0
  local ymin = tonumber(p.ymin) or -1.0
  local ymax = tonumber(p.ymax) or 1.0
  if xmin == xmax then
    xmin, xmax = -1.0, 1.0
  end
  if ymin == ymax then
    ymin, ymax = -1.0, 1.0
  end
  local x = xmin + (xx + 1.0) * 0.5 * (xmax - xmin)
  local y = ymin + (yy + 1.0) * 0.5 * (ymax - ymin)
  api.set_param(p.name, x, y)
end

function M.default_options()
  return {
    idle_enabled = true,
    mouse_look_enabled = false,
    blink_enabled = true,
    saccade_enabled = true,
    breath_enabled = true,

    head_idle_roll = 0.35,
    head_idle_yaw = 0.25,
    head_idle_pitch = 0.20,
    head_mouse_yaw = 0.45,
    head_mouse_pitch = 0.35,

    body_follow_yaw = 0.35,
    body_follow_pitch = 0.25,
    body_follow_roll = 0.25,

    blink_min_delay = 3.0,
    blink_max_delay = 8.0,
    blink_close_sec = 0.12,
    blink_open_sec = 0.16,

    saccade_min_delay = 0.7,
    saccade_max_delay = 2.2,
    saccade_strength_x = 0.9,
    saccade_strength_y = 0.6,

    smooth_head_tau = 0.18,
    smooth_body_tau = 0.26,
    smooth_eye_tau = 0.10,
    smooth_mouth_tau = 0.06,

    breath_period = 4.0,
    breath_strength = 0.15,
  }
end

local function randf(a, b)
  if _G.love and love.math and love.math.random then
    return love.math.random() * (b - a) + a
  end
  return math.random() * (b - a) + a
end

function M.new(param_by_name, opts)
  opts = opts or {}
  local mapping = M.make_mapping(param_by_name, {
    puppet_path = opts.puppet_path or "",
    mapping_path = opts.mapping_path or "",
  })
  local options = opts.options or M.default_options()

  local ctrl = {
    mapping = mapping,
    options = options,

    head = { roll = 0.0, yaw = 0.0, pitch = 0.0 },
    body = { roll = 0.0, yaw = 0.0, pitch = 0.0 },
    mouth = { v = 0.0 },
    eye = {
      x = 0.0,
      y = 0.0,
      target_x = 0.0,
      target_y = 0.0,
      next_saccade_at = 0.0,
      last_saccade_at = 0.0,
    },
    blink = {
      phase = "idle",
      progress = 0.0,
      delay = randf(options.blink_min_delay, options.blink_max_delay),
    },
  }

  return ctrl
end

local function update_blink(ctrl, dt)
  if not ctrl or not ctrl.blink then
    return 1.0
  end
  local opt = ctrl.options or {}
  if not opt.blink_enabled then
    ctrl.blink.phase = "idle"
    ctrl.blink.progress = 0.0
    ctrl.blink.delay = randf(opt.blink_min_delay or 3.0, opt.blink_max_delay or 8.0)
    return 1.0
  end

  local close_sec = opt.blink_close_sec or 0.12
  local open_sec = opt.blink_open_sec or 0.16
  local b = ctrl.blink

  if b.phase == "idle" then
    b.delay = (b.delay or 0.0) - dt
    if b.delay <= 0.0 then
      b.phase = "closing"
      b.progress = 0.0
    end
    return 1.0
  end

  if b.phase == "closing" then
    b.progress = clamp((b.progress or 0.0) + dt / math.max(1e-6, close_sec), 0.0, 1.0)
    local t = b.progress
    local eased = 1.0 - (1.0 - t) * (1.0 - t)
    if t >= 1.0 then
      b.phase = "opening"
      b.progress = 0.0
    end
    return 1.0 - eased
  end

  -- opening
  b.progress = clamp((b.progress or 0.0) + dt / math.max(1e-6, open_sec), 0.0, 1.0)
  local t = b.progress
  local eased = t * t
  if t >= 1.0 then
    b.phase = "idle"
    b.progress = 0.0
    b.delay = randf(opt.blink_min_delay or 3.0, opt.blink_max_delay or 8.0)
  end
  return eased
end

local function update_saccade(ctrl, t)
  if not ctrl or not ctrl.eye then
    return
  end
  local opt = ctrl.options or {}
  if not opt.saccade_enabled then
    return
  end
  if t >= (ctrl.eye.next_saccade_at or -1.0) or t < (ctrl.eye.last_saccade_at or -1.0) then
    local sx = (randf(-1.0, 1.0)) * (opt.saccade_strength_x or 0.9)
    local sy = (randf(-1.0, 0.7)) * (opt.saccade_strength_y or 0.6)
    ctrl.eye.target_x = sx
    ctrl.eye.target_y = sy
    ctrl.eye.last_saccade_at = t
    ctrl.eye.next_saccade_at = t + randf(opt.saccade_min_delay or 0.7, opt.saccade_max_delay or 2.2)
  end
end

function M.update(api, ctrl, dt, t, mouth_raw, input)
  if not (api and ctrl and ctrl.mapping) then
    return
  end
  dt = clamp(dt or 0.0, 0.0, 0.1)

  local opt = ctrl.options or {}
  local m = ctrl.mapping

  -- Input
  local mx = 0.0
  local my = 0.0
  if input and input.mouse then
    mx = tonumber(input.mouse.x) or 0.0
    my = tonumber(input.mouse.y) or 0.0
  end
  mx = clamp(mx, -1.0, 1.0)
  my = clamp(my, -1.0, 1.0)

  -- Optional external drive (normalized): head/base pose (e.g. from tracking).
  local head_base_roll = 0.0
  local head_base_yaw = 0.0
  local head_base_pitch = 0.0
  if input then
    if type(input.head) == "table" then
      head_base_roll = clamp(tonumber(input.head.roll) or 0.0, -1.0, 1.0)
      head_base_yaw = clamp(tonumber(input.head.yaw) or 0.0, -1.0, 1.0)
      head_base_pitch = clamp(tonumber(input.head.pitch) or 0.0, -1.0, 1.0)
    else
      if input.head_roll ~= nil then
        head_base_roll = clamp(tonumber(input.head_roll) or 0.0, -1.0, 1.0)
      end
      if input.head_yaw ~= nil then
        head_base_yaw = clamp(tonumber(input.head_yaw) or 0.0, -1.0, 1.0)
      end
      if input.head_pitch ~= nil then
        head_base_pitch = clamp(tonumber(input.head_pitch) or 0.0, -1.0, 1.0)
      end
    end
  end

  -- Head target: idle noise + optional mouse follow.
  local head_roll_t = head_base_roll
  local head_yaw_t = head_base_yaw
  local head_pitch_t = head_base_pitch

  if opt.idle_enabled then
    local n1 = noise01(t * 0.7 + 12.3)
    local n2 = noise01(t * 0.9 + 45.6)
    local n3 = noise01(t * 1.1 + 78.9)
    head_roll_t = ((n1 - 0.5) * 2.0) * (opt.head_idle_roll or 0.35)
    head_yaw_t = ((n2 - 0.5) * 2.0) * (opt.head_idle_yaw or 0.25)
    head_pitch_t = ((n3 - 0.5) * 2.0) * (opt.head_idle_pitch or 0.20)
  end

  if opt.mouse_look_enabled then
    head_yaw_t = head_yaw_t + mx * (opt.head_mouse_yaw or 0.45)
    head_pitch_t = head_pitch_t + (-my) * (opt.head_mouse_pitch or 0.35)
  end

  head_roll_t = clamp(head_roll_t, -1.0, 1.0)
  head_yaw_t = clamp(head_yaw_t, -1.0, 1.0)
  head_pitch_t = clamp(head_pitch_t, -1.0, 1.0)

  ctrl.head.roll = exp_smooth(ctrl.head.roll or 0.0, head_roll_t, dt, opt.smooth_head_tau or 0.18)
  ctrl.head.yaw = exp_smooth(ctrl.head.yaw or 0.0, head_yaw_t, dt, opt.smooth_head_tau or 0.18)
  ctrl.head.pitch = exp_smooth(ctrl.head.pitch or 0.0, head_pitch_t, dt, opt.smooth_head_tau or 0.18)

  if m.head then
    set_vec2_signed(api, m.head, ctrl.head.yaw, ctrl.head.pitch)
  end
  set_scalar_signed(api, m.head_roll, ctrl.head.roll)
  set_scalar_signed(api, m.head_yaw, ctrl.head.yaw)
  set_scalar_signed(api, m.head_pitch, ctrl.head.pitch)

  -- Body: follow head (optional).
  if m.body or m.body_yaw or m.body_pitch or m.body_roll then
    local byaw_t = (ctrl.head.yaw or 0.0) * (opt.body_follow_yaw or 0.35)
    local bpitch_t = (ctrl.head.pitch or 0.0) * (opt.body_follow_pitch or 0.25)
    local broll_t = (ctrl.head.roll or 0.0) * (opt.body_follow_roll or 0.25)

    ctrl.body.yaw = exp_smooth(ctrl.body.yaw or 0.0, byaw_t, dt, opt.smooth_body_tau or 0.26)
    ctrl.body.pitch = exp_smooth(ctrl.body.pitch or 0.0, bpitch_t, dt, opt.smooth_body_tau or 0.26)
    ctrl.body.roll = exp_smooth(ctrl.body.roll or 0.0, broll_t, dt, opt.smooth_body_tau or 0.26)

    if m.body then
      set_vec2_signed(api, m.body, ctrl.body.yaw, ctrl.body.pitch)
    end
    set_scalar_signed(api, m.body_yaw, ctrl.body.yaw)
    set_scalar_signed(api, m.body_pitch, ctrl.body.pitch)
    set_scalar_signed(api, m.body_roll, ctrl.body.roll)
  end

  -- Eyes: mouse look or idle saccades.
  local ex_t, ey_t = 0.0, 0.0
  local has_external_look = false
  if input then
    local look = nil
    if type(input.look) == "table" then
      look = input.look
    elseif type(input.eye) == "table" then
      look = input.eye
    end
    if look then
      local lx = clamp(tonumber(look.x) or 0.0, -1.0, 1.0)
      local ly = clamp(tonumber(look.y) or 0.0, -1.0, 1.0)
      ex_t, ey_t = lx, ly
      ctrl.eye.target_x = ex_t
      ctrl.eye.target_y = ey_t
      has_external_look = true
    end
  end

  if (not has_external_look) and opt.mouse_look_enabled then
    ex_t, ey_t = mx, -my
    ctrl.eye.target_x = ex_t
    ctrl.eye.target_y = ey_t
  end

  if (not has_external_look) and (not opt.mouse_look_enabled) then
    update_saccade(ctrl, t)
  end

  ctrl.eye.x = exp_smooth(ctrl.eye.x or 0.0, ctrl.eye.target_x or 0.0, dt, opt.smooth_eye_tau or 0.10)
  ctrl.eye.y = exp_smooth(ctrl.eye.y or 0.0, ctrl.eye.target_y or 0.0, dt, opt.smooth_eye_tau or 0.10)

  if m.eye_ball then
    set_vec2_signed(api, m.eye_ball, ctrl.eye.x, ctrl.eye.y)
  else
    set_scalar_signed(api, m.eye_ball_x, ctrl.eye.x)
    set_scalar_signed(api, m.eye_ball_y, ctrl.eye.y)
  end

  -- Blink: apply on eye-open parameters if present.
  local base_eye_l = 1.0
  local base_eye_r = 1.0
  if input then
    if input.eye_open ~= nil then
      local v = clamp(tonumber(input.eye_open) or 1.0, 0.0, 1.0)
      base_eye_l = v
      base_eye_r = v
    else
      if input.eye_open_l ~= nil then
        base_eye_l = clamp(tonumber(input.eye_open_l) or 1.0, 0.0, 1.0)
      end
      if input.eye_open_r ~= nil then
        base_eye_r = clamp(tonumber(input.eye_open_r) or 1.0, 0.0, 1.0)
      end
    end
  end

  local blink_open = update_blink(ctrl, dt)
  if m.eye_open_l or m.eye_open_r then
    set_scalar_01(api, m.eye_open_l, blink_open * base_eye_l)
    set_scalar_01(api, m.eye_open_r, blink_open * base_eye_r)
  else
    local base_eye = (base_eye_l + base_eye_r) * 0.5
    set_scalar_01(api, m.eye_open, blink_open * base_eye)
  end

  -- Mouth: smooth raw envelope a bit.
  local mouth_t = clamp(mouth_raw or 0.0, 0.0, 1.0)
  ctrl.mouth.v = exp_smooth(ctrl.mouth.v or 0.0, mouth_t, dt, opt.smooth_mouth_tau or 0.06)
  set_scalar_01(api, m.mouth_open, ctrl.mouth.v)

  -- Breath (optional).
  if opt.breath_enabled and m.breath then
    local period = opt.breath_period or 4.0
    local amp = opt.breath_strength or 0.15
    local b = math.sin((t or 0.0) * (2.0 * math.pi) / math.max(0.5, period)) * amp
    set_scalar_signed(api, m.breath, b)
  end
end

-- Back-compat helpers (used by older main.lua).
function M.apply_idle(inochi, mapping, t)
  if not inochi or not mapping then
    return
  end
  local ctrl = M.new({})
  ctrl.mapping = mapping
  ctrl.options.idle_enabled = true
  ctrl.options.mouse_look_enabled = false
  M.update(inochi, ctrl, 1 / 60, t or 0.0, 0.0, nil)
end

function M.apply_mouth(inochi, mapping, mouth)
  if not inochi or not mapping then
    return
  end
  local ctrl = M.new({})
  ctrl.mapping = mapping
  ctrl.options.idle_enabled = false
  ctrl.options.blink_enabled = false
  ctrl.options.saccade_enabled = false
  ctrl.options.breath_enabled = false
  M.update(inochi, ctrl, 1 / 60, 0.0, mouth or 0.0, nil)
end

return M
