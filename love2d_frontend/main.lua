-- Mori Inochi2D (Live2D alternative) Love2D frontend (WIP).
--
-- Current status:
--   - Renders a placeholder "puppet" and applies a random wiggle animation.
--   - Optionally reads Mori's subtitle file and displays it on screen.
--
-- TODO (next):
--   - Bind real Inochi2D runtime (likely via inochi2d-c + LuaJIT FFI).
--   - Load .inx puppet (e.g. model/inochi2d/puppets/aka/Aka.inx).
--   - Drive parameters (mouth/eyes/expressions) from events.jsonl + audio/lipsync.
--   - Provide a minimal control API from Mori -> frontend (IPC/WebSocket/OSC).

local state = {
  t = 0.0,
  phase1 = 0.0,
  phase2 = 0.0,
  angle = 0.0,
  ox = 0.0,
  oy = 0.0,
  subtitle = "",
  subtitlePath = "",
  subtitlePoll = 0.0,
}

local function defaultSubtitlePath()
  -- This file is at: <repo>/mori_live2d/love2d_frontend/main.lua
  -- Default vtuber output is: <repo>/live/subtitle.txt
  return "../../live/subtitle.txt"
end

local function readAllText(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function love.load()
  love.window.setTitle("mori_live2d - Love2D Frontend (WIP)")
  love.window.setMode(900, 700, { resizable = true, vsync = true })

  math.randomseed(os.time())
  state.phase1 = math.random() * 100.0
  state.phase2 = math.random() * 100.0

  state.subtitlePath = os.getenv("MORI_SUBTITLE_PATH") or ""
  if state.subtitlePath == "" then
    state.subtitlePath = defaultSubtitlePath()
  end
end

function love.update(dt)
  state.t = state.t + dt

  -- Smooth random-ish motion using noise (no per-frame jitter).
  local n1 = love.math.noise(state.t * 0.7 + state.phase1)
  local n2 = love.math.noise(state.t * 0.9 + state.phase2)
  local n3 = love.math.noise(state.t * 1.1 + 123.45)

  state.angle = (n1 - 0.5) * 0.18 -- radians (~10 degrees)
  state.ox = (n2 - 0.5) * 30.0
  state.oy = (n3 - 0.5) * 20.0

  -- Poll subtitle file at a low frequency to avoid excessive disk I/O.
  state.subtitlePoll = state.subtitlePoll - dt
  if state.subtitlePoll <= 0.0 then
    state.subtitlePoll = 0.2
    local s = readAllText(state.subtitlePath)
    if s then
      s = s:gsub("\r\n", "\n")
      s = s:gsub("\n+$", "")
      state.subtitle = s
    end
  end
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.06, 0.08, 1.0)

  -- Placeholder puppet (replace with real Inochi2D renderer later).
  local cx, cy = w * 0.5, h * 0.48
  love.graphics.push()
  love.graphics.translate(cx + state.ox, cy + state.oy)
  love.graphics.rotate(state.angle)

  -- Body
  love.graphics.setColor(0.85, 0.86, 0.92, 1.0)
  love.graphics.rectangle("fill", -120, -150, 240, 320, 18, 18)

  -- Head
  love.graphics.setColor(0.20, 0.22, 0.30, 1.0)
  love.graphics.circle("fill", 0, -180, 75)

  -- Face
  love.graphics.setColor(0.95, 0.95, 0.98, 1.0)
  love.graphics.circle("fill", -25, -195, 10)
  love.graphics.circle("fill", 25, -195, 10)
  love.graphics.setColor(0.95, 0.72, 0.75, 1.0)
  love.graphics.rectangle("fill", -18, -160, 36, 8, 4, 4)

  love.graphics.pop()

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Love2D Frontend (WIP)", 12, 10)
  love.graphics.print("TODO: bind Inochi2D runtime + load .inx + drive params.", 12, 30)
  love.graphics.print("Subtitle path: " .. tostring(state.subtitlePath), 12, 50)

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

