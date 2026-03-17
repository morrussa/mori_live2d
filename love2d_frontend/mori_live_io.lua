local M = {}

local function read_all_text(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function strip_utf8_bom(s)
  if type(s) ~= "string" then
    return s
  end
  -- UTF-8 BOM: EF BB BF
  if s:sub(1, 3) == "\239\187\191" then
    return s:sub(4)
  end
  return s
end

local function sanitize_utf8_best_effort(s)
  if type(s) ~= "string" then
    return s
  end
  if not (_G.utf8 and utf8.len) then
    return s
  end
  local ok, _len, pos = pcall(utf8.len, s)
  if ok and _len ~= nil then
    return s
  end
  -- Replace invalid bytes with '?', retry a few times.
  local out = s
  for _ = 1, 32 do
    local len2, badpos = utf8.len(out)
    if len2 ~= nil then
      return out
    end
    if not badpos then
      return out
    end
    out = out:sub(1, badpos - 1) .. "?" .. out:sub(badpos + 1)
  end
  return out
end

local function codepoint_to_utf8(cp)
  if _G.utf8 and utf8.char then
    return utf8.char(cp)
  end
  if cp <= 0x7F then
    return string.char(cp)
  elseif cp <= 0x7FF then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp <= 0xFFFF then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

local function json_extract_string(line, key)
  local needle = '"' .. key .. '"'
  local kpos = line:find(needle, 1, true)
  if not kpos then
    return nil
  end
  local i = kpos + #needle
  local colon = line:find(":", i, true)
  if not colon then
    return nil
  end
  i = colon + 1
  while i <= #line and line:sub(i, i):match("%s") do
    i = i + 1
  end
  if i > #line or line:sub(i, i) ~= '"' then
    return nil
  end
  i = i + 1

  local out = {}
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' then
      return table.concat(out)
    end
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      local esc = line:sub(i + 1, i + 1)
      if esc == "" then
        return nil
      end
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
        i = i + 2
      elseif esc == "n" then
        out[#out + 1] = "\n"
        i = i + 2
      elseif esc == "r" then
        out[#out + 1] = "\r"
        i = i + 2
      elseif esc == "t" then
        out[#out + 1] = "\t"
        i = i + 2
      elseif esc == "u" then
        local hex = line:sub(i + 2, i + 5)
        if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
          return nil
        end
        local cp = tonumber(hex, 16) or 0
        out[#out + 1] = codepoint_to_utf8(cp)
        i = i + 6
      else
        out[#out + 1] = esc
        i = i + 2
      end
    end
  end
  return nil
end

local function json_extract_number(line, key)
  local needle = '"' .. key .. '"'
  local kpos = line:find(needle, 1, true)
  if not kpos then
    return nil
  end
  local i = kpos + #needle
  local colon = line:find(":", i, true)
  if not colon then
    return nil
  end
  i = colon + 1
  while i <= #line and line:sub(i, i):match("%s") do
    i = i + 1
  end
  local num = line:match("[-+]?%d*%.?%d+", i)
  if not num then
    return nil
  end
  return tonumber(num)
end

local function json_extract_number_array(line, key)
  local needle = '"' .. key .. '"'
  local kpos = line:find(needle, 1, true)
  if not kpos then
    return nil
  end
  local i = kpos + #needle
  local colon = line:find(":", i, true)
  if not colon then
    return nil
  end
  i = colon + 1
  while i <= #line and line:sub(i, i):match("%s") do
    i = i + 1
  end
  if i > #line or line:sub(i, i) ~= "[" then
    return nil
  end
  local j = line:find("]", i + 1, true)
  if not j then
    return nil
  end
  local slice = line:sub(i + 1, j - 1)
  local out = {}
  for num in slice:gmatch("[-+]?%d*%.?%d+") do
    out[#out + 1] = tonumber(num)
  end
  if #out == 0 then
    return nil
  end
  return out
end
function M.read_subtitle(path)
  local raw = read_all_text(path)
  if not raw then
    return nil
  end
  local s = tostring(raw)
  s = strip_utf8_bom(s)
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\r", "\n")
  s = s:gsub("\n+$", "")
  s = sanitize_utf8_best_effort(s)
  return s
end

function M.new_event_tail(path)
  return {
    path = path,
    offset = 0,
  }
end

function M.poll_events(tail)
  if not tail or not tail.path then
    return {}
  end
  local f = io.open(tail.path, "rb")
  if not f then
    return {}
  end
  local size = f:seek("end")
  if size and tail.offset > size then
    tail.offset = 0
  end
  f:seek("set", tail.offset)
  local events = {}
  for line in f:lines() do
    local wav_path = json_extract_string(line, "wav_path") or ""
    local mouth_envelope = json_extract_number_array(line, "mouth_envelope")
    local mouth_window_sec = json_extract_number(line, "mouth_window_sec") or 0
    local mouth_duration = json_extract_number(line, "mouth_duration") or 0
    if wav_path ~= "" and file_exists(wav_path) then
      events[#events + 1] = {
        wav_path = wav_path,
        mouth_envelope = mouth_envelope,
        mouth_window_sec = mouth_window_sec,
        mouth_duration = mouth_duration,
      }
    end
  end
  tail.offset = f:seek()
  f:close()
  return events
end

return M
