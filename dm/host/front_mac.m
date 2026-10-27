// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN starts it that way. ⌘Q quits; the left mouse button is the touchscreen.
// Escape or a controller's Home button opens the in-game menu (display, controls, mods: see the end of this file).
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−, Space=shake the controller.
// Controllers: buttons by position as on the iPhone (right A, bottom B, top X, left Y), shoulders L R, triggers ZL ZR, Menu + Options −, both sticks and their presses.
// Each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h);
// DM_PAD_MERGE=1 merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the controllers from player 2 on.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include <signal.h>
#include <math.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;
static int g_input_on = 1;   // main thread: the game window is key, so its keyboard, mouse and controllers reach the game (input_release / input_resume)
static int g_menu_open, g_menu_swallow, g_abxy = -2;   // the in-game menu (end of this file) is up; controller buttons held as it closed, kept from the game until released; DM_PAD_ABXY
static int menu_key(unsigned short c, int down); static void menu_pad(uint64_t m, int32_t ly); static void menu_toggle(void); static void menu_home(const char *from); static void hdr_apply(int lvl);

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}
static void push(void) {
    int32_t lx = (g_d - g_a) * 32767, ly = (g_w - g_s) * 32767;
    dm_input_set(g_btn, lx, ly, 0, 0);
}
static int key_bit(unsigned short code) {
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 48: return 11;                                          // Return Tab → + −
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void on_key(NSEvent *e, int down) {
    if (!g_input_on) return;
    unsigned short c = e.keyCode;
    if (menu_key(c, down)) return;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    uint64_t m = b >= 0 ? 1ull << b : c == 49 ? DM_BTN_SHAKE : 0;   // Space: shaken while held
    g_btn = down ? (g_btn | m) : (g_btn & ~m);
    push();
}

// Physical controllers (GameController) go to dm_pad_set_player, mapped as the iPhone's (DmGamepad.m read_pad, same layout); player 1's is ORed with the keyboard, a stick takes
// whichever is deflected more (hle_hid.c). DM_KEYS uses player 1's path, so player 1's controller touched during a script takes it over.
// Players: every controller with an extended gamepad profile holds a slot (pad_slots.h: player 1 first, a reconnected controller gets its player back), and hle_hid.c reports
// player n on its own npad while the slot is held (dm_pad_players). A one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c).
// With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins; when the last one goes away its buttons and sticks are released)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_kbd_own;
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX); }
// Face buttons. macOS names a Nintendo controller's buttons by their labels (its buttonA is the button marked A, on the right), so the positional
// map below swapped A/B and X/Y on a Switch Pro Controller. Nintendo pads (Pro Controller, Joy-Con) therefore map by label and the others by
// position; DM_PAD_ABXY=label or position forces one map for every controller (auto, the default, decides per controller).
static void abxy_init(void) { if (g_abxy == -2) { const char *e = getenv("DM_PAD_ABXY"); g_abxy = e && !strcmp(e, "label") ? 1 : e && !strcmp(e, "position") ? 0 : -1; } }
static int pad_by_label(GCController *c) {
    abxy_init();
    if (g_abxy >= 0) return g_abxy;   // the in-game menu can change it
    NSString *s = [NSString stringWithFormat:@"%@ %@", c.productCategory ?: @"", c.vendorName ?: @""];
    for (NSString *n in @[@"Pro Controller", @"Joy-Con", @"Nintendo", @"Switch"])
        if ([s rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) return 1;
    return 0;
}
static int home_ok(void) { return g_input_on || NSApp.isActive; }   // Home still works while something else of this app's (a system panel) holds the key window
static void pad_read(GCExtendedGamepad *g) {
    static int home_down; int home = g.buttonHome.isPressed;   // Home (a Pro Controller's, an 8BitDo's heart) opens and closes the in-game menu
    if (home && !home_down && home_ok()) menu_home("controller");
    home_down = home;
    if (!g_input_on) return;
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    if (pad_by_label(g.controller)) { K(g.buttonA, DM_BTN_A); K(g.buttonB, DM_BTN_B); K(g.buttonX, DM_BTN_X); K(g.buttonY, DM_BTN_Y); }   // by label (Nintendo pads)
    else { K(g.buttonB, DM_BTN_A); K(g.buttonA, DM_BTN_B); K(g.buttonY, DM_BTN_X); K(g.buttonX, DM_BTN_Y); }   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    if (g_menu_open) { menu_pad(m, pad_axis(g.leftThumbstick.yAxis.value)); return; }
    if (g_menu_swallow) { if (m) m = 0; else g_menu_swallow = 0; }   // the button that closed the menu does not reach the game
    dm_pad_set_player(p, m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
// Motion: a controller with sensors (a Switch Pro Controller, a DualSense) feeds its player's six-axis sensor (dm_pad_set_motion, hle_hid.c); Super Mario Galaxy's docked
// pointer is the gyro. GameController's axes need not be the Switch's (x right, y away from the player, z up out of the face: lying flat, gravity (0, 0, -1)):
// DM_GYRO_AXES maps them, the GameController axis for the Switch's x, y and z, each with an optional minus (default x,y,z); DM_GYRO=0 keeps the sensor lying flat.
static int g_gaxis[3] = {0, 1, 2}, g_gyro_state = -1;   // -1 not read yet, 0 off, 1 on
static float g_gsign[3] = {1, 1, 1};
static void gyro_init(void) {
    const char *e = getenv("DM_GYRO"); g_gyro_state = !(e && !strcmp(e, "0"));
    const char *a = getenv("DM_GYRO_AXES"); if (!a) return;
    int ax[3], k = 0; float sg[3];
    for (const char *s = a; *s && k < 3; s++) {
        float sign = 1; if (*s == '-') { sign = -1; s++; }
        if (*s < 'x' || *s > 'z') break;
        sg[k] = sign; ax[k++] = *s - 'x';
        while (s[1] && s[1] != ',') s++; if (s[1] == ',') s++;
    }
    if (k == 3) { memcpy(g_gaxis, ax, sizeof ax); memcpy(g_gsign, sg, sizeof sg); }
    else LOG("[RED] DM_GYRO_AXES=%s: three of x y z expected (such as -y,x,z), keeping x,y,z", a);
}
static void motion_on(GCController *c) {
    if (g_gyro_state < 0) gyro_init();
    GCMotion *mo = c.motion;
    if (!g_gyro_state || !mo || !mo.hasRotationRate) return;
    if (mo.sensorsRequireManualActivation) mo.sensorsActive = YES;
    LOG("controller '%s': motion sensors on (axes %s%c,%s%c,%s%c; DM_GYRO_AXES remaps them)", pad_name(c), g_gsign[0] < 0 ? "-" : "", 'x' + g_gaxis[0],
        g_gsign[1] < 0 ? "-" : "", 'x' + g_gaxis[1], g_gsign[2] < 0 ? "-" : "", 'x' + g_gaxis[2]);
    __weak GCController *wc = c;
    mo.valueChangedHandler = ^(GCMotion *m) {
        GCController *cc = wc; if (!cc || !g_input_on || g_menu_open) return;
        int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)cc); if (p < 0) return;
        double a[3], w[3];
        if (m.hasGravityAndUserAcceleration) { a[0] = m.gravity.x + m.userAcceleration.x; a[1] = m.gravity.y + m.userAcceleration.y; a[2] = m.gravity.z + m.userAcceleration.z; }
        else { a[0] = m.acceleration.x; a[1] = m.acceleration.y; a[2] = m.acceleration.z; }
        w[0] = m.rotationRate.x; w[1] = m.rotationRate.y; w[2] = m.rotationRate.z;   // radians / s
        // GameController sends a Switch Pro Controller's motion events with every value zero (macOS 27: active, 60 per second, still zero while it turns), so a player's
        // sensor switches to real motion only from the first reading with data; until then games keep the flat sensor (and its shake) exactly as before
        static int live[DM_PLAYERS];
        if (!live[p]) {
            if (fabs(a[0]) + fabs(a[1]) + fabs(a[2]) + fabs(w[0]) + fabs(w[1]) + fabs(w[2]) < 1e-6) return;
            live[p] = 1; LOG("controller '%s': motion data arriving", pad_name(cc));
        }
        float acc[3], gyro[3];
        for (int i = 0; i < 3; i++) { acc[i] = g_gsign[i] * (float)a[g_gaxis[i]]; gyro[i] = g_gsign[i] * (float)(w[g_gaxis[i]] / (2 * M_PI)); }
        static int n;   // the first readings, for working out DM_GYRO_AXES: lying flat, the Switch's gravity is (0, 0, -1)
        static int every = -1; if (every < 0) { const char *e = getenv("DM_GYRO_LOG"); every = e ? atoi(e) : 0; }   // DM_GYRO_LOG=<n>: log every n-th reading
        if (++n == 200 || n == 1500 || (every > 0 && n % every == 0))
            LOG("controller motion #%d: active %d (manual %d), gravity+user %d, attitude %d; acceleration (%.2f, %.2f, %.2f), gravity (%.2f, %.2f, %.2f), raw acceleration (%.2f, %.2f, %.2f) G, "
                "rotation (%.2f, %.2f, %.2f) rad/s → Switch acceleration (%.2f, %.2f, %.2f)", n, m.sensorsActive, m.sensorsRequireManualActivation, m.hasGravityAndUserAcceleration,
                m.hasAttitude, a[0], a[1], a[2], m.gravity.x, m.gravity.y, m.gravity.z, m.acceleration.x, m.acceleration.y, m.acceleration.z, w[0], w[1], w[2], acc[0], acc[1], acc[2]);
        dm_pad_set_motion(p, acc, gyro, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    };
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    if (g_merge) {
        int any = 0;
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && c != gone) {
            any = 1; c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
            pad_read(c.extendedGamepad);
        }
        if (!any) { dm_pad_set(0, 0, 0, 0, 0); dm_haptics_apple_controller(0, nil); }
        return;
    }
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        g_held[p].motion.valueChangedHandler = nil; dm_pad_motion_gone(p);
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c;
        c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;   // Home opens the in-game menu, not the system's
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
        npad_name(p, nb, sizeof nb); LOG("controller '%s' (%s) connected: player %d (npad %s), face buttons by %s", pad_name(c), c.productCategory.UTF8String ?: "?", p + 1, nb, pad_by_label(c) ? "label" : "position");
        motion_on(c);
        pad_read(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
}
// Focus: a window that is no longer key sees no key-up, mouse-up or controller release, so whatever is held when it loses focus (another app, the text box, minimized) would
// stay pressed in the game. The front end releases only what it pressed itself: player 1's pad and the touch are also DM_KEYS / DM_CTL's (hle_hid.c), and a scripted hold goes on.
// Out of focus a controller's changes are ignored, so back in focus each controller is read as it is now (a button still held, a stick still deflected)
static int g_mouse_down;   // the mouse holds the touch (DmGameView)
static void input_release(void) {
    g_input_on = 0;
    g_btn = 0; g_w = g_a = g_s = g_d = 0; push();
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) { dm_pad_set(0, 0, 0, 0, 0); break; } }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
static void input_resume(void) {
    g_input_on = 1;
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) pad_read(c.extendedGamepad); }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p].extendedGamepad) pad_read(g_held[p].extendedGamepad);
}
// A Switch Pro Controller's motion, read from its HID reports: GameController gives its GCMotion all zeros, but macOS's own driver keeps the controller in the
// full report mode (0x30, about 60 per second on Bluetooth) with its IMU on, and IOKit lets the host read those reports beside it without sending anything.
// Each 0x30 report holds three samples 5 ms apart from byte 13: accelerometer x y z and gyroscope x y z, int16 little endian, in the controller's own axes
// (x towards the shoulder buttons, y to the left, z up out of the face; lying flat the accelerometer reads +1 G on z). Measured on a Pro Controller on macOS 27:
// turning it flat on the desk turns about z, tilting the front up turns about y while the x reading swings with gravity, rolling it turns about x.
// The Switch's SixAxisSensorState axes are x right, y away from the player, z up, with gravity (0, 0, -1) lying flat (hle_hid.c): acceleration (raw y, -raw x, -raw z),
// angular velocity (-raw y, raw x, raw z). Scales: ±8 G (4096 per G) and ±2000 degrees / s (0.061 per unit). The gyroscope's resting offset is followed while it is still.
// DM_GYRO_AXES (motion_on) reorders and flips the result; DM_GYRO=0 or DM_GYRO_HID=0 turns this reader off.
static IOHIDManagerRef g_hid;
static double g_gbias[3]; static int g_gbias_n;
static int pro_player(void) {   // the player of the first Pro Controller GameController knows, else player 1
    if (g_merge) return 0;
    for (GCController *c in GCController.controllers)
        if ([c.productCategory rangeOfString:@"Pro Controller"].location != NSNotFound) { int p = pad_slot_of(&g_slots, (__bridge const void *)c); if (p >= 0) return p; }
    return 0;
}
static void pro_report(void *ctx, IOReturn res, void *sender, IOHIDReportType type, uint32_t id, uint8_t *r, CFIndex len) {
    (void)ctx; (void)res; (void)sender; (void)type; (void)id;
    if (len < 49 || r[0] != 0x30) return;
    static int home_down; int home = (r[4] & 0x10) != 0;   // byte 4: − + RS LS Home Capture; macOS does not pass a Pro Controller's Home to GameController
    if (home && !home_down && home_ok()) menu_home("Pro Controller report");
    home_down = home;
    if (!g_input_on) return;
    if (g_menu_open || !g_gyro_state) return;
    static int first = 1;
    if (first) { first = 0; LOG("controller motion: reading the Pro Controller's own reports (HID 0x30)"); }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int p = pro_player();
    for (int k = 0; k < 3; k++) {
        const uint8_t *s = r + 13 + 12 * k;
        int16_t v[6]; for (int i = 0; i < 6; i++) v[i] = (int16_t)(s[2 * i] | s[2 * i + 1] << 8);
        double g[3] = {v[3], v[4], v[5]};
        if (fabs(g[0]) < 40 && fabs(g[1]) < 40 && fabs(g[2]) < 40) {   // still (under ~2.5 degrees / s): follow the resting offset
            double a = g_gbias_n < 200 ? 1.0 / ++g_gbias_n : 0.005;
            for (int i = 0; i < 3; i++) g_gbias[i] += (g[i] - g_gbias[i]) * a;
        }
        for (int i = 0; i < 3; i++) g[i] -= g_gbias[i];
        double dps = 0.06103 / 360;   // raw units to revolutions / s
        float accs[3] = {(float)(v[1] / 4096.0), (float)(-v[0] / 4096.0), (float)(-v[2] / 4096.0)};
        float gyros[3] = {(float)(-g[1] * dps), (float)(g[0] * dps), (float)(g[2] * dps)}, acc[3], gyro[3];
        for (int i = 0; i < 3; i++) { acc[i] = g_gsign[i] * accs[g_gaxis[i]]; gyro[i] = g_gsign[i] * gyros[g_gaxis[i]]; }
        dm_pad_set_motion(p, acc, gyro, now - (uint64_t)(2 - k) * 5000000);
    }
    static int n; static int every = -1; if (every < 0) { const char *e = getenv("DM_GYRO_LOG"); every = e ? atoi(e) : 0; }
    if (every > 0 && ++n % every == 0) {
        const uint8_t *s = r + 13; int16_t v[6]; for (int i = 0; i < 6; i++) v[i] = (int16_t)(s[2 * i] | s[2 * i + 1] << 8);
        LOG("controller motion (HID) #%d: raw accel %d %d %d gyro %d %d %d, gyro offset %.0f %.0f %.0f", n, v[0], v[1], v[2], v[3], v[4], v[5], g_gbias[0], g_gbias[1], g_gbias[2]);
    }
}
static void pro_found(void *ctx, IOReturn res, void *sender, IOHIDDeviceRef d) {   // a Pro Controller appeared (at start or later): listen to its reports
    (void)ctx; (void)res; (void)sender;
    static uint8_t buf[512];   // one controller is read; a second one's reports would share it (the callback copies nothing out of it later)
    IOHIDDeviceRegisterInputReportCallback(d, buf, sizeof buf, pro_report, NULL);
    id t = (__bridge id)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
    LOG("controller motion: Pro Controller found over HID (%s)", t ? [t description].UTF8String : "?");
}
static void pro_hid_start(void) {
    if (g_gyro_state < 0) gyro_init();
    const char *e = getenv("DM_GYRO_HID");
    if (e && !strcmp(e, "0")) return;   // with motion off the reports still give the Home button (the in-game menu)
    g_hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(g_hid, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009});
    IOHIDManagerRegisterDeviceMatchingCallback(g_hid, pro_found, NULL);
    IOHIDManagerScheduleWithRunLoop(g_hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(g_hid, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) LOG("[RED] controller motion: cannot open HID devices (0x%x%s); the Pro Controller's sensors stay off", r, r == kIOReturnNotPermitted ? ", not permitted" : "");
}
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_KBD_PLAYER"); g_kbd_own = !g_merge && e && !strcmp(e, "own");
    static const char kbd = 0;
    if (g_kbd_own) pad_slot_take(&g_slots, &kbd, "keyboard");   // holds player 1 for good
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : g_kbd_own ? "the keyboard is player 1, each controller a player of its own from player 2 on (DM_KBD_PLAYER=own)"
                                                                           : "each controller is a player of its own, the keyboard plays with player 1");
    pads_changed(nil);
    pro_hid_start();
}

