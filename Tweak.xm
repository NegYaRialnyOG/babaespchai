// Blockpost Mobile 2D Box ESP — NeqYaRialnyOG & Nyx
// Overlay Dear ImGui menu on our own MTKView (no Metal hook, no MSHookFunction).
//
// Enemies are enumerated with UnityEngine.Object.FindObjectsOfType(Type) so we
// don't depend on any single game-specific list (KCC motors only ever held the
// local player). Everything is resolved by RVA against UnityFramework and is
// live-tunable from the debug menu. Resolved for BLOCKPOSTMOBILE build 260206.

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <vector>
#include <mutex>
#include <string>

#include "imgui.h"
#include "imgui_impl_metal.h"

struct Vector3 { float x, y, z; };

// Resolved Unity methods (called by address; trailing arg = hidden MethodInfo*)
typedef Vector3 (*Cam_W2S_t)(void* camera, Vector3 pos, void* method);      // Camera.WorldToScreenPoint(Vector3)
typedef void*   (*Cam_get_main_t)(void* method);                            // Camera.get_main
typedef Vector3 (*Tf_get_pos_t)(void* transform, void* method);            // Transform.get_position
typedef void*   (*FindObjs_t)(void* type, void* method);                    // Object.FindObjectsOfType(Type)

static Cam_W2S_t      W2S             = NULL;
static Cam_get_main_t Camera_get_main = NULL;
static Tf_get_pos_t   Tf_get_pos      = NULL;
static FindObjs_t     FindObjs        = NULL;

// il2cpp runtime API (bound by RVA — these aren't in the export trie)
typedef void* (*il2cpp_domain_get_t)();
typedef void* (*il2cpp_domain_assembly_open_t)(void*, const char*);
typedef void* (*il2cpp_assembly_get_image_t)(void*);
typedef void* (*il2cpp_class_from_name_t)(void*, const char*, const char*);
typedef void* (*il2cpp_class_get_type_t)(void*);
typedef void* (*il2cpp_type_get_object_t)(void*);
typedef void* (*il2cpp_object_get_class_t)(void*);
typedef const char* (*il2cpp_class_get_name_t)(void*);

static il2cpp_domain_get_t           il2cpp_domain_get           = NULL;
static il2cpp_domain_assembly_open_t il2cpp_domain_assembly_open = NULL;
static il2cpp_assembly_get_image_t   il2cpp_assembly_get_image   = NULL;
static il2cpp_class_from_name_t      il2cpp_class_from_name      = NULL;
static il2cpp_class_get_type_t       il2cpp_class_get_type       = NULL;
static il2cpp_type_get_object_t      il2cpp_type_get_object      = NULL;
static il2cpp_object_get_class_t     il2cpp_object_get_class     = NULL;
static il2cpp_class_get_name_t       il2cpp_class_get_name       = NULL;

// RVAs (UnityFramework, build 260206) --------------------------------------
#define RVA_W2S              0x321c108   // Camera.WorldToScreenPoint(Vector3) -> Vector3
#define RVA_GET_MAIN         0x321c3d4   // Camera.get_main
#define RVA_TF_POS           0x325da48   // Transform.get_position -> Vector3
#define RVA_FINDOBJS         0x3258d94   // Object.FindObjectsOfType(Type) -> Object[]

#define RVA_il2cpp_domain_get            0x10afe4c
#define RVA_il2cpp_domain_assembly_open  0x10afe50
#define RVA_il2cpp_assembly_get_image    0x10af938
#define RVA_il2cpp_class_from_name       0x10af96c
#define RVA_il2cpp_class_get_type        0x10af9d4
#define RVA_il2cpp_type_get_object       0x10b0368
#define RVA_il2cpp_object_get_class      0x10b027c
#define RVA_il2cpp_class_get_name        0x10af998

