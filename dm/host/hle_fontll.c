// nn::fontll::ScalableFontEngine used by one guest thread at a time (game profile font_engine_lock / DM_FONT_LOCK; off by default: the calls go straight to the SDK).
// The engine keeps its state per instance and in globals of its own (the FSS layer: the current font, scale and glyph work areas), with no lock: a game that uses it from two
// threads relies on the Switch never running them side by side. Tomodachi Life: Living the Dream's UpdateTextureCacheThread (priority 45, mask 0x7, on core 0) renders glyphs
// (SetFont, SetScale, AcquireGlyphmap: get_graymap / outline_graymap) while its Scene Prepare Thread (priority 50, core 0) measures text (SetFont, SetScale, GetAdvance) with the
// same engine. On core 0 the higher-priority renderer runs first and the measurer cannot start until it blocks; the host runs both pthreads at once, and about one boot in two crashed
// in FSS_get_advance (sdk+0x37cdfc / +0x37cd34 / +0x37cff4) on a null font the other thread had just switched out.
// A thread's first engine call takes the engine lock, and the thread keeps it until it next enters an SVC, a patched spin wait or a native HLE wait (dm_fontll_release, from
// thr_svc_enter and dm_thread_native_wait): a whole SetFont … GetAdvance or SetFont … ReleasesGlyph sequence runs as it would on one core, and no thread blocks while holding it.
// The game's calls are taken over (HLE_FORCE) and passed to the SDK's own functions with every argument register as it came (no argument here is a float or on the stack).
// LoadFont is taken over by hle_sdk16.c (the shared-font payload) and takes the lock there.
#include "hle.h"
#include <pthread.h>
#include <stdlib.h>

static pthread_mutex_t g_fe_mu;
static __thread int g_fe_held;
static int g_fe_on;
static pthread_once_t g_fe_once = PTHREAD_ONCE_INIT;
static void fe_init(void) {
    pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&g_fe_mu, &a);
    const char *e = getenv("DM_FONT_LOCK"); g_fe_on = e ? atoi(e) != 0 : DM_GAME_FONT_ENGINE_LOCK;
    if (g_fe_on) LOG("fontll: the scalable font engine is used by one thread at a time, each holding it until its next SVC or wait (game profile font_engine_lock)");
}
void dm_fontll_enter(void) {
    pthread_once(&g_fe_once, fe_init);
    if (!g_fe_on || g_fe_held) return;
    dm_host_lock(&g_fe_mu); g_fe_held = 1;
}
void dm_fontll_release(void) {
    if (!g_fe_held) return;
    g_fe_held = 0; pthread_mutex_unlock(&g_fe_mu);
}

typedef uint64_t (*fe_fn)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
#define FE(mangled, cname)                                                                                                         \
    static fe_fn cname##_orig;                                                                                                     \
    HLE_FORCE(mangled, "font engine call; with font_engine_lock one thread at a time (hle_fontll.c), the SDK's own function", uint64_t, cname, \
              uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {          \
        if (!cname##_orig && !(cname##_orig = (fe_fn)guest_sym(mangled))) die("%s not found in the guest", mangled);             \
        dm_fontll_enter();                                                                                                         \
        return cname##_orig(a0, a1, a2, a3, a4, a5, a6, a7);                                                                       \
    }
FE("_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj", h_fe_Initialize)
FE("_ZN2nn6fontll18ScalableFontEngine8FinalizeEv", h_fe_Finalize)
FE("_ZN2nn6fontll18ScalableFontEngine7SetFontEPc", h_fe_SetFont)
FE("_ZN2nn6fontll18ScalableFontEngine8SetScaleEiiii", h_fe_SetScale)
FE("_ZN2nn6fontll18ScalableFontEngine8SetFlagsENS1_5FlagsE", h_fe_SetFlags)
FE("_ZN2nn6fontll18ScalableFontEngine11SetAutoHintEb", h_fe_SetAutoHint)
FE("_ZN2nn6fontll18ScalableFontEngine13SetBoldWeightEi", h_fe_SetBoldWeight)
FE("_ZN2nn6fontll18ScalableFontEngine15SetOutlineWidthEt", h_fe_SetOutlineWidth)
FE("_ZN2nn6fontll18ScalableFontEngine8GetErrorEv", h_fe_GetError)
FE("_ZN2nn6fontll18ScalableFontEngine14GetFontMetricsEPNS0_7MetricsE", h_fe_GetFontMetrics)
FE("_ZN2nn6fontll18ScalableFontEngine10GetAdvanceEPsS2_PiS3_jt", h_fe_GetAdvance)
FE("_ZN2nn6fontll18ScalableFontEngine10GetKerningEPiS2_jj", h_fe_GetKerning)
FE("_ZN2nn6fontll18ScalableFontEngine15CheckGlyphExistEj", h_fe_CheckGlyphExist)
FE("_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt", h_fe_AcquireGlyphmap)
FE("_ZN2nn6fontll18ScalableFontEngine13ReleasesGlyphEPv", h_fe_ReleasesGlyph)
FE("_ZN2nn6fontll18ScalableFontEngine22GetPointerToWorkBufferEv", h_fe_GetWorkBuffer)
FE("_ZN2nn6fontll18ScalableFontEngine25InitializeOtfKerningTableEPFPvmmS2_ES2_b", h_fe_InitOtfKerning)
FE("_ZN2nn6fontll18ScalableFontEngine23FinalizeOtfKerningTableEPNS0_15OtfKerningTableEPFvPvS4_ES4_", h_fe_FinOtfKerning)
FE("_ZN2nn6fontll18ScalableFontEngine17AcquireOtfKerningEPKNS0_15OtfKerningTableEjjj", h_fe_OtfKerning)
FE("_ZN2nn6fontll18ScalableFontEngine22AcquireOtfKerningFirstEPKNS0_15OtfKerningTableEjj", h_fe_OtfKerningFirst)
FE("_ZN2nn6fontll18ScalableFontEngine21AcquireOtfKerningLastEPKNS0_15OtfKerningTableEjj", h_fe_OtfKerningLast)