// Mouse as a single-point touchscreen (front.h dm_touch_set): left button down / drag = finger 0, release = lifted. The content view takes the clicks,
// not a window-wide event monitor, so clicks on the title bar, the window buttons and the resize edges still reach AppKit.
@interface DmGameView : NSView @end
@implementation DmGameView
- (void)mouseDown:(NSEvent *)e { [self mouseDragged:e]; }
- (void)mouseDragged:(NSEvent *)e {
    if (!g_input_on || g_menu_open) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the centered 16:9 picture the present fits into the view, as on the iPhone (DmGamepad.m)
    double x0 = (b.width - w) / 2, y0 = (b.height - h) / 2;
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1); g_mouse_down = 1;
}
- (void)mouseUp:(NSEvent *)e { (void)e; if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); } }
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self fitDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end

// A quit through exit() (⌘Q, Quit game, Restart now, the window closed, the game ending) says so in the log; a crash leaves through _exit (crash.c) and does not.
// The launcher's settings safety net (switchports/safe_launch.py) counts a trial run that ended this way as good
static void exit_log(void) { LOG("exit: the app quit normally"); }

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void hud_env(void) { front_hud_env(); }
void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    atexit(exit_log);
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        NSView *v = win.contentView = [[DmGameView alloc] initWithFrame:r];
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
        v.layer = g_layer; [(DmGameView *)v fitDrawable];
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        // Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
        [app addItemWithTitle:@"Quit " DM_GAME_NAME action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""] setSubmenu:wm];
        [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"].keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        NSApp.mainMenu = bar;
        if (getenv("DM_FULLSCREEN")) dispatch_async(dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });   // start in fullscreen
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); }];
        dm_haptics_apple_init();
        pads_start();
        if (getenv("DM_AUTO_HDR") && atoi(getenv("DM_AUTO_HDR")) > 0) hdr_apply(atoi(getenv("DM_AUTO_HDR")));   // Auto HDR from the start (the in-game menu sets it)
        // The pointer hides in fullscreen once the mouse has kept still for DM_CURSOR_HIDE seconds (default 3, 0 = never) and shows again as it moves (AppKit's
        // hidden-until-moved); not while a button is held, as the mouse is the touchscreen
        static NSPoint last_at; static double still; static int hidden;
        const char *ch = getenv("DM_CURSOR_HIDE"); double hide_after = ch ? atof(ch) : 3;
        if (hide_after > 0) [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t;
            NSPoint at = NSEvent.mouseLocation;
            if (!NSEqualPoints(at, last_at) || g_mouse_down || !(win.styleMask & NSWindowStyleMaskFullScreen) || !win.isKeyWindow) { last_at = at; still = 0; hidden = 0; return; }
            if ((still += 0.5) >= hide_after && !hidden) { [NSCursor setHiddenUntilMouseMoves:YES]; hidden = 1; }
        }];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1).
        // Input is released when the window stops being key (and when it is minimized) and taken up again when it is key again
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n;
            LOG("front end: the game window lost the keyboard (key window now %s, app %s)", NSApp.keyWindow ? NSApp.keyWindow.className.UTF8String : "none", NSApp.isActive ? "active" : "in the background");
            input_release(); if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_resume(); dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's, the title, a bar and a count, centered; AppKit views, so it draws while the game's thread waits
