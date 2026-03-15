local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  return {
    ok = false,
    error = "Missing LuaJIT FFI. Please use LÖVE 11.x (LuaJIT) builds.",
  }
end

local size_t_typ = ffi.abi("64bit") and "uint64_t" or "uint32_t"
ffi.cdef(([[
	typedef unsigned char uint8_t;
	typedef unsigned int uint32_t;
	typedef unsigned long long uint64_t;
	typedef %s size_t;
	typedef int int32_t;
	typedef int32_t int32;

typedef struct InoxHandle InoxHandle;

InoxHandle* inox_create(const char* path, uint32_t width, uint32_t height);
void inox_destroy(InoxHandle* handle);

int32 inox_resize(InoxHandle* handle, uint32_t width, uint32_t height);
int32 inox_begin_frame(InoxHandle* handle);
int32 inox_set_param(InoxHandle* handle, const char* name, float x, float y);
int32 inox_end_frame(InoxHandle* handle, float dt);
int32 inox_draw(InoxHandle* handle);

size_t inox_param_count(InoxHandle* handle);
size_t inox_param_name(InoxHandle* handle, size_t index, char* buf, size_t buf_len);
int32 inox_param_is_vec2(InoxHandle* handle, size_t index);
int32 inox_param_minmax(InoxHandle* handle, size_t index, float* xmin, float* ymin, float* xmax, float* ymax);

size_t inox_last_error(char* buf, size_t buf_len);
]]):format(size_t_typ))

local M = {
  ok = true,
  ffi = ffi,
  lib = nil,
}

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

function M.find_library()
  local env = os.getenv("MORI_INOX2D_LIB") or os.getenv("INOX2D_LIB") or ""
  if env ~= "" and file_exists(env) then
    return env
  end

  local base = love.filesystem.getSourceBaseDirectory()
  local wd = love.filesystem.getWorkingDirectory and love.filesystem.getWorkingDirectory() or ""
  local candidates = {
    -- Repo-root (recommended): run `love mori_live2d/love2d_frontend` from repo root.
    (wd ~= "" and (wd .. "/model/inochi2d/native/libmori_inox2d.so") or ""),
    (wd ~= "" and (wd .. "/mori_live2d/native/inox2d_ffi/target/release/libmori_inox2d_ffi.so") or ""),

    -- Relative to LÖVE source base directory (depends on how LÖVE was launched).
    base .. "/../../model/inochi2d/native/libmori_inox2d.so",
    base .. "/../native/inox2d_ffi/target/release/libmori_inox2d_ffi.so",
  }
  for _, p in ipairs(candidates) do
    if p ~= "" and file_exists(p) then
      return p
    end
  end
  return nil
end

function M.load(lib_path)
  if M.lib then
    return true
  end
  local path = lib_path or M.find_library()
  if not path then
    return false,
      "libmori_inox2d.so not found. Build it via: python3 -m mori_live2d.cli build-inox2d "
        .. "or set MORI_INOX2D_LIB=/abs/path/to/libmori_inox2d.so"
  end
  M.lib = ffi.load(path)
  return true
end

function M.last_error()
  if not M.lib then
    return nil
  end
  local need = tonumber(M.lib.inox_last_error(nil, 0)) or 0
  if need <= 1 then
    return nil
  end
  local buf = ffi.new("char[?]", need)
  M.lib.inox_last_error(buf, need)
  local s = ffi.string(buf)
  if s == "" then
    return nil
  end
  return s
end

function M.create(puppet_path, w, h)
  local ok, err = M.load()
  if not ok then
    return nil, err
  end
  local handle = M.lib.inox_create(tostring(puppet_path), w or 0, h or 0)
  if handle == nil then
    return nil, M.last_error() or "inox_create failed"
  end
  return handle
end

function M.destroy(handle)
  if M.lib and handle ~= nil then
    pcall(function()
      M.lib.inox_destroy(handle)
    end)
  end
end

function M.resize(handle, w, h)
  if not (M.lib and handle ~= nil) then
    return false
  end
  return M.lib.inox_resize(handle, w, h) ~= 0
end

function M.begin_frame(handle)
  if not (M.lib and handle ~= nil) then
    return false
  end
  return M.lib.inox_begin_frame(handle) ~= 0
end

function M.end_frame(handle, dt)
  if not (M.lib and handle ~= nil) then
    return false
  end
  return M.lib.inox_end_frame(handle, dt or 0.0) ~= 0
end

function M.set_param(handle, name, x, y)
  if not (M.lib and handle ~= nil) then
    return false
  end
  return M.lib.inox_set_param(handle, tostring(name), x or 0.0, y or 0.0) ~= 0
end

function M.draw(handle)
  if not (M.lib and handle ~= nil) then
    return false
  end
  return M.lib.inox_draw(handle) ~= 0
end

function M.get_parameters(handle)
  if not (M.lib and handle ~= nil) then
    return {}, {}
  end
  local n = tonumber(M.lib.inox_param_count(handle)) or 0
  local list = {}
  local by_name = {}
  for i = 0, n - 1 do
    local need = tonumber(M.lib.inox_param_name(handle, i, nil, 0)) or 0
    if need > 1 then
      local buf = ffi.new("char[?]", need)
      M.lib.inox_param_name(handle, i, buf, need)
      local name = ffi.string(buf)
      local xmin = ffi.new("float[1]", 0)
      local ymin = ffi.new("float[1]", 0)
      local xmax = ffi.new("float[1]", 0)
      local ymax = ffi.new("float[1]", 0)
      M.lib.inox_param_minmax(handle, i, xmin, ymin, xmax, ymax)
      local is_vec2 = M.lib.inox_param_is_vec2(handle, i) ~= 0
      local info = {
        name = name,
        is_vec2 = is_vec2,
        xmin = xmin[0],
        ymin = ymin[0],
        xmax = xmax[0],
        ymax = ymax[0],
      }
      list[#list + 1] = info
      by_name[name] = info
    end
  end
  return list, by_name
end

return M
