-- Mori Inochi2D Love2D frontend (inochi2d-c + LuaJIT FFI).
--
-- What works now:
--   - Loads and renders an Inochi2D puppet (.inx) via inochi2d-c (OpenGL).
--   - Polls Mori outputs and displays subtitle file.
--   - Plays Mori-generated wav (from events.jsonl) and drives mouth-open (simple lipsync envelope).
--   - Applies idle "random wiggle" similar to my-neuro (head roll/yaw/pitch if params are found).
--
-- TODO:
--   - Better parameter mapping per-puppet (config file).
--   - Blink/eye tracking, expressions and emotion mapping.
--   - Robust IPC (WebSocket/OSC) instead of polling files.
--   - Proper transparency / OBS capture ergonomics.

local inochi = require("inochi2d_c")
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
  puppet = nil,
  params = nil,
  paramByName = nil,
  mapping = nil,
  camera = nil,

  status = "",
  err = "",
  renderer = "",
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

  if not inochi.ok then
    state.err = tostring(inochi.error or "inochi2d-c ffi module not available")
    return
  end

  local ok, err = inochi.init()
  if not ok then
    state.err = tostring(err or "failed to init inochi2d-c")
    return
  end

  local w, h = love.graphics.getDimensions()
  pcall(function()
    inochi.set_viewport(w, h)
  end)

  state.camera = inochi.get_camera()
  -- Reasonable defaults for Aka-like vtuber puppets.
  inochi.camera_set_zoom(state.camera, 0.2)
  inochi.camera_set_position(state.camera, 0.0, 1000.0)

  local puppet, perr = inochi.load_puppet(state.puppetPath)
  if not puppet then
    state.err = tostring(perr or "failed to load puppet")
    return
  end
  state.puppet = puppet

  local params, by_name = inochi.get_parameters(puppet)
  state.params = params
  state.paramByName = by_name
  state.mapping = controller.make_mapping(by_name)

  print("inochi2d> loaded puppet: " .. tostring(state.puppetPath))
  print("inochi2d> parameters:")
  for _, p in ipairs(params or {}) do
    print(string.format("  - %s (vec2=%s) range=[%.3f..%.3f]", p.name, tostring(p.is_vec2), p.xmin, p.xmax))
  end

  state.status = "ready"
end

function love.resize(w, h)
  if inochi.ok and state.puppet ~= nil then
    pcall(function()
      inochi.set_viewport(w, h)
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

  if inochi.ok and state.puppet ~= nil then
    pcall(function()
      inochi.update()
      controller.apply_idle(inochi, state.mapping, state.t)
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
  if state.playback and inochi.ok and state.puppet ~= nil then
    local mouth = lipsync.update_mouth(state.playback)
    controller.apply_mouth(inochi, state.mapping, mouth)
    if not state.playback.source:isPlaying() then
      state.playback = nil
      controller.apply_mouth(inochi, state.mapping, 0.0)
    end
  end
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.06, 0.08, 1.0)

  if inochi.ok and state.puppet ~= nil then
    local ok_draw, derr = pcall(function()
      inochi.draw_puppet(state.puppet, w, h)
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
  love.graphics.print("mori_live2d (inochi2d-c + Love2D)", 12, 10)
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
  end
end

function love.filedropped(file)
  if not (inochi.ok and state.puppet ~= nil) then
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

  inochi.destroy_puppet(state.puppet)
  state.puppet = nil

  local puppet, perr = inochi.load_puppet(filename)
  if not puppet then
    state.err = tostring(perr or "failed to load puppet: " .. tostring(filename))
    return
  end

  state.puppetPath = filename
  state.puppet = puppet
  local params, by_name = inochi.get_parameters(puppet)
  state.params = params
  state.paramByName = by_name
  state.mapping = controller.make_mapping(by_name)
  state.err = ""
  print("inochi2d> switched puppet: " .. tostring(filename))
end

function love.quit()
  if inochi.ok then
    inochi.destroy_puppet(state.puppet)
    inochi.shutdown()
  end
end