static NSView *g_prog; static NSTextField *g_prog_title, *g_prog_count; static NSProgressIndicator *g_prog_bar;
static NSTextField *prog_label(NSRect r, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""]; t.frame = r; t.alignment = NSTextAlignmentCenter; t.textColor = c;
    t.font = [NSFont monospacedDigitSystemFontOfSize:size weight:w]; return t;
}
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            NSView *cv = g_win.contentView;
            g_prog = [[NSView alloc] initWithFrame:cv.bounds]; g_prog.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g_prog.wantsLayer = YES; g_prog.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:0.94].CGColor;
            NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width - 400) / 2), floor((cv.bounds.size.height - 96) / 2), 400, 96)];
            box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
            g_prog_title = prog_label(NSMakeRect(0, 62, 400, 30), 20, NSFontWeightSemibold, NSColor.whiteColor);
            g_prog_bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 36, 360, 20)];
            g_prog_bar.style = NSProgressIndicatorStyleBar; g_prog_bar.indeterminate = NO; g_prog_bar.minValue = 0;
            g_prog_count = prog_label(NSMakeRect(0, 4, 400, 22), 13, NSFontWeightRegular, [NSColor colorWithWhite:0.72 alpha:1]);
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [cv addSubview:g_prog];
        }
        g_prog_title.stringValue = tt; g_prog_bar.maxValue = total > 0 ? (double)total : 1; g_prog_bar.doubleValue = (double)done;
        g_prog_count.stringValue = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                                    [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;   // hle_swkbd.c: this input's minimum length from ShowKeyboardArg; the applet keeps OK disabled until the text is long enough
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The box takes the keyboard and the mouse, so the game window never sees the key-up of the button or the touch-up of the click that opened it: nothing may stay pressed
        // while it is up, or the game reads the stuck button / touch the moment the box closes (Stardew Valley's character creation re-opened the keyboard endlessly)
        g_btn = 0; g_w = g_a = g_s = g_d = 0; push();
        dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input";
            a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn;
            text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            // On hardware the applet would not have accepted the shorter text (OK stayed disabled); a game that rejects it re-opens the keyboard for ever, so the box comes back with the rule instead
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}

