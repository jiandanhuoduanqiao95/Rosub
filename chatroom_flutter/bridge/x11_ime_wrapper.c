// x11_ime_wrapper.c —— 非变参 C 包装器，供 dart:ffi 调用
// 编译: gcc -shared -fPIC -o libx11ime.so x11_ime_wrapper.c -lX11

#include <X11/Xlib.h>
#include <stdlib.h>

// 返回 {Display*, XIM, XIC} 三级指针数组，失败返回 NULL
void** x11_ime_init(unsigned long window) {
    Display* dpy = XOpenDisplay(NULL);
    if (!dpy) return NULL;
    XIM xim = XOpenIM(dpy, NULL, NULL, NULL);
    if (!xim) { XCloseDisplay(dpy); return NULL; }
    XIC xic = XCreateIC(xim,
        XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
        XNClientWindow, (Window)window,
        NULL);
    if (!xic) { XCloseIM(xim); XCloseDisplay(dpy); return NULL; }
    void** r = malloc(3 * sizeof(void*));
    r[0] = dpy; r[1] = xim; r[2] = xic;
    return r;
}

// 处理一个按键事件，返回 IME 组合后的 UTF-8 字节数 (0=IME未产生字符)
int x11_ime_process(void** ctx, int state, unsigned int keycode,
                    char* out_buf, int buf_size) {
    XKeyEvent ev = {0};
    ev.type = KeyPress;
    ev.display = (Display*)ctx[0];
    ev.window = XDefaultRootWindow((Display*)ctx[0]);
    ev.root = ev.window;
    ev.state = state;
    ev.keycode = keycode;
    ev.same_screen = 1;

    XFilterEvent((XEvent*)&ev, ev.window);
    KeySym ks;
    Status st;
    int len = Xutf8LookupString((XIC)ctx[2], &ev, out_buf, buf_size - 1, &ks, &st);
    if (len > 0) out_buf[len] = 0;
    return len;
}

void x11_ime_set_focus(void** ctx, int focused) {
    if (focused) XSetICFocus((XIC)ctx[2]);
    else XUnsetICFocus((XIC)ctx[2]);
}

void x11_ime_destroy(void** ctx) {
    if (ctx[2]) XDestroyIC((XIC)ctx[2]);
    if (ctx[1]) XCloseIM((XIM)ctx[1]);
    if (ctx[0]) XCloseDisplay((Display*)ctx[0]);
    free(ctx);
}