// Live-tunable target -------------------------------------------------------
static char      g_image_name[64] = "UnityFramework";
static char      g_target_ns[64]  = "";       // BotAI has no namespace
static char      g_target_cls[64] = "BotAI";  // what to draw boxes on
static uintptr_t g_off_tf         = 0x20;     // Transform field inside target (BotAI._meshesRoot)
static uintptr_t g_off_team       = 0x28;     // team int inside target (BotAI, guess)
static float     g_box_height     = 1.8f;

static uintptr_t g_image_base = 0;
static void*     g_img        = NULL;   // Assembly-CSharp image
static void*     g_type_obj   = NULL;   // cached System.Type for g_target_cls

static bool g_esp_on       = false;
static bool g_enemies_only = false;
static int  g_local_team   = -1;

static bool g_dbg_names = false;
static bool g_dbg_pos   = false;
static bool g_dbg_w2s   = false;
static int  g_scan_count = -1;

static std::string g_debug_text;

// ---------------------------------------------------------------------------
static inline bool safe_ptr(const void* p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x10000 && (v & 0x7) == 0 && v < 0x0000100000000000ULL;
}

static uintptr_t image_header_for(const char* needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* n = _dyld_get_image_name(i);
        if (n && needle && strstr(n, needle)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static void* type_object_for(const char* ns, const char* name) {
    if (!g_img || !il2cpp_class_from_name || !il2cpp_class_get_type || !il2cpp_type_get_object) return NULL;
    void* k = il2cpp_class_from_name(g_img, ns, name);
    if (!k) return NULL;
    void* t = il2cpp_class_get_type(k);
    if (!t) return NULL;
    return il2cpp_type_get_object(t);
}

static void resolve_all() {
    g_image_base = image_header_for(g_image_name);
    if (!g_image_base) g_image_base = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t B = g_image_base;

    W2S             = (Cam_W2S_t)     (B + RVA_W2S);
    Camera_get_main = (Cam_get_main_t)(B + RVA_GET_MAIN);
    Tf_get_pos      = (Tf_get_pos_t)  (B + RVA_TF_POS);
    FindObjs        = (FindObjs_t)    (B + RVA_FINDOBJS);

    il2cpp_domain_get           = (il2cpp_domain_get_t)          (B + RVA_il2cpp_domain_get);
    il2cpp_domain_assembly_open = (il2cpp_domain_assembly_open_t)(B + RVA_il2cpp_domain_assembly_open);
    il2cpp_assembly_get_image   = (il2cpp_assembly_get_image_t)  (B + RVA_il2cpp_assembly_get_image);
    il2cpp_class_from_name      = (il2cpp_class_from_name_t)     (B + RVA_il2cpp_class_from_name);
    il2cpp_class_get_type       = (il2cpp_class_get_type_t)      (B + RVA_il2cpp_class_get_type);
    il2cpp_type_get_object      = (il2cpp_type_get_object_t)     (B + RVA_il2cpp_type_get_object);
    il2cpp_object_get_class     = (il2cpp_object_get_class_t)    (B + RVA_il2cpp_object_get_class);
    il2cpp_class_get_name       = (il2cpp_class_get_name_t)      (B + RVA_il2cpp_class_get_name);

    void* dom = il2cpp_domain_get();
    void* asmb = dom ? il2cpp_domain_assembly_open(dom, "Assembly-CSharp") : NULL;
    g_img = asmb ? il2cpp_assembly_get_image(asmb) : NULL;
    g_type_obj = type_object_for(g_target_ns, g_target_cls);
}

// Enumerate live instances of the target class. Object[] layout: count @0x18,
// element pointers begin @0x20.
static int find_targets(std::vector<void*>& out) {
    out.clear();
    if (!FindObjs || !g_type_obj) return 0;
    void* arr = FindObjs(g_type_obj, NULL);
    if (!safe_ptr(arr)) return 0;
    int cnt = *(int*)((char*)arr + 0x18);
    if (cnt <= 0 || cnt > 1024) return 0;
    for (int i = 0; i < cnt; i++) {
        void* o = *(void**)((char*)arr + 0x20 + (uintptr_t)i * 8);
        if (safe_ptr(o)) out.push_back(o);
    }
    return (int)out.size();
}

static bool obj_pos(void* o, Vector3& outp) {
    if (!safe_ptr(o) || !Tf_get_pos) return false;
    void* tf = *(void**)((char*)o + g_off_tf);
    if (!safe_ptr(tf)) return false;
    outp = Tf_get_pos(tf, NULL);
    return true;
}

static int obj_team(void* o) {
    if (!g_off_team || !safe_ptr(o)) return -999;
    return *(int*)((char*)o + g_off_team);
}

// probe a class name and return instance count (or negative error)
static int probe_count(const char* ns, const char* name, void** first) {
    void* t = type_object_for(ns, name);
    if (!t || !FindObjs) return -1;
    void* arr = FindObjs(t, NULL);
    if (!safe_ptr(arr)) return -2;
    int c = *(int*)((char*)arr + 0x18);
    if (c < 0 || c > 4096) return -3;
    if (first && c > 0) *first = *(void**)((char*)arr + 0x20);
    return c;
}

// ---------------------------------------------------------------------------
static std::string build_debug_dump() {
    char b[512]; std::string o;
    snprintf(b, sizeof(b), "=== Blockpost ESP debug ===\nimage=%s base=0x%lx\n"
             "target=%s.%s off_tf=0x%lx off_team=0x%lx\n",
             g_image_name, (unsigned long)g_image_base,
             g_target_ns, g_target_cls, (unsigned long)g_off_tf, (unsigned long)g_off_team);
    o += b;
    snprintf(b, sizeof(b), "img=%p type_obj=%p cam=%p\n",
             g_img, g_type_obj, Camera_get_main ? Camera_get_main(NULL) : NULL); o += b;

    // probe likely classes so we see which one actually has instances
    struct { const char* ns; const char* n; } cand[] = {
        {"", "BotAI"}, {"", "Player"},
        {"KinematicCharacterController.Examples", "ExampleCharacterController"},
        {"KinematicCharacterController", "KinematicCharacterMotor"},
    };
    o += "-- class population --\n";
    for (auto& c : cand) {
        void* first = NULL;
        int n = probe_count(c.ns, c.n, &first);
        snprintf(b, sizeof(b), "   %-28s count=%d first=%p\n", c.n, n, first); o += b;
    }

    void* cam = Camera_get_main ? Camera_get_main(NULL) : NULL;
    std::vector<void*> t; int n = find_targets(t);
    snprintf(b, sizeof(b), "-- target '%s' instances=%d --\n", g_target_cls, n); o += b;

    for (int i = 0; i < n && i < 4; i++) {
        void* obj = t[i];
        const char* cname = "?";
        if (g_dbg_names && il2cpp_object_get_class && il2cpp_class_get_name) {
            void* c = il2cpp_object_get_class(obj);
            if (safe_ptr(c)) cname = il2cpp_class_get_name(c);
        }
        snprintf(b, sizeof(b), "obj[%d]=%p (%s)\n", i, obj, cname); o += b;

        if (g_dbg_pos) {
            Vector3 p;
            if (obj_pos(obj, p)) {
                snprintf(b, sizeof(b), "   pos=(%.2f,%.2f,%.2f)", p.x, p.y, p.z); o += b;
                if (g_dbg_w2s && cam && W2S) {
                    Vector3 s = W2S(cam, p, NULL);
                    snprintf(b, sizeof(b), "  screen=(%.1f,%.1f,z=%.2f)", s.x, s.y, s.z); o += b;
                }
                o += "\n";
            }
        }
        if (safe_ptr(obj)) {
            unsigned char* by = (unsigned char*)obj;
            for (int row = 0; row < 0x60; row += 16) {
                snprintf(b, sizeof(b), "   +0x%02x: ", row); o += b;
                for (int c = 0; c < 16; c++) { snprintf(b, sizeof(b), "%02x ", by[row+c]); o += b; }
                snprintf(b, sizeof(b), " i=%d f=%.2f\n", *(int*)(by+row), *(float*)(by+row)); o += b;
            }
        }
    }
    return o;
}

// ---------------------------------------------------------------------------
static std::mutex          g_rects_mtx;
static std::vector<CGRect> g_capture_rects;

// cached enumeration for ESP (refreshed at low rate)
static std::vector<void*> g_cache;
static int                g_cache_frame = 0;

static void render_frame(float screenW, float screenH) {
    std::vector<CGRect> rects;

    ImGui::SetNextWindowSize(ImVec2(300, 0), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(30, 40), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSizeConstraints(ImVec2(240, 0), ImVec2(360, 9999));
    ImGui::Begin("Blockpost ESP");
    {
        ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
        rects.push_back(CGRectMake(wp.x, wp.y, ws.x, ws.y));

        ImGui::Checkbox("ESP", &g_esp_on); ImGui::SameLine();
        ImGui::Checkbox("Enemies only", &g_enemies_only);
        ImGui::InputInt("Local team", &g_local_team);
        ImGui::SliderFloat("Box height", &g_box_height, 0.5f, 3.0f);

        if (ImGui::CollapsingHeader("Target / offsets (advanced)")) {
            ImGui::InputText("image", g_image_name, sizeof(g_image_name));
            ImGui::InputText("namespace", g_target_ns, sizeof(g_target_ns));
            ImGui::InputText("class", g_target_cls, sizeof(g_target_cls));
            ImGui::InputScalar("tf off",   ImGuiDataType_U64, &g_off_tf,   0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team off", ImGuiDataType_U64, &g_off_team, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            if (ImGui::Button("Apply / Re-resolve")) resolve_all();
        }

        ImGui::SeparatorText("State");
        ImGui::Text("base=0x%lx img=%p", (unsigned long)g_image_base, g_img);
        ImGui::Text("type_obj=%p  last scan=%d", g_type_obj, g_scan_count);

        ImGui::SeparatorText("Self-test (enable one at a time)");
        if (ImGui::Button("1. Scan")) { std::vector<void*> v; g_scan_count = find_targets(v); }
        ImGui::Checkbox("2. class names", &g_dbg_names);
        ImGui::Checkbox("3. positions", &g_dbg_pos);
        ImGui::Checkbox("4. project (W2S)", &g_dbg_w2s);

        if (ImGui::Button("Copy Debug")) {
            g_debug_text = build_debug_dump();
            [UIPasteboard generalPasteboard].string =
                [NSString stringWithUTF8String:g_debug_text.c_str()];
        }
        ImGui::SameLine(); ImGui::TextDisabled("(-> paste to Nyx)");
    }
    ImGui::End();

    if (g_esp_on && W2S && Camera_get_main && Tf_get_pos && g_type_obj) {
        if (++g_cache_frame % 15 == 0 || g_cache.empty()) find_targets(g_cache);
        void* cam = Camera_get_main(NULL);
        if (cam) {
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            for (void* obj : g_cache) {
                if (g_enemies_only && g_off_team && g_local_team >= 0) {
                    int tm = obj_team(obj);
                    if (tm == g_local_team) continue;
                }
                Vector3 feet;
                if (!obj_pos(obj, feet)) continue;
                Vector3 head = feet; head.y += g_box_height;
                Vector3 sf = W2S(cam, feet, NULL);
                Vector3 sh = W2S(cam, head, NULL);
                if (sf.z <= 0.0f) continue;             // behind camera
                float feetY = screenH - sf.y;           // Unity bottom-left -> UIKit top-left
                float headY = screenH - sh.y;
                float cx = sf.x;
                if (cx <= 0 || cx >= screenW) continue;
                float h = feetY - headY; if (h < 6) h = 6;
                float w = h * 0.45f;
                ImVec2 tl(cx - w*0.5f, headY), br(cx + w*0.5f, feetY);
                dl->AddRect(ImVec2(tl.x-1,tl.y-1), ImVec2(br.x+1,br.y+1), IM_COL32(0,0,0,180), 0,0,3.0f);
                dl->AddRect(tl, br, IM_COL32(255,40,40,255), 0,0,1.5f);
            }
        }
    }

    { std::lock_guard<std::mutex> l(g_rects_mtx); g_capture_rects = rects; }
}

// ---------------------------------------------------------------------------
// Metal overlay
// ---------------------------------------------------------------------------
@interface ESPView : MTKView
@end
@implementation ESPView
- (void)feedTouch:(UITouch*)t down:(int)state {
    CGPoint p = [t locationInView:self];
    ImGuiIO& io = ImGui::GetIO();
    io.AddMousePosEvent(p.x, p.y);
    if (state >= 0) io.AddMouseButtonEvent(0, state == 1);
}
- (void)touchesBegan:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self feedTouch:t.anyObject down:1]; }
- (void)touchesMoved:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self feedTouch:t.anyObject down:-1]; }
- (void)touchesEnded:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self feedTouch:t.anyObject down:0]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self feedTouch:t.anyObject down:0]; }
@end

