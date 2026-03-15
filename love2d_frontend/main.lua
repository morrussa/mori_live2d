-- Mori Inochi2D Love2D frontend (Inox2D + LuaJIT FFI).
--
-- What works now:
--   - Loads and renders an Inochi2D puppet (.inx/.inp) via Inox2D (Rust, OpenGL).
--   - Polls Mori outputs and displays subtitle file.
--   - Plays Mori-generated wav (from events.jsonl) and drives mouth-open (simple lipsync envelope).
--   - Applies idle "random wiggle" similar to my-neuro (head roll/yaw/pitch if params are found).
--   - Basic eye saccades + optional mouse look; auto blink if eye-open params are found.
--
-- TODO:
--   - Rich expressions / emotion mapping.
--   - Robust IPC (WebSocket/OSC) instead of polling files.
--   - Proper transparency / OBS capture ergonomics.

local inox = require("inox2d")
local liveio = require("mori_live_io")
local lipsync = require("lipsync")
local controller = require("controller")

local state = {
  t = 0.0,
  subtitle = "",
  subtitlePath = "",
  subtitlePoll = 0.0,
  eventLogPath = "",
  eventTail = nil,
  audioQueue = {},
  playback = nil,

  puppetPath = "",
  handle = nil,
  params = nil,
  paramByName = nil,
  mappingPath = "",
  ctrl = nil,

  status = "",
  err = "",
  renderer = "",
  showHelp = true,
}

local function parse_arg(flag)
  if type(arg) ~= "table" then
    return nil
  end
  for i = 1, #arg - 1 do
    if arg[i] == flag then
      return arg[i + 1]
    end
  end
  return nil
end

local function default_path(rel)
  -- Source directory is: <repo>/mori_live2d/love2d_frontend
  local base = love.filesystem.getSourceBaseDirectory()
  return base .. "/" .. rel
end

function love.load()
  love.window.setTitle("mori_live2d - Inochi2D Love2D Frontend")
  love.window.setMode(900, 700, { resizable = true, vsync = true })

  local rname, rver, rvendor, rdevice = love.graphics.getRendererInfo()
  state.renderer = string.format("%s %s (%s)", tostring(rname), tostring(rver), tostring(rvendor))

  local liveDir = os.getenv("MORI_LIVE_DIR") or parse_arg("--live-dir") or ""
  if liveDir == "" then
    liveDir = default_path("../../live")
  end

  state.subtitlePath = os.getenv("MORI_SUBTITLE_PATH") or parse_arg("--subtitle") or ""
  if state.subtitlePath == "" then
    state.subtitlePath = liveDir .. "/subtitle.txt"
  end

  state.eventLogPath = os.getenv("MORI_EVENT_LOG") or parse_arg("--event-log") or ""
  if state.eventLogPath == "" then
    state.eventLogPath = liveDir .. "/events.jsonl"
  end
  state.eventTail = liveio.new_event_tail(state.eventLogPath)

  state.puppetPath = os.getenv("MORI_PUPPET_PATH") or parse_arg("--puppet") or ""
  if state.puppetPath == "" then
    state.puppetPath = default_path("../../model/inochi2d/puppets/aka/Aka.inx")
  end

  state.mappingPath = os.getenv("MORI_MAPPING_PATH") or parse_arg("--mapping") or ""

  if not inox.ok then
    state.err = tostring(inox.error or "inox2d ffi module not available")
    return
  end

  local w, h = love.graphics.getDimensions()

  local handle, perr = inox.create(state.puppetPath, w, h)
  if not handle then
    state.err = tostring(perr or "failed to load puppet")
    return
  end
  state.handle = handle

  local params, by_name = inox.get_parameters(handle)
  state.params = params
  state.paramByName = by_name
  state.ctrl = controller.new(by_name, {
    puppet_path = state.puppetPath,
    mapping_path = state.mappingPath,
    options = state.ctrl and state.ctrl.options or nil,
  })

  print("inochi2d> loaded puppet: " .. tostring(state.puppetPath))
  print("inochi2d> parameters:")
  for _, p in ipairs(params or {}) do
    print(string.format("  - %s (vec2=%s) range=[%.3f..%.3f]", p.name, tostring(p.is_vec2), p.xmin, p.xmax))
  end
  if state.ctrl and state.ctrl.mapping and state.ctrl.mapping.__mapping_path and state.ctrl.mapping.__mapping_path ~= "" then
    print("inochi2d> mapping override: " .. tostring(state.ctrl.mapping.__mapping_path))
  end

  state.status = "ready"
end

function love.resize(w, h)
  if inox.ok and state.handle ~= nil then
    pcall(function()
      inox.resize(state.handle, w, h)
    end)
  end
end

