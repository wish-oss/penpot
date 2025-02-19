pub mod debug;
pub mod images;
pub mod math;
pub mod render;
pub mod shapes;
pub mod state;
pub mod utils;
pub mod view;

use skia_safe as skia;

use crate::state::State;
use crate::utils::uuid_from_u32_quartet;

static mut STATE: Option<Box<State>> = None;

extern "C" {
    fn emscripten_GetProcAddress(
        name: *const ::std::os::raw::c_char,
    ) -> *const ::std::os::raw::c_void;
}

fn init_gl() {
    unsafe {
        gl::load_with(|addr| {
            let addr = std::ffi::CString::new(addr).unwrap();
            emscripten_GetProcAddress(addr.into_raw() as *const _) as *const _
        });
    }
}

/// This is called from JS after the WebGL context has been created.
#[no_mangle]
pub extern "C" fn init(width: i32, height: i32, debug: u32) {
    let state_box = Box::new(State::with_capacity(width, height, debug, 2048));
    unsafe {
        STATE = Some(state_box);
    }
}

#[no_mangle]
pub unsafe extern "C" fn render() {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.render_all();
}

#[no_mangle]
pub unsafe extern "C" fn navigate() {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.navigate();
}

#[no_mangle]
pub extern "C" fn reset_canvas() {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.render_state().reset_canvas();
}

#[no_mangle]
pub extern "C" fn resize_canvas(width: i32, height: i32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.resize(width, height);
}

#[no_mangle]
pub extern "C" fn set_view(zoom: f32, x: f32, y: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.viewbox.set_all(zoom, x, y);
}

#[no_mangle]
pub extern "C" fn set_view_zoom(zoom: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.viewbox.set_zoom(zoom);
}

#[no_mangle]
pub extern "C" fn set_view_xy(x: f32, y: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    state.viewbox.set_xy(x, y);
}

#[no_mangle]
pub extern "C" fn use_shape(a: u32, b: u32, c: u32, d: u32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    let id = uuid_from_u32_quartet(a, b, c, d);
    state.use_shape(id);
}

#[no_mangle]
pub unsafe extern "C" fn set_shape_selrect(left: f32, top: f32, right: f32, bottom: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");

    if let Some(shape) = state.current_shape() {
        shape.selrect.set_ltrb(left, top, right, bottom);
    }
}

#[no_mangle]
pub unsafe extern "C" fn set_shape_rotation(rotation: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        shape.rotation = rotation;
    }
}

#[no_mangle]
pub unsafe extern "C" fn set_shape_transform(a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        shape.transform.a = a;
        shape.transform.b = b;
        shape.transform.c = c;
        shape.transform.d = d;
        shape.transform.e = e;
        shape.transform.f = f;
    }
}

#[no_mangle]
pub extern "C" fn add_shape_child(a: u32, b: u32, c: u32, d: u32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    let id = uuid_from_u32_quartet(a, b, c, d);
    if let Some(shape) = state.current_shape() {
        shape.children.push(id);
    }
}

#[no_mangle]
pub extern "C" fn clear_shape_children() {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        shape.children.clear();
    }
}

#[no_mangle]
pub extern "C" fn add_shape_solid_fill(r: u8, g: u8, b: u8, a: f32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        let alpha: u8 = (a * 0xff as f32).floor() as u8;
        let color = skia::Color::from_argb(alpha, r, g, b);
        shape.add_fill(shapes::Fill::from(color));
    }
}

#[no_mangle]
pub extern "C" fn clear_shape_fills() {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        shape.clear_fills();
    }
}

#[no_mangle]
pub extern "C" fn set_shape_blend_mode(mode: i32) {
    let state = unsafe { STATE.as_mut() }.expect("got an invalid state pointer");
    if let Some(shape) = state.current_shape() {
        shape.set_blend_mode(shapes::BlendMode::from(mode));
    }
}

fn main() {
    init_gl();
}