// In-game menu: Escape, or the controller's Home button (a Pro Controller's Home, an 8BitDo's heart), opens a panel over the game. Up / down (arrow keys, the D-pad or the
// left stick) choose a line, A / Return / Space / left / right change it, B / Escape / Home close it. The game is told it lost focus while the panel is up, and gets no input.
// Display and control settings change at once; console mode and mods take a restart (the "Restart to apply" line), since the game reads them as it starts. Every change is
// written to settings.env in the game's Application Support folder (DM_ROOT), which the launcher reads at the next start. Mods are the pchtxt mods the game was built or
// patched with (<module>.mods.tsv beside the code): switching one off lists it in DM_MODS_OFF, whose patches the loader puts back to the original bytes (loader.c).
int mtl_upscale_get(void); int mtl_upscale_set(int on);   // nvn_mtl.m
void mtl_hdr_set(float peak);
// Auto HDR (DM_AUTO_HDR=1 low, 2 medium, 3 high): the layer takes extended linear values and the present lifts the picture's highlights to 2, 3 or 4 times SDR white
// (nvn_mtl.m hdr_consts), on a screen with HDR headroom such as a MacBook Pro's XDR display; SDR screens clip back to white
static int g_hdr;
static void hdr_apply(int lvl) {
    static const float peak[4] = {0, 2, 3, 4};
    g_hdr = lvl < 0 ? 0 : lvl > 3 ? 3 : lvl;
    if (g_hdr) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        g_layer.wantsExtendedDynamicRangeContent = YES; g_layer.colorspace = cs; g_layer.pixelFormat = MTLPixelFormatRGBA16Float; CGColorSpaceRelease(cs);
        mtl_hdr_set(peak[g_hdr]);
    } else { mtl_hdr_set(0); g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.colorspace = NULL; g_layer.wantsExtendedDynamicRangeContent = NO; }
    LOG("front end: Auto HDR %s (screen headroom now %.1fx, up to %.1fx)", g_hdr ? (const char *[]){"", "low", "medium", "high"}[g_hdr] : "off",
        g_win.screen.maximumExtendedDynamicRangeColorComponentValue, g_win.screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
}
@interface DmMenuRow : NSObject
@property (copy) NSString *title, *section; @property (copy) NSArray<NSString *> *choices; @property int restart, initial;
@property (copy) int (^get)(void); @property (copy) void (^set)(int); @property (copy) void (^act)(void);
@end
@implementation DmMenuRow @end
static NSMutableArray<DmMenuRow *> *g_rows;
static NSView *g_menu; static int g_sel, g_tab, g_confirm, g_csel;   // g_confirm: the restart question is up (g_csel its chosen answer)   // the chosen line; the tab (sections in order, from menu_tabs)
static NSArray<NSString *> *menu_tabs(void);
static int menu_shows(DmMenuRow *r) { NSArray *t = menu_tabs(); return !r.section.length || (g_tab < (int)t.count && [r.section isEqualToString:t[g_tab]]); }
static int g_restart_opmode = -1; static NSMutableOrderedSet<NSString *> *g_mods_all, *g_mods_off;

