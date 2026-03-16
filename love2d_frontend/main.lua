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

  autoScreenshotPath = "",
  autoScreenshotDone = false,

  status = "",
  err = "",
  renderer = "",
  showHelp = true,
  uiFont = nil,
  subtitleFont = nil,
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

local function parse_bool(v)
  if v == nil then
    return nil
  end
  local s = string.lower(tostring(v))
  if s == "" then
    return nil
  end
  if s == "1" or s == "true" or s == "on" or s == "yes" or s == "y" then
    return true
  end
  if s == "0" or s == "false" or s == "off" or s == "no" or s == "n" then
    return false
  end
  return nil
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function sanitize_path(p)
  local s = tostring(p or "")
  -- trim whitespace (common when copy/pasting or env vars contain newline)
  s = (s:gsub("^%s+", ""):gsub("%s+$", ""))
  -- strip surrounding quotes
  if (s:sub(1, 1) == '"' and s:sub(-1) == '"') or (s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    s = s:sub(2, -2)
  end
  return s
end

local function find_cjk_font_path()
  local env = os.getenv("MORI_FONT_PATH") or parse_arg("--font") or ""
  if env ~= "" and file_exists(env) then
    return env
  end

  local candidates = {
    -- Linux (Noto / WenQuanYi)
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    -- macOS
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    -- Windows
    "C:\\Windows\\Fonts\\msyh.ttc",
    "C:\\Windows\\Fonts\\simhei.ttf",
    "C:\\Windows\\Fonts\\simsun.ttc",
  }
  for _, p in ipairs(candidates) do
    if file_exists(p) then
      return p
    end
  end
  return nil
end

local function default_path(rel)
  -- Source directory is: <repo>/mori_live2d/love2d_frontend
  local base = love.filesystem.getSourceBaseDirectory()
  return base .. "/" .. rel
end

local function repo_path(rel_from_repo_root)
  local wd = love.filesystem.getWorkingDirectory and love.filesystem.getWorkingDirectory() or ""
  if wd ~= "" then
    return wd .. "/" .. rel_from_repo_root
  end
  -- fallback: behave like older versions
  return default_path("../../" .. rel_from_repo_root)
end

function love.load()
  love.window.setTitle("mori_live2d - Inochi2D Love2D Frontend")
  love.window.setMode(900, 700, { resizable = true, vsync = true })

  do
    local ui_size = tonumber(os.getenv("MORI_UI_FONT_SIZE") or parse_arg("--ui-font-size") or "") or 14
    local sub_size = tonumber(os.getenv("MORI_SUBTITLE_FONT_SIZE") or parse_arg("--subtitle-font-size") or "") or 22
    local font_path = find_cjk_font_path()

    local ok_ui, ui_font = pcall(function()
      if font_path then
        return love.graphics.newFont(font_path, ui_size)
      end
      return love.graphics.newFont(ui_size)
    end)
    local ok_sub, sub_font = pcall(function()
      if font_path then
        return love.graphics.newFont(font_path, sub_size)
      end
      return love.graphics.newFont(sub_size)
    end)

    if ok_ui and ui_font then
      state.uiFont = ui_font
      love.graphics.setFont(ui_font)
    end
    if ok_sub and sub_font then
      state.subtitleFont = sub_font
    end
  end

  local rname, rver, rvendor, rdevice = love.graphics.getRendererInfo()
  state.renderer = string.format("%s %s (%s)", tostring(rname), tostring(rver), tostring(rvendor))

  local liveDir = os.getenv("MORI_LIVE_DIR") or parse_arg("--live-dir") or ""
  if liveDir == "" then
    liveDir = repo_path("live")
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
    state.puppetPath = repo_path("model/inochi2d/puppets/aka/Aka.inx")
  end
  state.puppetPath = sanitize_path(state.puppetPath)

  state.mappingPath = os.getenv("MORI_MAPPING_PATH") or parse_arg("--mapping") or ""
  state.mappingPath = sanitize_path(state.mappingPath)

  state.autoScreenshotPath = os.getenv("MORI_SCREENSHOT_PATH") or parse_arg("--screenshot") or ""
  state.autoScreenshotPath = sanitize_path(state.autoScreenshotPath)

  if not inox.ok then
    state.err = tostring(inox.error or "inox2d ffi module not available")
    return
  end

  local w, h = love.graphics.getDimensions()

  if not file_exists(state.puppetPath) then
    state.err = "puppet file not found: " .. tostring(state.puppetPath)
    return
  end

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
  do
    local v = parse_bool(os.getenv("MORI_MOUSE_LOOK") or parse_arg("--mouse-look"))
    if v ~= nil and state.ctrl and state.ctrl.options then
      state.ctrl.options.mouse_look_enabled = v
    end
  end

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
        local nx, ny = 0.0, 0.0
        if state.ctrl.options and state.ctrl.options.mouse_look_enabled and love.mouse and love.mouse.getPosition then
          local w, h = love.graphics.getDimensions()
          local ok, mx, my = pcall(love.mouse.getPosition)
          if ok then
            nx = (mx / math.max(1, w) - 0.5) * 2.0
            ny = (my / math.max(1, h) - 0.5) * 2.0
          end
        end
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
    local wav = tostring(ev.wav_path or "")
    if wav ~= "" and file_exists(wav) then
      state.audioQueue[#state.audioQueue + 1] = wav
    end
  end

  -- Start next audio if idle.
  if (not state.playback) and #state.audioQueue > 0 then
    local wav = table.remove(state.audioQueue, 1)
    if wav ~= "" and file_exists(wav) then
      local pb, aerr = lipsync.load_wav_for_playback(wav, 0.02)
      if pb then
        state.playback = pb
        pb.source:play()
      else
        state.err = tostring(aerr)
      end
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

  if (not state.autoScreenshotDone) and state.autoScreenshotPath ~= "" and love.graphics.captureScreenshot then
    state.autoScreenshotDone = true
    local ok_ss, ss_err = pcall(function()
      love.graphics.captureScreenshot(function(img)
        local ok_enc, enc_err = pcall(function()
          -- Love's ImageData:encode() writes via love.filesystem when given a filename.
          -- For CI/headless runs we often want an absolute path (e.g. /tmp/out.png), so
          -- encode to FileData and write bytes ourselves.
          local fd = img:encode("png")
          local bytes = fd and fd.getString and fd:getString() or nil
          if not bytes then
            error("ImageData:encode('png') did not return FileData")
          end
          local f, ferr = io.open(state.autoScreenshotPath, "wb")
          if not f then
            error("io.open failed: " .. tostring(ferr))
          end
          f:write(bytes)
          f:close()
        end)
        if not ok_enc and enc_err then
          state.err = "screenshot encode failed: " .. tostring(enc_err)
          print("inochi2d> " .. state.err)
        end
        if love.event and love.event.quit then
          love.event.quit(0)
        end
      end)
    end)
    if not ok_ss and ss_err then
      state.err = "captureScreenshot failed: " .. tostring(ss_err)
      print("inochi2d> " .. state.err)
    end
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
    show("head", m.head)
    show("head_yaw", m.head_yaw)
    show("head_pitch", m.head_pitch)
    show("head_roll", m.head_roll)
    show("body", m.body)
    show("body_yaw", m.body_yaw)
    show("body_pitch", m.body_pitch)
    show("body_roll", m.body_roll)
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

  -- Subtitle overlay (only show when there is text)
  local subtitle = tostring(state.subtitle or "")
  subtitle = subtitle:gsub("^%s+", ""):gsub("%s+$", "")
  if subtitle ~= "" then
    local padding = 12
    local inner = 12
    local font = state.subtitleFont or love.graphics.getFont()
    local prev_font = state.uiFont or love.graphics.getFont()
    if font then
      love.graphics.setFont(font)
    end

    local wrapW = math.max(20, w - padding * 2 - inner * 2)
    local _, lines = font:getWrap(subtitle, wrapW)
    local lineH = font:getHeight() * (font:getLineHeight() or 1.0)
    local textH = (#lines) * lineH

    local boxH = textH + inner * 2
    local maxH = math.floor(h * 0.45)
    if boxH > maxH then
      boxH = maxH
    end
    local boxY = h - boxH - padding

    love.graphics.setColor(0, 0, 0, 0.42)
    love.graphics.rectangle("fill", padding, boxY, w - padding * 2, boxH, 14, 14)
    love.graphics.setColor(1, 1, 1, 1)

    love.graphics.setScissor(padding, boxY, w - padding * 2, boxH)
    love.graphics.printf(subtitle, padding + inner, boxY + inner, wrapW, "left")
    love.graphics.setScissor()

    if prev_font then
      love.graphics.setFont(prev_font)
    end
  end
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