function love.update(dt)
  state.t = state.t + dt

  -- Poll subtitle file at a low frequency to avoid excessive disk I/O.
  state.subtitlePoll = state.subtitlePoll - dt
  if state.subtitlePoll <= 0.0 then
    state.subtitlePoll = 0.2
    local s = liveio.read_subtitle(state.subtitlePath)
    if s then
      state.subtitle = s
    end
  end

  if inox.ok and state.handle ~= nil then
    pcall(function()
      inox.begin_frame(state.handle)
      local api = {
        set_param = function(name, x, y)
          return inox.set_param(state.handle, name, x, y)
        end,
      }
      if state.ctrl then
        local mouth = 0.0
        if state.playback then
          mouth = lipsync.update_mouth(state.playback)
        end
        local w, h = love.graphics.getDimensions()
        local mx, my = love.mouse.getPosition()
        local nx = (mx / math.max(1, w) - 0.5) * 2.0
        local ny = (my / math.max(1, h) - 0.5) * 2.0
        controller.update(api, state.ctrl, dt, state.t, mouth, {
          mouse = { x = nx, y = ny },
        })
      end
      inox.end_frame(state.handle, dt)
    end)
  end

  -- Poll events.jsonl for new wav_path, enqueue playback.
  local new_events = liveio.poll_events(state.eventTail)
  for _, ev in ipairs(new_events or {}) do
    state.audioQueue[#state.audioQueue + 1] = ev.wav_path
  end

  -- Start next audio if idle.
  if (not state.playback) and #state.audioQueue > 0 then
    local wav = table.remove(state.audioQueue, 1)
    local pb, aerr = lipsync.load_wav_for_playback(wav, 0.02)
    if pb then
      state.playback = pb
      pb.source:play()
    else
      state.err = tostring(aerr)
    end
  end

  -- Drive mouth while playing.
  if state.playback and (not state.playback.source:isPlaying()) then
    state.playback = nil
  end
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.06, 0.08, 1.0)

  if inox.ok and state.handle ~= nil then
    local ok_draw, derr = pcall(function()
      inox.draw(state.handle)
    end)
    -- External GL calls may disturb LÖVE state; reset before drawing overlays.
    if love.graphics.reset then
      love.graphics.reset()
    end
    if not ok_draw and derr then
      state.err = tostring(derr)
    end
  else
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Inochi2D not initialized.", 12, 10)
  end

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("mori_live2d (Inox2D + Love2D)", 12, 10)
  love.graphics.print("renderer: " .. tostring(state.renderer), 12, 26)
  love.graphics.print("puppet: " .. tostring(state.puppetPath), 12, 42)
  love.graphics.print("subtitle: " .. tostring(state.subtitlePath), 12, 58)
  love.graphics.print("events: " .. tostring(state.eventLogPath), 12, 74)
  if state.playback and state.playback.wav_path then
    love.graphics.print("tts wav: " .. tostring(state.playback.wav_path), 12, 90)
  end
  if state.err ~= "" then
    love.graphics.setColor(1, 0.4, 0.4, 1)
    love.graphics.print("error: " .. tostring(state.err), 12, 110)
    love.graphics.setColor(1, 1, 1, 1)
  end
  if state.ctrl and state.ctrl.options then
    local o = state.ctrl.options
    love.graphics.print(
      string.format(
        "keys: [H] help  [I] idle:%s  [F] mouse:%s  [B] blink:%s  [R] reload map",
        o.idle_enabled and "on" or "off",
        o.mouse_look_enabled and "on" or "off",
        o.blink_enabled and "on" or "off"
      ),
      12,
      130
    )
  end

  if state.showHelp and state.ctrl and state.ctrl.mapping then
    local m = state.ctrl.mapping
    local y = 150
    local function show(label, entry)
      if not entry then
        return
      end
      local p = entry.param or entry
      if p and p.name then
        love.graphics.print(string.format("map> %-12s -> %s", label, tostring(p.name)), 12, y)
        y = y + 16
      end
    end
    show("head_yaw", m.head_yaw)
    show("head_pitch", m.head_pitch)
    show("head_roll", m.head_roll)
    show("mouth_open", m.mouth_open)
    show("eye_ball", m.eye_ball)
    show("eye_open_l", m.eye_open_l)
    show("eye_open_r", m.eye_open_r)
    show("eye_open", m.eye_open)
    show("breath", m.breath)
    if m.__mapping_path and m.__mapping_path ~= "" then
      love.graphics.print("map file: " .. tostring(m.__mapping_path), 12, y)
      y = y + 16
    end
  end

  -- Subtitle overlay
  local padding = 18
  local boxH = 140
  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.rectangle("fill", padding, h - boxH - padding, w - padding * 2, boxH, 16, 16)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.printf(state.subtitle, padding + 14, h - boxH - padding + 14, w - padding * 2 - 28, "left")
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
    return
  end
  if key == "h" then
    state.showHelp = not state.showHelp
    return
  end
  if not (state.ctrl and state.ctrl.options) then
    return
  end
  if key == "i" then
    state.ctrl.options.idle_enabled = not state.ctrl.options.idle_enabled
    return
  end
  if key == "f" then
    state.ctrl.options.mouse_look_enabled = not state.ctrl.options.mouse_look_enabled
    return
  end
  if key == "b" then
    state.ctrl.options.blink_enabled = not state.ctrl.options.blink_enabled
    return
  end
  if key == "r" and state.paramByName then
    state.ctrl = controller.new(state.paramByName, {
      puppet_path = state.puppetPath,
      mapping_path = state.mappingPath,
      options = state.ctrl and state.ctrl.options or nil,
    })
    state.err = ""
    return
  end
end

function love.filedropped(file)
  if not (inox.ok and state.handle ~= nil) then
    return
  end
  local filename = file:getFilename()
  if not filename or filename == "" then
    return
  end
  local lower = string.lower(filename)
  if not (string.sub(lower, -4) == ".inx" or string.sub(lower, -4) == ".inp") then
    state.err = "dropped file is not a puppet (.inx/.inp): " .. tostring(filename)
    return
  end

  local w, h = love.graphics.getDimensions()
  inox.destroy(state.handle)
  state.handle = nil

  local handle, perr = inox.create(filename, w, h)
  if not handle then
    state.err = tostring(perr or "failed to load puppet: " .. tostring(filename))
    return
  end

  state.puppetPath = filename
  state.handle = handle
  local params, by_name = inox.get_parameters(handle)
  state.params = params
  state.paramByName = by_name
  state.ctrl = controller.new(by_name, {
    puppet_path = state.puppetPath,
    mapping_path = state.mappingPath,
    options = state.ctrl and state.ctrl.options or nil,
  })
  state.err = ""
  print("inochi2d> switched puppet: " .. tostring(filename))
end

function love.quit()
  inox.destroy(state.handle)
end