// settings.env: KEY=value lines (a # comments a line out). A key the menu sets replaces its uncommented line, or is added at the end; nil removes the uncommented line
static void settings_put(NSString *key, NSString *value) {
    const char *root = getenv("DM_ROOT"); if (!root) return;
    NSString *path = [@(root) stringByAppendingPathComponent:@"settings.env"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count && !lines.lastObject.length) [lines removeLastObject];
    NSString *line = value ? [NSString stringWithFormat:@"%@=%@   # set in the in-game menu", key, value] : nil; int done = 0;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *t = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![t hasPrefix:[key stringByAppendingString:@"="]]) continue;
        if (line && !done) { lines[i] = line; done = 1; } else { [lines removeObjectAtIndex:i]; i--; }
    }
    if (line && !done) [lines addObject:line];
    [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LOG("in-game menu: settings.env %s=%s", key.UTF8String, value ? value.UTF8String : "(removed)");
}
static void mods_read(void) {   // every mod file named in the modules' mods records, and DM_MODS_OFF
    g_mods_all = [NSMutableOrderedSet new]; g_mods_off = [NSMutableOrderedSet new];
    const char *dir = dm_code_dir(); if (!dir || !*dir) return;
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:@(dir) error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f hasSuffix:@".mods.tsv"]) continue;
        NSString *t = [NSString stringWithContentsOfFile:[@(dir) stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        for (NSString *l in [t componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *c = [l componentsSeparatedByString:@"\t"];
            if ([l hasPrefix:@"#"] || c.count < 4 || !c[3].length) continue;
            [g_mods_all addObject:c[3].lastPathComponent];
        }
    }
    const char *off = getenv("DM_MODS_OFF");
    if (off) for (NSString *s in [@(off) componentsSeparatedByString:@"|"]) if (s.length) [g_mods_off addObject:s];
}
static NSString *mod_label(NSString *file) {   // "Fl4sh9174 1920x1080 1.3.0-1.4.1.pchtxt" → "1920x1080 1.3.0-1.4.1 (Fl4sh9174)" when the first word is the author's
    NSString *b = file.stringByDeletingPathExtension; NSRange sp = [b rangeOfString:@" "];
    if (sp.location == NSNotFound) return b;
    NSString *who = [b substringToIndex:sp.location], *what = [b substringFromIndex:sp.location + 1];
    return [who rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == NSNotFound || [who containsString:@"-"] ? [NSString stringWithFormat:@"%@ (%@)", what, who] : b;
}
static DmMenuRow *row(NSString *section, NSString *title, NSArray<NSString *> *choices, int (^get)(void), void (^set)(int)) {
    DmMenuRow *r = [DmMenuRow new]; r.section = section; r.title = title; r.choices = choices; r.get = get; r.set = set; [g_rows addObject:r]; return r;
}
static NSArray<NSString *> *menu_tabs(void) {   // the sections that have lines, in order: each is a tab (L / R or Q / E switch them)
    NSMutableOrderedSet<NSString *> *t = [NSMutableOrderedSet new];
    for (DmMenuRow *r in g_rows) if (r.section.length) [t addObject:r.section];
    return t.array;
}
static int menu_pending(void) { for (DmMenuRow *r in g_rows) if (r.restart && r.get && r.get() != r.initial) return 1; return 0; }
static void menu_close(void); static void menu_draw(void); static void menu_restart(void);
// Leaving the menu (Escape, Home, B, Resume) with changes that need a restart asks first: restart now, keep them for the next start, or put them back
static void menu_leave(void) { if (menu_pending()) { g_confirm = 1; g_csel = 0; menu_draw(); } else menu_close(); }
static void menu_answer(int a) {
    g_confirm = 0;
    if (a == 0) { menu_restart(); return; }
    if (a == 2) for (DmMenuRow *r in g_rows) if (r.restart && r.get && r.get() != r.initial) r.set(r.initial);   // settings.env back as it was
    menu_close();
}
static void menu_restart(void) {   // starts the app again a moment after this process has gone (open -n), then quits
    NSString *app = NSBundle.mainBundle.bundlePath;
    LOG("in-game menu: restarting %s", app.UTF8String);
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", @"sleep 1; exec /usr/bin/open -n \"$0\"", app];
    [t launchAndReturnError:nil];
    [NSApp terminate:nil];
}
// The game's own player settings (Resources/game/launcher.json, written by switchports/game_settings.py from nxnative's settings.tsv: the rows that apply to this game, as
// the iOS launcher shows them). The host reads them as the game starts, so each takes a restart; the ones this menu changes live (console mode, upscaling, the HUD) are
// left out. Frame rate gets 120 fps on a screen that shows 120 Hz: nxnative paces those games itself (fps_target), so the game keeps its speed; it also sets the 120 Hz link
static NSArray *g_game_settings;
static void menu_game_settings(NSString *section) {
    if (!g_game_settings) {
        const char *dir = dm_code_dir();
        NSData *d = dir && *dir ? [NSData dataWithContentsOfFile:[[@(dir) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"launcher.json"]] : nil;
        g_game_settings = d ? ([NSJSONSerialization JSONObjectWithData:d options:0 error:nil][@"settings"] ?: @[]) : @[];
    }
    static NSMutableDictionary<NSString *, NSNumber *> *pick; if (!pick) pick = [NSMutableDictionary new];   // the choice made in this session, kept across menu openings
    for (NSDictionary *st in g_game_settings) {
        NSString *env = st[@"env"], *kind = st[@"kind"], *def = [st[@"default"] description] ?: @"";
        if (![st[@"section"] isEqualToString:section] || [@[@"DM_OPMODE", @"DM_PRESENT_UPSCALE", @"DM_METAL_HUD", @"DM_TOUCH_HAPTICS"] containsObject:env]) continue;
        NSMutableArray<NSString *> *vals = [NSMutableArray new], *labels = [NSMutableArray new];
        if ([kind isEqualToString:@"choice"]) for (NSArray *o in st[@"options"]) { [vals addObject:[o[0] description]]; [labels addObject:o[1]]; }
        else if ([kind isEqualToString:@"toggle"]) { [vals addObject:[st[@"off"] description]]; [labels addObject:@"Off"]; [vals addObject:[st[@"on"] description]]; [labels addObject:@"On"]; }
        else if ([kind isEqualToString:@"range"]) {
            double lo = [st[@"min"] doubleValue], hi = [st[@"max"] doubleValue], step = [st[@"step"] doubleValue]; if (step <= 0) continue;
            for (double v = lo; v <= hi + step / 2; v += step) { [vals addObject:[NSString stringWithFormat:@"%g", round(v * 1000) / 1000]]; [labels addObject:[NSString stringWithFormat:@"%.0f%%", v * 100]]; }
        } else continue;
        int fps = [env isEqualToString:@"DM_FPS_TARGET"];
        if (fps && g_screen_fps >= 120 && ![vals containsObject:@"120"]) { [vals addObject:@"120"]; [labels addObject:@"120 fps"]; }
        const char *cur = getenv(env.UTF8String); NSString *now = cur ? @(cur) : def;
        int init = 0; double best = INFINITY;
        for (int i = 0; i < (int)vals.count; i++) { double dd = fabs(vals[i].doubleValue - now.doubleValue); if ([vals[i] isEqualToString:now]) { best = -1; init = i; break; } if (dd < best) { best = dd; init = i; } }
        if (!pick[env]) pick[env] = @(init);
        NSString *label = st[@"label"];
        DmMenuRow *r = row(section, label, labels, ^int { return pick[env].intValue; }, ^(int v) {
            pick[env] = @(v); NSString *val = vals[v];
            settings_put(env, [val isEqualToString:def] ? nil : val);
            if (fps) { int hi = val.intValue > 60; settings_put(@"DM_PRESENT_HZ", hi ? val : nil); settings_put(@"DM_PRESENT_LINK", hi ? @"2" : nil); }
        });
        r.restart = 1; r.initial = init;
    }
}
static void menu_build(void) {
    g_rows = [NSMutableArray new]; mods_read();
    NSArray *onoff = @[@"Off", @"On"];
    row(@"Display", @"Full screen", onoff, ^int { return (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0; },
        ^(int v) { if (v != ((g_win.styleMask & NSWindowStyleMaskFullScreen) != 0)) [g_win toggleFullScreen:nil]; settings_put(@"DM_FULLSCREEN", v ? nil : @"0"); });
    row(@"Display", @"Auto HDR", @[@"Off", @"Low", @"Medium", @"High"], ^int { return g_hdr; },
        ^(int v) { hdr_apply(v); settings_put(@"DM_AUTO_HDR", v ? [NSString stringWithFormat:@"%d", v] : nil); });
    row(@"Display", @"MetalFX upscaling", onoff, ^int { return mtl_upscale_get(); },
        ^(int v) { settings_put(@"DM_PRESENT_UPSCALE", mtl_upscale_set(v) ? nil : @"off"); });
    static int hud = -1; if (hud < 0) hud = getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"));   // Metal turns its HUD on as the process starts only
    DmMenuRow *hr = row(@"Display", @"Performance overlay", onoff, ^int { return hud; }, ^(int v) { hud = v; settings_put(@"DM_METAL_HUD", v ? @"1" : nil); });
    hr.restart = 1; hr.initial = getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"));
    DmMenuRow *op = row(@"Display", @"Console mode", @[@"Handheld", @"Docked"], ^int { return g_restart_opmode; },
        ^(int v) { g_restart_opmode = v; settings_put(@"DM_OPMODE", v ? @"1" : @"0"); });
    op.restart = 1; op.initial = g_restart_opmode = dm_opmode() ? 1 : 0;
    row(@"Controls", @"Motion controls (gyro)", onoff, ^int { return g_gyro_state != 0; }, ^(int v) {
        if (g_gyro_state < 0) gyro_init();
        g_gyro_state = v;
        if (!v) { for (int p = 0; p < DM_PLAYERS; p++) dm_pad_motion_gone(p); }
        else { for (GCController *c in GCController.controllers) motion_on(c); if (!g_hid) pro_hid_start(); }
        settings_put(@"DM_GYRO", v ? nil : @"0"); });
    menu_game_settings(@"Game");
    abxy_init();
    row(@"Controls", @"A B X Y buttons", @[@"Automatic", @"By label", @"By position"], ^int { return g_abxy < 0 ? 0 : g_abxy ? 1 : 2; }, ^(int v) {
        g_abxy = v == 0 ? -1 : v == 1 ? 1 : 0;
        settings_put(@"DM_PAD_ABXY", v == 0 ? nil : v == 1 ? @"label" : @"position"); });
    menu_game_settings(@"Controls"); menu_game_settings(@"Performance");
    for (NSString *m in g_mods_all) {
        DmMenuRow *r = row(@"Mods", mod_label(m), onoff, ^int { return ![g_mods_off containsObject:m]; }, ^(int v) {
            if (v) [g_mods_off removeObject:m]; else [g_mods_off addObject:m];
            NSString *list = [g_mods_off.array componentsJoinedByString:@"|"];
            settings_put(@"DM_MODS_OFF", list.length ? [NSString stringWithFormat:@"\"%@\"", list] : nil); });
        r.restart = 1; r.initial = ![g_mods_off containsObject:m];
    }
    DmMenuRow *rz = row(@"", @"Resume game", nil, nil, nil); rz.act = ^{ menu_leave(); };
    DmMenuRow *q = row(@"", @"Quit game", nil, nil, nil); q.act = ^{ [NSApp terminate:nil]; };
}
static NSTextField *menu_label(NSString *s, CGFloat size, NSFontWeight w, NSColor *c, NSTextAlignment al) {
    NSTextField *t = [NSTextField labelWithString:s]; t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c; t.alignment = al; return t;
}
static void menu_draw(void) {
    if (!g_menu) return;
    for (NSView *v in [g_menu.subviews copy]) [v removeFromSuperview];
    if (g_confirm) {
        const CGFloat W = 460, H = 230; NSArray *ans = @[@"Restart now", @"Apply at the next start", @"Discard changes"];
        NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(floor((g_menu.bounds.size.width - W) / 2), floor((g_menu.bounds.size.height - H) / 2), W, H)];
        box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        box.wantsLayer = YES; box.layer.backgroundColor = [NSColor colorWithWhite:0.11 alpha:0.98].CGColor; box.layer.cornerRadius = 14;
        NSTextField *t = menu_label(@"Apply changes?", 19, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentLeft); t.frame = NSMakeRect(22, H - 48, W - 44, 26); [box addSubview:t];
        NSTextField *m = menu_label(@"Some changes take effect when the game starts again. Progress not saved in the game is lost on a restart.", 12, NSFontWeightRegular, [NSColor colorWithWhite:0.75 alpha:1], NSTextAlignmentLeft);
        m.frame = NSMakeRect(22, H - 88, W - 44, 34); m.maximumNumberOfLines = 2; m.cell.wraps = YES; [box addSubview:m];
        for (int i = 0; i < 3; i++) {
            NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(12, H - 128 - 32 * i, W - 24, 28)]; line.wantsLayer = YES; line.layer.cornerRadius = 6;
            if (i == g_csel) line.layer.backgroundColor = [NSColor colorWithRed:0.18 green:0.42 blue:0.95 alpha:1].CGColor;
            NSTextField *l = menu_label(ans[i], 15, NSFontWeightRegular, NSColor.whiteColor, NSTextAlignmentLeft); l.frame = NSMakeRect(12, 4, W - 60, 20); [line addSubview:l]; [box addSubview:line];
        }
        [g_menu addSubview:box]; return;
    }
    const CGFloat W = 520, rh = 30, pad = 22; int pending = menu_pending();
    NSMutableArray<NSView *> *lines = [NSMutableArray new]; NSString *sec = nil; CGFloat h = 0;
    NSMutableArray<NSNumber *> *ys = [NSMutableArray new]; CGFloat sel_y = 0; static CGFloat scroll;
    for (NSUInteger i = 0; i < g_rows.count; i++) {
        DmMenuRow *r = g_rows[i];
        if (!menu_shows(r)) continue;
        if (!r.section.length && !sec) { sec = @""; h += 14; }   // the gap before Restart / Resume / Quit
        NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(10, 0, W - 20, rh)]; line.wantsLayer = YES; line.layer.cornerRadius = 6;
        int dim = 0;
        if ((int)i == g_sel) line.layer.backgroundColor = [NSColor colorWithRed:0.18 green:0.42 blue:0.95 alpha:1].CGColor;
        NSColor *fg = dim ? [NSColor colorWithWhite:0.45 alpha:1] : NSColor.whiteColor;
        NSString *title = r.restart ? [r.title stringByAppendingString:@"  ↻"] : r.title;
        NSTextField *tl = menu_label(title, 15, NSFontWeightRegular, fg, NSTextAlignmentLeft); tl.frame = NSMakeRect(12, 5, W - 220, 20); [line addSubview:tl];
        if (r.choices) {
            int v = r.get(); NSString *val = v >= 0 && v < (int)r.choices.count ? r.choices[v] : @"?";
            NSTextField *vl = menu_label([NSString stringWithFormat:@"‹ %@ ›", val], 15, NSFontWeightMedium, fg, NSTextAlignmentRight); vl.frame = NSMakeRect(W - 220, 5, 186, 20); [line addSubview:vl];
        }
        if ((int)i == g_sel) sel_y = h;
        [lines addObject:line]; [ys addObject:@(h)]; h += rh;
    }
    NSTextField *head = menu_label(@DM_GAME_NAME, 20, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentLeft);
    NSTextField *foot = menu_label(pending ? @"↻ changed: you choose when to restart as you close the menu" : @"↻ needs a restart  ·  L / R tabs  ·  Esc or Home closes",
                                   12, NSFontWeightRegular, [NSColor colorWithWhite:pending ? 0.85 : 0.55 alpha:1], NSTextAlignmentLeft);
    CGFloat H = h + 72 + 40 + 2 * pad, avail = g_menu.bounds.size.height - 40, view = h;
    if (H > avail && avail > 200) {   // taller than the window: the lines scroll so the chosen one stays in view
        view = avail - (72 + 40 + 2 * pad); H = avail;
        if (sel_y < scroll) scroll = sel_y - 24; if (sel_y + rh > scroll + view) scroll = sel_y + rh - view + 8;
        scroll = fmax(0, fmin(scroll, h - view));
    } else scroll = 0;
    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(floor((g_menu.bounds.size.width - W) / 2), floor((g_menu.bounds.size.height - H) / 2), W, H)];
    panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    panel.wantsLayer = YES; panel.layer.backgroundColor = [NSColor colorWithWhite:0.11 alpha:0.97].CGColor; panel.layer.cornerRadius = 14; panel.layer.masksToBounds = YES;
    head.frame = NSMakeRect(pad, H - pad - 28, W - 2 * pad, 28); [panel addSubview:head];
    NSArray<NSString *> *tabs = menu_tabs(); CGFloat tx = pad;   // the tab bar, right of the title: L / R (Q / E) switch
    NSTextField *hint = menu_label(@"L", 12, NSFontWeightBold, [NSColor colorWithWhite:0.5 alpha:1], NSTextAlignmentLeft); hint.frame = NSMakeRect(tx, H - pad - 52, 14, 18); [panel addSubview:hint]; tx += 18;
    for (int i = 0; i < (int)tabs.count; i++) {
        NSTextField *t = menu_label(tabs[i], 13, i == g_tab ? NSFontWeightSemibold : NSFontWeightRegular, i == g_tab ? NSColor.whiteColor : [NSColor colorWithWhite:0.55 alpha:1], NSTextAlignmentCenter);
        CGFloat tw = ceil(t.intrinsicContentSize.width) + 16; t.frame = NSMakeRect(tx, H - pad - 52, tw, 18);
        if (i == g_tab) { NSView *u = [[NSView alloc] initWithFrame:NSMakeRect(tx + 6, H - pad - 55, tw - 12, 2)]; u.wantsLayer = YES; u.layer.backgroundColor = [NSColor colorWithRed:0.18 green:0.42 blue:0.95 alpha:1].CGColor; [panel addSubview:u]; }
        [panel addSubview:t]; tx += tw;
    }
    NSTextField *hint2 = menu_label(@"R", 12, NSFontWeightBold, [NSColor colorWithWhite:0.5 alpha:1], NSTextAlignmentLeft); hint2.frame = NSMakeRect(tx + 4, H - pad - 52, 14, 18); [panel addSubview:hint2];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSView *v = lines[i]; NSRect f = v.frame; CGFloat y = ys[i].doubleValue - scroll;
        if (y < 0 || y + f.size.height > view) continue;   // scrolled out of the panel
        f.origin.y = H - pad - 72 - y - f.size.height; v.frame = f; [panel addSubview:v];
    }
    foot.frame = NSMakeRect(pad, pad - 4, W - 2 * pad, 18); [panel addSubview:foot];
    [g_menu addSubview:panel];
}
static void menu_move(int d) {   // the next line with a value or an action
    if (!g_rows.count) return;
    for (int k = 0; k < (int)g_rows.count; k++) { g_sel = (g_sel + d + (int)g_rows.count) % (int)g_rows.count; if ((g_rows[g_sel].choices || g_rows[g_sel].act) && menu_shows(g_rows[g_sel])) break; }
    menu_draw();
}
static void menu_tab(int d) {   // the next / previous tab, on its first line
    int n = (int)menu_tabs().count; if (n < 2) return;
    g_tab = ((g_tab + d) % n + n) % n;
    for (g_sel = 0; g_sel < (int)g_rows.count && !(menu_shows(g_rows[g_sel]) && g_rows[g_sel].section.length && (g_rows[g_sel].choices || g_rows[g_sel].act)); g_sel++) ;
    if (g_sel >= (int)g_rows.count) g_sel = 0;
    menu_draw();
}
static void menu_change(int d) {   // d: +1 / -1 a value, 0 = A / Return (the next value, or the line's action)
    DmMenuRow *r = g_rows[g_sel];
    if (r.act) { if (d == 0) r.act(); return; }
    int n = (int)r.choices.count, v = r.get(); r.set(((v + (d < 0 ? -1 : 1)) % n + n) % n);
    menu_draw();
}
static void menu_open(void) {
    if (g_menu_open || !g_win) return;
    g_btn = 0; g_w = g_a = g_s = g_d = 0; push();   // nothing the game was given stays pressed
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
    for (int p = 0; p < DM_PLAYERS; p++) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    g_menu_open = 1; menu_build();
    if (g_tab >= (int)menu_tabs().count) g_tab = 0;
    if (g_sel >= (int)g_rows.count || !(g_rows[g_sel].choices || g_rows[g_sel].act) || !menu_shows(g_rows[g_sel])) { g_sel = 0; if (!g_rows[0].choices || !menu_shows(g_rows[0])) menu_move(1); }
    NSView *cv = g_win.contentView;
    g_menu = [[NSView alloc] initWithFrame:cv.bounds]; g_menu.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_menu.wantsLayer = YES; g_menu.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.45].CGColor;
    [cv addSubview:g_menu]; menu_draw();
    dm_focus_set(2); LOG("in-game menu: open");
}
static void menu_close(void) {
    if (!g_menu_open) return;
    g_menu_open = 0; g_confirm = 0; g_menu_swallow = 1; [g_menu removeFromSuperview]; g_menu = nil;
    if (g_win.isKeyWindow) { dm_focus_set(1); input_resume(); }
    LOG("in-game menu: closed");
}
static void menu_toggle(void) { if (g_menu_open) menu_leave(); else menu_open(); }
static void menu_home(const char *from) {   // Home from GameController or from the Pro Controller's reports, whichever comes first: one press toggles once
    static uint64_t last; uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int act = now - last > 300000000ull;   // the other path's report of the same press comes within a few ms; only a press that acts restarts the wait
    LOG("in-game menu: Home from %s (menu %s, game window %skey)%s", from, g_menu_open ? (g_confirm ? "asking" : "open") : "closed", g_win.isKeyWindow ? "" : "not ", act ? "" : ": same press, ignored");
    if (!act) return;
    last = now;
    if (g_confirm) { g_confirm = 0; menu_draw(); } else menu_toggle();
}
// A controller while the panel is up: each button and the stick act on their press (edge), not while held
static void menu_pad(uint64_t m, int32_t ly) {
    static uint64_t prev; static int prev_y;
    uint64_t dn = m & ~prev; prev = m;
    int y = ly > DM_STICK_MAX / 2 ? 1 : ly < -DM_STICK_MAX / 2 ? -1 : 0, ydn = y != prev_y ? y : 0; prev_y = y;
    if (g_confirm) {
        if ((dn & DM_BTN_UP) || ydn > 0) { g_csel = (g_csel + 2) % 3; menu_draw(); }
        if ((dn & DM_BTN_DOWN) || ydn < 0) { g_csel = (g_csel + 1) % 3; menu_draw(); }
        if (dn & DM_BTN_A) menu_answer(g_csel);
        if (dn & DM_BTN_B) { g_confirm = 0; menu_draw(); }   // back to the menu
        return;
    }
    if ((dn & DM_BTN_UP) || ydn > 0) menu_move(-1);
    if ((dn & DM_BTN_DOWN) || ydn < 0) menu_move(1);
    if (dn & DM_BTN_LEFT) menu_change(-1);
    if (dn & DM_BTN_RIGHT) menu_change(1);
    if (dn & DM_BTN_A) menu_change(0);
    if (dn & DM_BTN_B) menu_leave();
    if (dn & DM_BTN_L) menu_tab(-1);
    if (dn & DM_BTN_R) menu_tab(1);
}
static int menu_key(unsigned short c, int down) {   // 1 = the menu took the key
    if (c == 53) { if (down) { if (g_confirm) { g_confirm = 0; menu_draw(); } else menu_toggle(); } return 1; }   // Escape
    if (!g_menu_open) return 0;
    if (g_confirm) { if (down) switch (c) { case 126: g_csel = (g_csel + 2) % 3; menu_draw(); break; case 125: g_csel = (g_csel + 1) % 3; menu_draw(); break; case 36: case 49: case 76: menu_answer(g_csel); break; } return 1; }
    if (down) switch (c) { case 126: menu_move(-1); break; case 125: menu_move(1); break; case 123: menu_change(-1); break; case 124: menu_change(1); break; case 36: case 49: case 76: menu_change(0); break; case 12: menu_tab(-1); break; case 14: case 48: menu_tab(1); break; }
    return 1;
}
