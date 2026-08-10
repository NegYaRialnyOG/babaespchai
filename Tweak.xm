// Blockpost Mobile 2D Box ESP — NeqYaRialnyOG & Nyx
// Overlay Dear ImGui menu + il2cpp runtime enumeration of all characters.
//
// Rendering is on our OWN MTKView above the game (no hooking Unity's Metal or
// MSHookFunction -> safe on arm64e). We read game state through the exported
// il2cpp_* API and by calling a few resolved Unity methods directly.
//
// Resolved for BLOCKPOSTMOBILE build 260206 (metadata v31, arm64), image
// = UnityFramework. All addresses are RVAs relative to that image's header
// and are live-editable from the debug menu.

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <string.h>
#include <vector>
#include <mutex>
#include <string>

#include "imgui.h"
#include "imgui_impl_metal.h"

// ---------------------------------------------------------------------------
// Unity math
// ---------------------------------------------------------------------------
struct Vector3 { float x, y, z; };
struct Vector2 { float x, y; };

// il2cpp methods take a trailing hidden `const MethodInfo* method` argument.
// WorldToScreenPoint_Injected(this, Vector3* worldIn, Vector3* screenOut, method)
typedef void  (*W2S_Injected_t)(void* camera, Vector3* in, Vector3* out, void* method);
typedef void* (*Camera_get_main_t)(void* method);
typedef Vector3 (*Motor_get_TransientPosition_t)(void* motor, void* method);

static W2S_Injected_t                 W2S            = NULL;
static Camera_get_main_t              Camera_get_main= NULL;
static Motor_get_TransientPosition_t  Motor_get_TP   = NULL;

// ---------------------------------------------------------------------------
// il2cpp runtime API (exported by UnityFramework, resolved via dlsym)
// ---------------------------------------------------------------------------
typedef void* (*il2cpp_domain_get_t)();
typedef void* (*il2cpp_domain_assembly_open_t)(void*, const char*);
typedef void* (*il2cpp_assembly_get_image_t)(void*);
typedef void* (*il2cpp_class_from_name_t)(void*, const char*, const char*);
typedef void* (*il2cpp_class_get_field_from_name_t)(void*, const char*);
typedef void  (*il2cpp_field_static_get_value_t)(void*, void*);
typedef void* (*il2cpp_object_get_class_t)(void*);
typedef const char* (*il2cpp_class_get_name_t)(void*);
typedef void* (*il2cpp_thread_attach_t)(void*);

static il2cpp_domain_get_t                il2cpp_domain_get               = NULL;
static il2cpp_domain_assembly_open_t      il2cpp_domain_assembly_open     = NULL;
static il2cpp_assembly_get_image_t        il2cpp_assembly_get_image       = NULL;
static il2cpp_class_from_name_t           il2cpp_class_from_name          = NULL;
static il2cpp_class_get_field_from_name_t il2cpp_class_get_field_from_name= NULL;
static il2cpp_field_static_get_value_t    il2cpp_field_static_get_value   = NULL;
static il2cpp_object_get_class_t          il2cpp_object_get_class         = NULL;
static il2cpp_class_get_name_t            il2cpp_class_get_name           = NULL;
static il2cpp_thread_attach_t             il2cpp_thread_attach            = NULL;

// il2cpp API RVAs pulled from the UnityFramework symbol table (build 260206).
// dlsym can't see these (not in the export trie), so we call them by address.
#define RVA_il2cpp_domain_get            0x10afe4c
#define RVA_il2cpp_domain_assembly_open  0x10afe50
#define RVA_il2cpp_assembly_get_image    0x10af938
#define RVA_il2cpp_class_from_name       0x10af96c
#define RVA_il2cpp_class_get_field       0x10af98c
#define RVA_il2cpp_field_static_get      0x10b0088
#define RVA_il2cpp_object_get_class      0x10b027c
#define RVA_il2cpp_class_get_name        0x10af998
#define RVA_il2cpp_thread_attach         0x10b030c

// ---------------------------------------------------------------------------
// Live-tunable offsets / RVAs (all relative to g_image_base)
// ---------------------------------------------------------------------------
static char      g_image_name[64]   = "UnityFramework";
static uintptr_t g_rva_w2s          = 0x321bed8; // Camera.WorldToScreenPoint_Injected
static uintptr_t g_rva_getmain      = 0x321c3d4; // Camera.get_main
static uintptr_t g_rva_tp           = 0x17c93b8; // KinematicCharacterMotor.get_TransientPosition
static uintptr_t g_off_ctrl         = 0x1B0;     // motor -> CharacterController (ICharacterController)
static uintptr_t g_off_team         = 0x0;       // team int inside the controller object (TUNE ME)
static float     g_box_height       = 1.8f;      // world units, feet->head

static uintptr_t g_image_base       = 0;
static bool      g_esp_on           = true;
static bool      g_enemies_only     = false;     // needs a valid g_off_team first
static int       g_local_team       = -1;

