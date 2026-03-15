use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::sync::Mutex;

use glam::{vec2, Vec2};
use inox2d::formats::inp::parse_inp;
use inox2d::model::Model;
use inox2d::params::Param;
use inox2d::render::InoxRendererExt;
use inox2d_opengl::OpenglRenderer;
use libloading::Library;
use once_cell::sync::Lazy;

static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

fn set_last_error(msg: impl Into<String>) {
    let mut g = LAST_ERROR.lock().unwrap();
    *g = Some(msg.into());
}

#[no_mangle]
pub extern "C" fn inox_last_error(buf: *mut c_char, buf_len: usize) -> usize {
    let msg = LAST_ERROR
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| "".to_string());
    let bytes = msg.as_bytes();
    if buf.is_null() || buf_len == 0 {
        return bytes.len() + 1;
    }
    let n = bytes.len().min(buf_len.saturating_sub(1));
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    n + 1
}

type GlxGetProcAddress = unsafe extern "C" fn(*const u8) -> *const c_void;

struct GlLoader {
    _lib: Library,
    glx_get_proc: Option<GlxGetProcAddress>,
}

impl GlLoader {
    fn new() -> Result<Self, String> {
        let lib = unsafe { Library::new("libGL.so.1") }
            .map_err(|e| format!("Failed to load libGL.so.1: {e}"))?;

        let glx_get_proc = unsafe {
            lib.get::<GlxGetProcAddress>(b"glXGetProcAddressARB\0")
                .ok()
                .map(|s| *s)
        };

        Ok(Self {
            _lib: lib,
            glx_get_proc,
        })
    }

    fn get_proc(&self, symbol: &str) -> *const c_void {
        let Ok(cstr) = CString::new(symbol) else {
            return ptr::null();
        };
        unsafe {
            if let Some(f) = self.glx_get_proc {
                let p = f(cstr.as_ptr() as *const u8);
                if !p.is_null() {
                    return p;
                }
            }
            let p = self._lib.get::<*const c_void>(cstr.as_bytes_with_nul());
            p.ok().map(|s| *s).unwrap_or(ptr::null())
        }
    }
}

static GL_LOADER: Lazy<Result<GlLoader, String>> = Lazy::new(GlLoader::new);

#[repr(C)]
pub struct InoxHandle {
    model: Model,
    renderer: OpenglRenderer,
    params: Vec<ParamInfo>,
    first_frame: bool,
    width: u32,
    height: u32,
}

#[derive(Clone)]
struct ParamInfo {
    name: String,
    is_vec2: bool,
    min: Vec2,
    max: Vec2,
}

