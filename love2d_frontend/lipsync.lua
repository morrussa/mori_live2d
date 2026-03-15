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

local function read_file_bytes(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function avg_sample(sound, i)
  local a, b = sound:getSample(i)
  if b ~= nil then
    return (a + b) * 0.5
  end
  return a
end

function M.build_envelope(sound_data, window_sec)
  local sr = sound_data:getSampleRate()
  local total = sound_data:getSampleCount()
  local win = math.max(1, math.floor(sr * window_sec))
  local env = {}
  local maxv = 1e-9

  local idx = 0
  while idx < total do
    local endi = math.min(total - 1, idx + win - 1)
    local sum = 0.0
    local n = 0
    for i = idx, endi do
      local s = avg_sample(sound_data, i)
      sum = sum + (s * s)
      n = n + 1
    end
    local rms = math.sqrt(sum / math.max(1, n))
    env[#env + 1] = rms
    if rms > maxv then
      maxv = rms
    end
    idx = idx + win
  end

  for i = 1, #env do
    env[i] = env[i] / maxv
  end
  return env
end

function M.load_wav_for_playback(wav_path, window_sec)
  local bytes = read_file_bytes(wav_path)
  if not bytes then
    return nil, "failed to read wav: " .. tostring(wav_path)
  end

  local file_data = love.filesystem.newFileData(bytes, "tts.wav")
  local sound_data = love.sound.newSoundData(file_data)
  local source = love.audio.newSource(sound_data)

  local env = M.build_envelope(sound_data, window_sec)
  local duration = source:getDuration("seconds")

  return {
    wav_path = wav_path,
    source = source,
    envelope = env,
    window_sec = window_sec,
    duration = duration,
    mouth = 0.0,
  }
end

function M.update_mouth(playback)
  if not playback or not playback.source then
    return 0.0
  end
  if not playback.source:isPlaying() then
    playback.mouth = 0.0
    return 0.0
  end
  local t = playback.source:tell("seconds")
  local idx = math.floor((t / playback.window_sec) + 1)
  local v = playback.envelope[idx] or 0.0
  v = clamp(v, 0.0, 1.0)
  -- Similar shaping to my-neuro: pow(x, 0.8)
  v = math.pow(v, 0.8)
  playback.mouth = v
  return v
end

return M