// il2cpp handles (resolved once, refreshed on Apply)
static void* g_kcs_class = NULL;   // KinematicCharacterSystem
static void* g_motors_field = NULL;// static List<KinematicCharacterMotor> CharacterMotors

static std::string g_debug_text;

// ---------------------------------------------------------------------------
static uintptr_t image_header_for(const char* needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* n = _dyld_get_image_name(i);
        if (n && needle && strstr(n, needle))
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// Bind the il2cpp API by address (dlsym fails: symbols aren't in the export trie).
static void resolve_il2cpp_api(uintptr_t base) {
    #define BIND(fn) fn = (fn##_t)(base + RVA_##fn)
    BIND(il2cpp_domain_get);
    BIND(il2cpp_domain_assembly_open);
    BIND(il2cpp_assembly_get_image);
    BIND(il2cpp_class_from_name);
    il2cpp_class_get_field_from_name = (il2cpp_class_get_field_from_name_t)(base + RVA_il2cpp_class_get_field);
    il2cpp_field_static_get_value    = (il2cpp_field_static_get_value_t)   (base + RVA_il2cpp_field_static_get);
    il2cpp_object_get_class          = (il2cpp_object_get_class_t)         (base + RVA_il2cpp_object_get_class);
    il2cpp_class_get_name            = (il2cpp_class_get_name_t)           (base + RVA_il2cpp_class_get_name);
    il2cpp_thread_attach             = (il2cpp_thread_attach_t)            (base + RVA_il2cpp_thread_attach);
    #undef BIND
}

static void resolve_all() {
    g_image_base = image_header_for(g_image_name);
    if (!g_image_base) g_image_base = (uintptr_t)_dyld_get_image_header(0);

    resolve_il2cpp_api(g_image_base);

    W2S             = g_rva_w2s     ? (W2S_Injected_t)(g_image_base + g_rva_w2s)                : NULL;
    Camera_get_main = g_rva_getmain ? (Camera_get_main_t)(g_image_base + g_rva_getmain)         : NULL;
    Motor_get_TP    = g_rva_tp      ? (Motor_get_TransientPosition_t)(g_image_base + g_rva_tp)  : NULL;

    // resolve the static motor list via runtime API
    g_kcs_class = NULL; g_motors_field = NULL;
    if (il2cpp_domain_get && il2cpp_class_from_name) {
        void* dom = il2cpp_domain_get();
        void* asmb = il2cpp_domain_assembly_open ? il2cpp_domain_assembly_open(dom, "Assembly-CSharp") : NULL;
        void* img = asmb && il2cpp_assembly_get_image ? il2cpp_assembly_get_image(asmb) : NULL;
        if (img) {
            g_kcs_class = il2cpp_class_from_name(img, "KinematicCharacterController", "KinematicCharacterSystem");
            if (g_kcs_class && il2cpp_class_get_field_from_name)
                g_motors_field = il2cpp_class_get_field_from_name(g_kcs_class, "CharacterMotors");
        }
    }
}

// Snapshot the current motor list into a plain vector of pointers.
static int get_motors(std::vector<void*>& out) {
    out.clear();
    if (!g_motors_field || !il2cpp_field_static_get_value) return 0;
    void* listobj = NULL;
    il2cpp_field_static_get_value(g_motors_field, &listobj); // static -> obj ignored
    if (!listobj) return 0;
    // System.Collections.Generic.List<T>: _items @0x10 (T[]), _size @0x18 (int)
    void* items = *(void**)((char*)listobj + 0x10);
    int size    = *(int*) ((char*)listobj + 0x18);
    if (!items || size <= 0 || size > 512) return 0;
    // Il2CppArray payload begins at 0x20
    for (int i = 0; i < size; i++) {
        void* m = *(void**)((char*)items + 0x20 + (uintptr_t)i * 8);
        if (m) out.push_back(m);
    }
    return (int)out.size();
}

static int motor_team(void* motor) {
    if (!g_off_team) return -999;
    void* ctrl = *(void**)((char*)motor + g_off_ctrl);
    if (!ctrl) return -999;
    return *(int*)((char*)ctrl + g_off_team);
}

// ---------------------------------------------------------------------------
static std::string build_debug_dump() {
    char b[512];
    std::string o;
    snprintf(b, sizeof(b), "=== Blockpost ESP debug ===\nimage=%s base=0x%lx\n"
             "rva_w2s=0x%lx rva_getmain=0x%lx rva_tp=0x%lx off_ctrl=0x%lx off_team=0x%lx\n",
             g_image_name, (unsigned long)g_image_base,
             (unsigned long)g_rva_w2s, (unsigned long)g_rva_getmain, (unsigned long)g_rva_tp,
             (unsigned long)g_off_ctrl, (unsigned long)g_off_team);
    o += b;
    snprintf(b, sizeof(b), "il2cpp api: dom=%p class=%p field=%p\n",
             (void*)il2cpp_domain_get, g_kcs_class, g_motors_field); o += b;

    void* cam = Camera_get_main ? Camera_get_main(NULL) : NULL;
    snprintf(b, sizeof(b), "camera=%p\n", cam); o += b;

    std::vector<void*> motors; int n = get_motors(motors);
    snprintf(b, sizeof(b), "motors=%d\n", n); o += b;

    // dump up to 4 characters: controller class name + first 0x80 bytes so we
    // can locate the team field, plus position + screen projection
    for (int i = 0; i < n && i < 4; i++) {
        void* m = motors[i];
        void* ctrl = *(void**)((char*)m + g_off_ctrl);
        const char* cname = "?";
        if (ctrl && il2cpp_object_get_class && il2cpp_class_get_name) {
            void* c = il2cpp_object_get_class(ctrl);
            if (c) cname = il2cpp_class_get_name(c);
        }
        snprintf(b, sizeof(b), "-- motor[%d]=%p ctrl=%p (%s) --\n", i, m, ctrl, cname); o += b;

        if (Motor_get_TP) {
            Vector3 p = Motor_get_TP(m, NULL);
            snprintf(b, sizeof(b), "   pos=(%.2f,%.2f,%.2f)", p.x, p.y, p.z); o += b;
            if (cam && W2S) {
                Vector3 s; W2S(cam, &p, &s, NULL);
                snprintf(b, sizeof(b), "  screen=(%.1f,%.1f,z=%.2f)", s.x, s.y, s.z); o += b;
            }
            o += "\n";
        }
        if (ctrl) {
            unsigned char* bytes = (unsigned char*)ctrl;
            for (int row = 0; row < 0x80; row += 16) {
                snprintf(b, sizeof(b), "   +0x%02x: ", row); o += b;
                for (int c = 0; c < 16; c++) { snprintf(b, sizeof(b), "%02x ", bytes[row+c]); o += b; }
                snprintf(b, sizeof(b), " i0=%d f0=%.2f\n",
                         *(int*)(bytes+row), *(float*)(bytes+row)); o += b;
            }
        }
    }
    return o;
}

// ---------------------------------------------------------------------------
// Touch capture rects
// ---------------------------------------------------------------------------
static std::mutex          g_rects_mtx;
static std::vector<CGRect> g_capture_rects;

// ---------------------------------------------------------------------------
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

        if (ImGui::CollapsingHeader("Offsets (advanced)")) {
            ImGui::InputText("image", g_image_name, sizeof(g_image_name));
            ImGui::InputScalar("W2S",     ImGuiDataType_U64, &g_rva_w2s,     0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("get_main",ImGuiDataType_U64, &g_rva_getmain, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("TransPos",ImGuiDataType_U64, &g_rva_tp,      0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("ctrl off",ImGuiDataType_U64, &g_off_ctrl,    0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team off",ImGuiDataType_U64, &g_off_team,    0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            if (ImGui::Button("Apply / Re-resolve")) resolve_all();
        }

        ImGui::SeparatorText("State");
        void* cam = Camera_get_main ? Camera_get_main(NULL) : NULL;
        std::vector<void*> motors; int n = get_motors(motors);
        ImGui::Text("base=0x%lx  cam=%p", (unsigned long)g_image_base, cam);
        ImGui::Text("motors=%d  class=%p field=%p", n, g_kcs_class, g_motors_field);

        g_debug_text = build_debug_dump();
        if (ImGui::Button("Copy Debug")) {
            [UIPasteboard generalPasteboard].string =
                [NSString stringWithUTF8String:g_debug_text.c_str()];
        }
        ImGui::SameLine(); ImGui::TextDisabled("(-> paste to Nyx)");
    }
    ImGui::End();

    // ---- ESP boxes ----
    if (g_esp_on && W2S && Camera_get_main && Motor_get_TP) {
        void* cam = Camera_get_main(NULL);
        if (cam) {
            std::vector<void*> motors; get_motors(motors);
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            for (void* m : motors) {
                if (g_enemies_only && g_off_team && g_local_team >= 0) {
                    int t = motor_team(m);
                    if (t == g_local_team) continue;
                }
                Vector3 feet = Motor_get_TP(m, NULL);
                Vector3 head = feet; head.y += g_box_height;

                Vector3 sf, sh;
                W2S(cam, &feet, &sf, NULL);
                W2S(cam, &head, &sh, NULL);
                if (sf.z <= 0.0f) continue; // behind camera

                float feetY = screenH - sf.y;   // Unity origin bottom-left -> UIKit top-left
                float headY = screenH - sh.y;
                float cx = sf.x;
                if (cx <= 0 || cx >= screenW) continue;

                float h = feetY - headY; if (h < 6) h = 6;
                float w = h * 0.45f;
                ImVec2 tl(cx - w * 0.5f, headY), br(cx + w * 0.5f, feetY);
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

// Orientation-locked host: Blockpost runs landscape; stop the overlay flipping.
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
    // force landscape geometry (wider than tall) so we never inherit a
    // portrait frame if the app briefly reports one during launch
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
    // give il2cpp + the app UI time to come up before we resolve/overlay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        resolve_all();
        setup_overlay();
    });
}