fn build_param_cache(params: &HashMap<String, Param>) -> Vec<ParamInfo> {
    let mut out: Vec<ParamInfo> = params
        .values()
        .map(|p| ParamInfo {
            name: p.name.clone(),
            is_vec2: p.is_vec2,
            min: p.min,
            max: p.max,
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn make_glow_context() -> Result<glow::Context, String> {
    let loader = GL_LOADER
        .as_ref()
        .map_err(|e| format!("OpenGL loader init failed: {e}"))?;
    Ok(unsafe {
        glow::Context::from_loader_function(|s| loader.get_proc(s) as *const _)
    })
}

fn init_model_from_bytes(bytes: &[u8]) -> Result<Model, String> {
    let mut model = parse_inp(bytes).map_err(|e| format!("Failed to parse .inx/.inp: {e}"))?;

    model.puppet.init_transforms();
    model.puppet.init_rendering();
    model.puppet.init_params();
    model.puppet.init_physics();
    Ok(model)
}

#[no_mangle]
pub extern "C" fn inox_create(path: *const c_char, width: u32, height: u32) -> *mut InoxHandle {
    if path.is_null() {
        set_last_error("inox_create: null path");
        return ptr::null_mut();
    }

    let path = unsafe { CStr::from_ptr(path) };
    let path_str = match path.to_str() {
        Ok(s) => s,
        Err(e) => {
            set_last_error(format!("inox_create: invalid UTF-8 path: {e}"));
            return ptr::null_mut();
        }
    };

    let bytes = match std::fs::read(path_str) {
        Ok(b) => b,
        Err(e) => {
            set_last_error(format!("inox_create: failed to read file '{path_str}': {e}"));
            return ptr::null_mut();
        }
    };

    let model = match init_model_from_bytes(&bytes) {
        Ok(m) => m,
        Err(e) => {
            set_last_error(e);
            return ptr::null_mut();
        }
    };

    let gl = match make_glow_context() {
        Ok(g) => g,
        Err(e) => {
            set_last_error(e);
            return ptr::null_mut();
        }
    };

    let mut renderer = match OpenglRenderer::new(gl, &model) {
        Ok(r) => r,
        Err(e) => {
            set_last_error(format!("OpenglRenderer::new failed: {e}"));
            return ptr::null_mut();
        }
    };

    renderer.resize(width, height);
    renderer.camera.scale = Vec2::splat(0.15);

    let params = build_param_cache(model.puppet.params());

    let handle = InoxHandle {
        model,
        renderer,
        params,
        first_frame: true,
        width,
        height,
    };
    Box::into_raw(Box::new(handle))
}

#[no_mangle]
pub extern "C" fn inox_destroy(handle: *mut InoxHandle) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn inox_resize(handle: *mut InoxHandle, width: u32, height: u32) -> c_int {
    if handle.is_null() {
        set_last_error("inox_resize: null handle");
        return 0;
    }
    let h = unsafe { &mut *handle };
    h.width = width;
    h.height = height;
    h.renderer.resize(width, height);
    1
}

#[no_mangle]
pub extern "C" fn inox_begin_frame(handle: *mut InoxHandle) -> c_int {
    if handle.is_null() {
        set_last_error("inox_begin_frame: null handle");
        return 0;
    }
    let h = unsafe { &mut *handle };
    h.model.puppet.begin_frame();
    1
}

#[no_mangle]
pub extern "C" fn inox_set_param(handle: *mut InoxHandle, name: *const c_char, x: f32, y: f32) -> c_int {
    if handle.is_null() {
        set_last_error("inox_set_param: null handle");
        return 0;
    }
    if name.is_null() {
        set_last_error("inox_set_param: null name");
        return 0;
    }
    let h = unsafe { &mut *handle };
    let name = unsafe { CStr::from_ptr(name) };
    let Ok(name) = name.to_str() else {
        set_last_error("inox_set_param: invalid UTF-8 name");
        return 0;
    };
    let Some(ctx) = h.model.puppet.param_ctx.as_mut() else {
        set_last_error("inox_set_param: param_ctx not initialized");
        return 0;
    };
    match ctx.set(name, vec2(x, y)) {
        Ok(()) => 1,
        Err(_) => 0,
    }
}

#[no_mangle]
pub extern "C" fn inox_end_frame(handle: *mut InoxHandle, dt: f32) -> c_int {
    if handle.is_null() {
        set_last_error("inox_end_frame: null handle");
        return 0;
    }
    let h = unsafe { &mut *handle };
    let dt = if h.first_frame {
        h.first_frame = false;
        0.0
    } else {
        dt.max(0.0)
    };
    h.model.puppet.end_frame(dt);
    1
}

#[no_mangle]
pub extern "C" fn inox_draw(handle: *mut InoxHandle) -> c_int {
    if handle.is_null() {
        set_last_error("inox_draw: null handle");
        return 0;
    }
    let h = unsafe { &mut *handle };

    h.renderer.clear();
    let puppet = &h.model.puppet;
    h.renderer.on_begin_draw(puppet);
    h.renderer.draw(puppet);
    h.renderer.on_end_draw(puppet);
    1
}

#[no_mangle]
pub extern "C" fn inox_param_count(handle: *mut InoxHandle) -> usize {
    if handle.is_null() {
        return 0;
    }
    let h = unsafe { &mut *handle };
    h.params.len()
}

#[no_mangle]
pub extern "C" fn inox_param_name(
    handle: *mut InoxHandle,
    index: usize,
    buf: *mut c_char,
    buf_len: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let h = unsafe { &mut *handle };
    let Some(p) = h.params.get(index) else {
        return 0;
    };
    let bytes = p.name.as_bytes();
    if buf.is_null() || buf_len == 0 {
        return bytes.len() + 1;
    }
    let n = bytes.len().min(buf_len.saturating_sub(1));
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    n + 1
}

#[no_mangle]
pub extern "C" fn inox_param_is_vec2(handle: *mut InoxHandle, index: usize) -> c_int {
    if handle.is_null() {
        return 0;
    }
    let h = unsafe { &mut *handle };
    let Some(p) = h.params.get(index) else {
        return 0;
    };
    if p.is_vec2 {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn inox_param_minmax(
    handle: *mut InoxHandle,
    index: usize,
    xmin: *mut f32,
    ymin: *mut f32,
    xmax: *mut f32,
    ymax: *mut f32,
) -> c_int {
    if handle.is_null() {
        return 0;
    }
    let h = unsafe { &mut *handle };
    let Some(p) = h.params.get(index) else {
        return 0;
    };
    unsafe {
        if !xmin.is_null() {
            *xmin = p.min.x;
        }
        if !ymin.is_null() {
            *ymin = p.min.y;
        }
        if !xmax.is_null() {
            *xmax = p.max.x;
        }
        if !ymax.is_null() {
            *ymax = p.max.y;
        }
    }
    1
}
