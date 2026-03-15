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
typedef _Bool bool;

typedef unsigned int uint;
typedef struct InError { size_t len; const char* msg; } InError;
typedef struct InPuppet InPuppet;
typedef struct InCamera InCamera;
typedef struct InParameter InParameter;

InError* inErrorGet(void);

void inInit(double (*timingFunc)());
void inCleanup(void);
void inUpdate(void);
void inViewportSet(uint width, uint height);
void inViewportGet(uint* width, uint* height);
void inSceneBegin(void);
void inSceneEnd(void);
void inSceneDraw(float x, float y, float width, float height);

InCamera* inCameraGetCurrent(void);
void inCameraGetPosition(InCamera* camera, float* x, float* y);
void inCameraSetPosition(InCamera* camera, float x, float y);
void inCameraGetZoom(InCamera* camera, float* zoom);
void inCameraSetZoom(InCamera* camera, float zoom);

InPuppet* inPuppetLoad(const char *path);
InPuppet* inPuppetLoadEx(const char *path, size_t length);
void inPuppetDestroy(InPuppet* puppet);
void inPuppetUpdate(InPuppet* puppet);
void inPuppetDraw(InPuppet* puppet);

void inPuppetGetParameters(InPuppet* puppet, InParameter*** array_ptr, size_t* length);
char* inParameterGetName(InParameter* param);
void inParameterGetValue(InParameter* param, float* x, float* y);
void inParameterSetValue(InParameter* param, float x, float y);
bool inParameterIsVec2(InParameter* param);
void inParameterGetMin(InParameter* param, float* xmin, float* ymin);
void inParameterGetMax(InParameter* param, float* xmax, float* ymax);
void inParameterReset(InParameter* param);
]]):format(size_t_typ))

local M = {
  ok = true,
  ffi = ffi,
  lib = nil,
  _time_cb = nil,
  _inited = false,
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
  local env = os.getenv("MORI_INOCHI2D_C_LIB") or os.getenv("INOCHI2D_C_LIB") or ""
  if env ~= "" and file_exists(env) then
    return env
  end

  local base = love.filesystem.getSourceBaseDirectory()
  local candidates = {
    base .. "/../../model/inochi2d/native/libinochi2d-c.so",
    base .. "/../../model/inochi2d/native/linux/libinochi2d-c.so",
    base .. "/../third_party/inochi2d-c/out/libinochi2d-c.so",
  }
  for _, p in ipairs(candidates) do
    if file_exists(p) then
      return p
    end
  end
  return nil
end

function M.last_error()
  if not M.lib then
    return nil
  end
  local err = M.lib.inErrorGet()
  if err == nil or err.msg == nil then
    return nil
  end
  local n = tonumber(err.len or 0) or 0
  if n <= 0 then
    return nil
  end
  return ffi.string(err.msg, n)
end

function M.init(lib_path)
  if M._inited then
    return true
  end
  local path = lib_path or M.find_library()
  if not path then
    return false, "libinochi2d-c.so not found. Build it via: python3 -m mori_live2d.cli build-inochi2d-c"
  end

  M.lib = ffi.load(path)

  M._time_cb = ffi.cast("double (*)()", function()
    return love.timer.getTime()
  end)
  M.lib.inInit(M._time_cb)
  M._inited = true
  return true
end

function M.shutdown()
  if not M._inited then
    return
  end
  pcall(function()
    M.lib.inCleanup()
  end)
  if M._time_cb then
    M._time_cb:free()
    M._time_cb = nil
  end
  M._inited = false
end

function M.set_viewport(w, h)
  M.lib.inViewportSet(w, h)
end

function M.update()
  M.lib.inUpdate()
end

function M.load_puppet(path)
  local p = tostring(path or "")
  if p == "" then
    return nil, "missing puppet path"
  end
  local puppet = M.lib.inPuppetLoad(p)
  if puppet == nil then
    return nil, M.last_error() or ("failed to load puppet: " .. p)
  end
  return puppet
end

function M.destroy_puppet(puppet)
  if puppet ~= nil then
    pcall(function()
      M.lib.inPuppetDestroy(puppet)
    end)
  end
end

function M.get_camera()
  return M.lib.inCameraGetCurrent()
end

function M.camera_set_zoom(camera, zoom)
  if camera ~= nil then
    M.lib.inCameraSetZoom(camera, zoom)
  end
end

function M.camera_set_position(camera, x, y)
  if camera ~= nil then
    M.lib.inCameraSetPosition(camera, x, y)
  end
end

function M.get_parameters(puppet)
  local len = ffi.new("size_t[1]", 0)
  local arr = ffi.new("InParameter**[1]")
  arr[0] = nil
  M.lib.inPuppetGetParameters(puppet, arr, len)
  local n = tonumber(len[0]) or 0
  local out = {}
  local by_name = {}
  if arr[0] ~= nil then
    for i = 0, n - 1 do
      local param = arr[0][i]
      if param ~= nil then
        local name = ffi.string(M.lib.inParameterGetName(param))
        local is_vec2 = M.lib.inParameterIsVec2(param)
        local xmin = ffi.new("float[1]", 0)
        local ymin = ffi.new("float[1]", 0)
        local xmax = ffi.new("float[1]", 0)
        local ymax = ffi.new("float[1]", 0)
        M.lib.inParameterGetMin(param, xmin, ymin)
        M.lib.inParameterGetMax(param, xmax, ymax)
        local info = {
          ptr = param,
          name = name,
          is_vec2 = is_vec2,
          xmin = xmin[0],
          ymin = ymin[0],
          xmax = xmax[0],
          ymax = ymax[0],
        }
        out[#out + 1] = info
        by_name[name] = info
      end
    end
  end
  return out, by_name
end

function M.param_set(param, x, y)
  if not param or not param.ptr then
    return
  end
  M.lib.inParameterSetValue(param.ptr, x or 0, y or 0)
end

function M.param_reset(param)
  if not param or not param.ptr then
    return
  end
  M.lib.inParameterReset(param.ptr)
end

function M.draw_puppet(puppet, w, h)
  M.lib.inSceneBegin()
  M.lib.inPuppetUpdate(puppet)
  M.lib.inPuppetDraw(puppet)
  M.lib.inSceneEnd()
  M.lib.inSceneDraw(0, 0, w, h)
end

return M