@interface ESPRenderer : NSObject <MTKViewDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@end
@implementation ESPRenderer
- (void)mtkView:(MTKView*)v drawableSizeWillChange:(CGSize)s {}
- (void)drawInMTKView:(MTKView*)view {
    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
    if (!rpd) { [cb commit]; return; }
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2(view.contentScaleFactor, view.contentScaleFactor);
    io.DeltaTime = 1.0f / 60.0f;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    render_frame(view.bounds.size.width, view.bounds.size.height);
    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    if (view.currentDrawable) [cb presentDrawable:view.currentDrawable];
    [cb commit];
}
@end

@interface ESPVC : UIViewController
@end
@implementation ESPVC
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

@interface ESPWindow : UIWindow
@end
@implementation ESPWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    std::lock_guard<std::mutex> l(g_rects_mtx);
    for (const CGRect& r : g_capture_rects)
        if (CGRectContainsPoint(r, point)) return [super hitTest:point withEvent:event];
    return nil;
}
@end

static ESPWindow*   g_window   = nil;
static ESPRenderer* g_renderer = nil;

static void setup_overlay() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    CGRect b = [UIScreen mainScreen].bounds;
    CGRect frame = (b.size.width < b.size.height)
                 ? CGRectMake(0, 0, b.size.height, b.size.width) : b;

    g_window = [[ESPWindow alloc] initWithFrame:frame];
    g_window.windowLevel = UIWindowLevelStatusBar + 1000;
    g_window.backgroundColor = [UIColor clearColor];
    g_window.opaque = NO;

    ESPVC* vc = [ESPVC new];
    g_window.rootViewController = vc;

    ESPView* mtk = [[ESPView alloc] initWithFrame:frame device:device];
    mtk.backgroundColor = [UIColor clearColor];
    mtk.opaque = NO; mtk.layer.opaque = NO;
    mtk.clearColor = MTLClearColorMake(0,0,0,0);
    mtk.framebufferOnly = NO;
    mtk.enableSetNeedsDisplay = NO; mtk.paused = NO;
    mtk.preferredFramesPerSecond = 60;
    mtk.multipleTouchEnabled = YES;
    vc.view = mtk;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.FontGlobalScale = 1.4f;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.3f);
    ImGui_ImplMetal_Init(device);

    g_renderer = [ESPRenderer new];
    g_renderer.queue = [device newCommandQueue];
    mtk.delegate = g_renderer;
    [g_window makeKeyAndVisible];
}

// ---------------------------------------------------------------------------
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        resolve_all();
        setup_overlay();
    });
}
