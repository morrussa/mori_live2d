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

local function find_param(by_name, keywords)
  local best = nil
  local best_len = 1e9
  for name, p in pairs(by_name or {}) do
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
  return best
end

function M.make_mapping(param_by_name)
  return {
    head_roll = find_param(param_by_name, { "head", "roll" }),
    head_pitch = find_param(param_by_name, { "head", "pitch" }) or find_param(param_by_name, { "head", "tilt" }),
    head_yaw = find_param(param_by_name, { "head", "yaw" }) or find_param(param_by_name, { "head", "turn" }),
    mouth_open = find_param(param_by_name, { "mouth", "open" }) or find_param(param_by_name, { "mouth" }),
  }
end

local function noise01(t)
  return love.math.noise(t)
end

function M.apply_idle(inochi, mapping, t)
  if not inochi or not mapping then
    return
  end

  local n1 = noise01(t * 0.7 + 12.3)
  local n2 = noise01(t * 0.9 + 45.6)
  local n3 = noise01(t * 1.1 + 78.9)

  local roll = (n1 - 0.5) * 2.0
  local yaw = (n2 - 0.5) * 2.0
  local pitch = (n3 - 0.5) * 2.0

  -- Use parameter min/max when available; otherwise assume [-1, 1].
  local function apply(param, v)
    if not param then
      return
    end
    local xmin = tonumber(param.xmin) or -1.0
    local xmax = tonumber(param.xmax) or 1.0
    if xmin == xmax then
      xmin, xmax = -1.0, 1.0
    end
    local vv = clamp(v, -1.0, 1.0)
    local x = xmin + (vv + 1.0) * 0.5 * (xmax - xmin)
    inochi.set_param(param.name, x, 0.0)
  end

  apply(mapping.head_roll, roll * 0.35)
  apply(mapping.head_yaw, yaw * 0.25)
  apply(mapping.head_pitch, pitch * 0.20)
end

function M.apply_mouth(inochi, mapping, mouth)
  if not inochi or not mapping or not mapping.mouth_open then
    return
  end
  local v = clamp(mouth or 0.0, 0.0, 1.0)
  local xmin = tonumber(mapping.mouth_open.xmin) or 0.0
  local xmax = tonumber(mapping.mouth_open.xmax) or 1.0
  if xmin == xmax then
    xmin, xmax = 0.0, 1.0
  end
  local x = xmin + v * (xmax - xmin)
  inochi.set_param(mapping.mouth_open.name, x, 0.0)
end

return M
