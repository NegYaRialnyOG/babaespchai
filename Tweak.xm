// Blockpost Mobile 2D Box ESP + Offset Explorer — NeqYaRialnyOG & Nyx
// Overlay Dear ImGui menu on our own MTKView (no Metal hook, no MSHookFunction).
//
// Targets are enumerated with UnityEngine.Object.FindObjectsOfType(Type) every
// frame (NO cached raw pointers — that was the ~6s use-after-free crash: a bot
// spawned/despawned, the cached pointer went stale, next frame we dereferenced
// freed memory). Everything is resolved by RVA against UnityFramework and is
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
typedef void*   (*Comp_get_tf_t)(void* component, void* method);           // Component.get_transform

static Cam_W2S_t      W2S             = NULL;
static Cam_get_main_t Camera_get_main = NULL;
static Tf_get_pos_t   Tf_get_pos      = NULL;
static FindObjs_t     FindObjs        = NULL;
static Comp_get_tf_t  Comp_get_tf     = NULL;

// il2cpp runtime API (bound by RVA — these aren't in the export trie)
typedef void* (*il2cpp_domain_get_t)();
typedef void* (*il2cpp_domain_assembly_open_t)(void*, const char*);
typedef void* (*il2cpp_assembly_get_image_t)(void*);
typedef void* (*il2cpp_class_from_name_t)(void*, const char*, const char*);
typedef void* (*il2cpp_class_get_type_t)(void*);
typedef void* (*il2cpp_type_get_object_t)(void*);
typedef void* (*il2cpp_object_get_class_t)(void*);
typedef const char* (*il2cpp_class_get_name_t)(void*);
typedef void* (*il2cpp_thread_attach_t)(void*);   // attach current thread to a domain
typedef void* (*il2cpp_thread_current_t)();        // NULL if thread not attached
typedef void* (*il2cpp_class_get_field_from_name_t)(void*, const char*);
typedef void  (*il2cpp_field_static_get_value_t)(void*, void*);

static il2cpp_domain_get_t           il2cpp_domain_get           = NULL;
static il2cpp_domain_assembly_open_t il2cpp_domain_assembly_open = NULL;
static il2cpp_assembly_get_image_t   il2cpp_assembly_get_image   = NULL;
static il2cpp_class_from_name_t      il2cpp_class_from_name      = NULL;
static il2cpp_class_get_type_t       il2cpp_class_get_type       = NULL;
static il2cpp_type_get_object_t      il2cpp_type_get_object      = NULL;
static il2cpp_object_get_class_t     il2cpp_object_get_class     = NULL;
static il2cpp_class_get_name_t       il2cpp_class_get_name       = NULL;
static il2cpp_thread_attach_t        il2cpp_thread_attach        = NULL;
static il2cpp_thread_current_t       il2cpp_thread_current       = NULL;
static il2cpp_class_get_field_from_name_t il2cpp_class_get_field_from_name = NULL;
static il2cpp_field_static_get_value_t    il2cpp_field_static_get_value    = NULL;

// RVAs (UnityFramework, build 260206) --------------------------------------
#define RVA_W2S              0x321c108   // Camera.WorldToScreenPoint(Vector3) -> Vector3
#define RVA_GET_MAIN         0x321c3d4   // Camera.get_main
#define RVA_TF_POS           0x325da48   // Transform.get_position -> Vector3
#define RVA_FINDOBJS         0x3258d94   // Object.FindObjectsOfType(Type) -> Object[]
#define RVA_GET_TRANSFORM    0x3252f14   // Component.get_transform -> Transform

#define RVA_il2cpp_domain_get            0x10afe4c
#define RVA_il2cpp_domain_assembly_open  0x10afe50
#define RVA_il2cpp_assembly_get_image    0x10af938
#define RVA_il2cpp_class_from_name       0x10af96c
#define RVA_il2cpp_class_get_type        0x10af9d4
#define RVA_il2cpp_type_get_object       0x10b0368
#define RVA_il2cpp_object_get_class      0x10b027c
#define RVA_il2cpp_class_get_name        0x10af998
#define RVA_il2cpp_thread_attach         0x10b030c
#define RVA_il2cpp_thread_current        0x10b0308
#define RVA_il2cpp_class_get_field_from_name 0x10af98c
#define RVA_il2cpp_field_static_get_value    0x10b0088

// Live-tunable target -------------------------------------------------------
static char      g_image_name[64] = "UnityFramework";
static char      g_target_ns[64]  = "";        // BotAI / Player have no namespace
static char      g_target_cls[64] = "BotAI";   // what to draw boxes on
static uintptr_t g_off_tf         = 0x20;      // Transform field inside target (BotAI._meshesRoot)
static uintptr_t g_off_team       = 0x0;       // team int inside target (0 = disabled)
static int       g_pos_mode       = 0;         // 0 = field @g_off_tf, 1 = Component.get_transform(self)
static float     g_head_off       = 0.2f;      // world units from anchor up to box TOP
static float     g_feet_off       = -1.9f;     // world units from anchor down to box BOTTOM
static float     g_width_mult     = 0.45f;     // box width as fraction of its height

// --- Blockpost-native player source (class PLH holds a static player array) --
// Cross-referenced from the Android source (PlayerData layout) against the BPM
// 260206 dump: PLH.PAODCKAEMPJ is a static DCEFKHDNOFM[] of all players.
static int  g_esp_src   = 1;            // 0 = FindObjectsOfType(class), 1 = PLH players
static char g_plh_cls[32]   = "PLH";
static char g_plh_field[32] = "PAODCKAEMPJ";   // static DCEFKHDNOFM[] players
static uintptr_t g_pd_pos    = 0x9c;    // DCEFKHDNOFM.Pos    (Vector3)
static uintptr_t g_pd_health = 0x50;    // DCEFKHDNOFM.health (int)
static uintptr_t g_pd_team   = 0x38;    // DCEFKHDNOFM.team   (int)
static uintptr_t g_pd_local  = 0x20;    // DCEFKHDNOFM.localplayer (bool)
static uintptr_t g_pd_zombie = 0x114;   // DCEFKHDNOFM.zombie (bool)
static void*     g_plh_klass = NULL;
static void*     g_plh_fld   = NULL;    // the static field handle for the array
static float     g_pd_head_off = 1.6f;  // Pos is at feet-ish -> box top above
static float     g_pd_feet_off = -0.1f; // small drop below Pos to feet

static uintptr_t g_image_base = 0;
static void*     g_dom        = NULL;   // il2cpp domain
static void*     g_asmb       = NULL;   // Assembly-CSharp assembly
static void*     g_img        = NULL;   // Assembly-CSharp image
static void*     g_type_obj   = NULL;   // cached System.Type for g_target_cls
static bool      g_resolved   = false;  // resolve_all completed at least once
static int       g_resolve_step = 0;    // last stage reached (for crash localization)

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

// A pointer that could be an il2cpp object: first qword is a plausible klass ptr.
static const char* obj_class_name(void* p) {
    if (!safe_ptr(p) || !il2cpp_class_get_name) return NULL;
    void* klass = *(void**)p;                 // il2cpp object header: +0x0 = Il2CppClass*
    if (!safe_ptr(klass)) return NULL;
    const char* n = il2cpp_class_get_name(klass);
    if (!n) return NULL;
    // sanity: printable, reasonable length
    for (int i = 0; i < 48; i++) {
        char c = n[i];
        if (c == 0) return i > 0 ? n : NULL;
        if (c < 0x20 || c > 0x7e) return NULL;
    }
    return NULL;
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

// Bind function pointers only (no game calls) — always safe.
static void bind_pointers() {
    g_image_base = image_header_for(g_image_name);
    if (!g_image_base) g_image_base = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t B = g_image_base;

    W2S             = (Cam_W2S_t)     (B + RVA_W2S);
    Camera_get_main = (Cam_get_main_t)(B + RVA_GET_MAIN);
    Tf_get_pos      = (Tf_get_pos_t)  (B + RVA_TF_POS);
    FindObjs        = (FindObjs_t)    (B + RVA_FINDOBJS);
    Comp_get_tf     = (Comp_get_tf_t) (B + RVA_GET_TRANSFORM);

    il2cpp_domain_get           = (il2cpp_domain_get_t)          (B + RVA_il2cpp_domain_get);
    il2cpp_domain_assembly_open = (il2cpp_domain_assembly_open_t)(B + RVA_il2cpp_domain_assembly_open);
    il2cpp_assembly_get_image   = (il2cpp_assembly_get_image_t)  (B + RVA_il2cpp_assembly_get_image);
    il2cpp_class_from_name      = (il2cpp_class_from_name_t)     (B + RVA_il2cpp_class_from_name);
    il2cpp_class_get_type       = (il2cpp_class_get_type_t)      (B + RVA_il2cpp_class_get_type);
    il2cpp_type_get_object      = (il2cpp_type_get_object_t)     (B + RVA_il2cpp_type_get_object);
    il2cpp_object_get_class     = (il2cpp_object_get_class_t)    (B + RVA_il2cpp_object_get_class);
    il2cpp_class_get_name       = (il2cpp_class_get_name_t)      (B + RVA_il2cpp_class_get_name);
    il2cpp_thread_attach        = (il2cpp_thread_attach_t)       (B + RVA_il2cpp_thread_attach);
    il2cpp_thread_current       = (il2cpp_thread_current_t)      (B + RVA_il2cpp_thread_current);
    il2cpp_class_get_field_from_name = (il2cpp_class_get_field_from_name_t)(B + RVA_il2cpp_class_get_field_from_name);
    il2cpp_field_static_get_value    = (il2cpp_field_static_get_value_t)   (B + RVA_il2cpp_field_static_get_value);
}

// Ensure the CURRENT thread (MTKView render thread) is attached to the il2cpp
// domain. Calling any reflection/allocating il2cpp function from an unattached
// thread deadlocks against the GC world-stop — that was the RESOLVE freeze.
static bool g_attached = false;
static bool ensure_attached() {
    if (g_attached) return true;
    if (!il2cpp_domain_get || !il2cpp_thread_attach) return false;
    if (il2cpp_thread_current && il2cpp_thread_current()) { g_attached = true; return true; }
    void* dom = il2cpp_domain_get();        // pure getter, safe on any thread
    if (!dom) return false;
    il2cpp_thread_attach(dom);
    g_attached = true;
    return true;
}

// Stepwise il2cpp resolve. g_resolve_step records how far we got so a crash
// pinpoints the offending call. NEVER auto-run at load — the domain/metadata
// may not be ready yet; call from the menu once you're in-game.
static void resolve_all() {
    bind_pointers();
    if (!ensure_attached()) { g_resolve_step = -1; return; }  // could not attach
    g_resolve_step = 1;
    g_dom = il2cpp_domain_get();
    g_resolve_step = 2;
    g_asmb = g_dom ? il2cpp_domain_assembly_open(g_dom, "Assembly-CSharp") : NULL;
    g_resolve_step = 3;
    g_img = g_asmb ? il2cpp_assembly_get_image(g_asmb) : NULL;
    g_resolve_step = 4;
    g_type_obj = g_img ? type_object_for(g_target_ns, g_target_cls) : NULL;

    // resolve PLH class + static player-array field
    g_plh_klass = NULL; g_plh_fld = NULL;
    if (g_img && il2cpp_class_from_name && il2cpp_class_get_field_from_name) {
        g_plh_klass = il2cpp_class_from_name(g_img, "", g_plh_cls);
        if (g_plh_klass) g_plh_fld = il2cpp_class_get_field_from_name(g_plh_klass, g_plh_field);
    }
    g_resolve_step = 5;
    g_resolved = true;
}

// Read the PLH static player array and collect element pointers (valid this
// frame only). Unity managed array: length @0x18, elements @0x20 (8B ptrs).
static int enum_plh_players(std::vector<void*>& out) {
    out.clear();
    if (!g_plh_fld || !il2cpp_field_static_get_value) return 0;
    void* arr = NULL;
    il2cpp_field_static_get_value(g_plh_fld, &arr);
    if (!safe_ptr(arr)) return 0;
    int cnt = *(int*)((char*)arr + 0x18);
    if (cnt <= 0 || cnt > 1024) return 0;
    for (int i = 0; i < cnt; i++) {
        void* o = *(void**)((char*)arr + 0x20 + (uintptr_t)i * 8);
        if (safe_ptr(o)) out.push_back(o);
    }
    return (int)out.size();
}

// Enumerate live instances of a Type object. Object[] layout: count @0x18,
// element pointers begin @0x20. Result pointers are valid ONLY this frame.
static int enum_type(void* type_obj, std::vector<void*>& out) {
    out.clear();
    if (!FindObjs || !type_obj) return 0;
    void* arr = FindObjs(type_obj, NULL);
    if (!safe_ptr(arr)) return 0;
    int cnt = *(int*)((char*)arr + 0x18);
    if (cnt <= 0 || cnt > 1024) return 0;
    for (int i = 0; i < cnt; i++) {
        void* o = *(void**)((char*)arr + 0x20 + (uintptr_t)i * 8);
        if (safe_ptr(o)) out.push_back(o);
    }
    return (int)out.size();
}

static int find_targets(std::vector<void*>& out) { return enum_type(g_type_obj, out); }

// Resolve an object's world position. mode 0: Transform field @g_off_tf.
// mode 1: Component.get_transform(self) — works for any MonoBehaviour (Player).
static bool obj_pos(void* o, Vector3& outp) {
    if (!safe_ptr(o) || !Tf_get_pos) return false;
    void* tf = NULL;
    if (g_pos_mode == 1) {
        if (!Comp_get_tf) return false;
        tf = Comp_get_tf(o, NULL);
    } else {
        tf = *(void**)((char*)o + g_off_tf);
    }
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
// Offset explorer: dump one instance's first 0x140 bytes, decoding each qword
// as int/float and — when it looks like an il2cpp object pointer — its class
// name. That reveals Transform fields (name "Transform"), and int slots in
// plausible team/health ranges. On-demand only (never per-frame).
static std::string scan_object(void* o) {
    char b[256]; std::string s;
    if (!safe_ptr(o)) return "scan: bad object\n";
    snprintf(b, sizeof(b), "scan obj=%p  (int/float/ptr per offset)\n", o); s += b;
    unsigned char* by = (unsigned char*)o;
    for (uintptr_t off = 0; off < 0x140; off += 8) {
        uint64_t q  = *(uint64_t*)(by + off);
        int32_t  iv = *(int32_t*)(by + off);
        float    fv = *(float*)(by + off);
        const char* cn = NULL;
        if (safe_ptr((void*)q)) cn = obj_class_name((void*)q);
        snprintf(b, sizeof(b), "+0x%03lx: i=%-11d f=%-14.3f ptr=0x%012llx%s%s\n",
                 (unsigned long)off, iv, fv, (unsigned long long)q,
                 cn ? "  -> " : "", cn ? cn : "");
        s += b;
    }
    return s;
}

static std::string build_debug_dump() {
    char b[512]; std::string o;
    if (!g_resolved) return "not resolved yet — tap RESOLVE il2cpp first\n";
    snprintf(b, sizeof(b), "=== Blockpost ESP debug ===\nimage=%s base=0x%lx\n"
             "target=%s.%s off_tf=0x%lx off_team=0x%lx pos_mode=%d\n",
             g_image_name, (unsigned long)g_image_base,
             g_target_ns, g_target_cls, (unsigned long)g_off_tf,
             (unsigned long)g_off_team, g_pos_mode);
    o += b;
    snprintf(b, sizeof(b), "img=%p type_obj=%p cam=%p\n",
             g_img, g_type_obj, Camera_get_main ? Camera_get_main(NULL) : NULL); o += b;

    // probe likely classes so we see which one actually has instances
    struct { const char* ns; const char* n; } cand[] = {
        {"", "Player"}, {"", "BotAI"}, {"", "BotSpawner"},
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

    // PLH native players
    snprintf(b, sizeof(b), "-- PLH klass=%p fld=%p --\n", g_plh_klass, g_plh_fld); o += b;
    std::vector<void*> pl; int pn = enum_plh_players(pl);
    snprintf(b, sizeof(b), "PLH players=%d\n", pn); o += b;
    for (int i = 0; i < pn && i < 6; i++) {
        void* pd = pl[i];
        int   id  = *(int*)((char*)pd + 0x10);
        bool  loc = *(bool*)((char*)pd + g_pd_local);
        int   tm  = *(int*)((char*)pd + g_pd_team);
        int   hp  = *(int*)((char*)pd + g_pd_health);
        Vector3 p = *(Vector3*)((char*)pd + g_pd_pos);
        snprintf(b, sizeof(b), " P[%d]=%p id=%d local=%d team=%d hp=%d pos=(%.1f,%.1f,%.1f)",
                 i, pd, id, loc, tm, hp, p.x, p.y, p.z); o += b;
        if (cam && W2S) { Vector3 s = W2S(cam, p, NULL);
            snprintf(b, sizeof(b), " scr=(%.0f,%.0f,z=%.1f)", s.x, s.y, s.z); o += b; }
        o += "\n";
        if (i == 0) o += scan_object(pd);
    }

    std::vector<void*> t; int n = find_targets(t);
    snprintf(b, sizeof(b), "-- target '%s' instances=%d --\n", g_target_cls, n); o += b;

    for (int i = 0; i < n && i < 4; i++) {
        void* obj = t[i];
        const char* cname = "?";
        if (g_dbg_names) { const char* c = obj_class_name(obj); if (c) cname = c; }
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
        if (i == 0) o += scan_object(obj);   // full offset scan of first instance
    }
    return o;
}

// ---------------------------------------------------------------------------
static std::mutex          g_rects_mtx;
static std::vector<CGRect> g_capture_rects;

static void render_frame(float screenW, float screenH) {
    std::vector<CGRect> rects;

    ImGui::SetNextWindowSize(ImVec2(300, 0), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(30, 40), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSizeConstraints(ImVec2(240, 0), ImVec2(380, 9999));
    ImGui::Begin("Blockpost ESP");
    {
        ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
        rects.push_back(CGRectMake(wp.x, wp.y, ws.x, ws.y));

        ImGui::Checkbox("ESP", &g_esp_on); ImGui::SameLine();
        ImGui::Checkbox("Enemies only", &g_enemies_only);
        ImGui::RadioButton("PLH players (real)", &g_esp_src, 1); ImGui::SameLine();
        ImGui::RadioButton("FindObjectsOfType", &g_esp_src, 0);
        ImGui::InputInt("Local team", &g_local_team);
        if (g_esp_src == 1) {
            ImGui::SliderFloat("Box top",   &g_pd_head_off, -1.0f, 3.0f);
            ImGui::SliderFloat("Box bottom",&g_pd_feet_off, -3.0f, 1.0f);
        } else {
            ImGui::SliderFloat("Box top",   &g_head_off, -3.0f, 3.0f);
            ImGui::SliderFloat("Box bottom",&g_feet_off, -3.0f, 3.0f);
        }
        ImGui::SliderFloat("Box width", &g_width_mult, 0.1f, 1.0f);

        if (ImGui::CollapsingHeader("Target / offsets (advanced)")) {
            ImGui::InputText("image", g_image_name, sizeof(g_image_name));
            ImGui::InputText("namespace", g_target_ns, sizeof(g_target_ns));
            ImGui::InputText("class", g_target_cls, sizeof(g_target_cls));
            ImGui::RadioButton("pos: field", &g_pos_mode, 0); ImGui::SameLine();
            ImGui::RadioButton("pos: get_transform()", &g_pos_mode, 1);
            ImGui::InputScalar("tf off",   ImGuiDataType_U64, &g_off_tf,   0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team off", ImGuiDataType_U64, &g_off_team, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            if (ImGui::Button("Apply / Re-resolve")) resolve_all();
            ImGui::SameLine();
            if (ImGui::Button("Target = Player")) {
                strcpy(g_target_cls, "Player"); g_target_ns[0] = 0;
                g_pos_mode = 1;               // Player: position via get_transform()
                resolve_all();
            }
            ImGui::SameLine();
            if (ImGui::Button("Target = BotAI")) {
                strcpy(g_target_cls, "BotAI"); g_target_ns[0] = 0;
                g_pos_mode = 0; g_off_tf = 0x20;
                resolve_all();
            }
        }

        ImGui::SeparatorText("State");
        if (ImGui::Button("RESOLVE il2cpp (tap in-game)")) resolve_all();
        ImGui::Text("resolved=%d step=%d attached=%d", g_resolved ? 1 : 0, g_resolve_step, g_attached ? 1 : 0);
        ImGui::Text("base=0x%lx", (unsigned long)g_image_base);
        ImGui::Text("dom=%p asmb=%p", g_dom, g_asmb);
        ImGui::Text("img=%p type_obj=%p", g_img, g_type_obj);
        ImGui::Text("PLH klass=%p fld=%p", g_plh_klass, g_plh_fld);
        if (g_resolved) {
            std::vector<void*> v; int pc = enum_plh_players(v);
            ImGui::Text("PLH players now=%d", pc);
        }
        ImGui::Text("last scan=%d", g_scan_count);

        if (ImGui::CollapsingHeader("PlayerData offsets")) {
            ImGui::InputScalar("Pos",    ImGuiDataType_U64, &g_pd_pos,    0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("health", ImGuiDataType_U64, &g_pd_health, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team",   ImGuiDataType_U64, &g_pd_team,   0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("local",  ImGuiDataType_U64, &g_pd_local,  0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
        }

        ImGui::SeparatorText("Self-test / offset explorer");
        if (ImGui::Button("1. Scan count")) { std::vector<void*> v; g_scan_count = find_targets(v); }
        ImGui::Checkbox("2. class names", &g_dbg_names);
        ImGui::Checkbox("3. positions", &g_dbg_pos);
        ImGui::Checkbox("4. project (W2S)", &g_dbg_w2s);

        if (ImGui::Button("Copy Debug (probe + scan)")) {
            g_debug_text = build_debug_dump();
            [UIPasteboard generalPasteboard].string =
                [NSString stringWithUTF8String:g_debug_text.c_str()];
        }
        ImGui::SameLine(); ImGui::TextDisabled("(-> paste to Nyx)");
    }
    ImGui::End();

    // ESP: enumerate FRESH this frame and use immediately (no stale cache).
    // Gated behind g_resolved so we never touch the runtime before it's ready.
    if (g_esp_on && g_resolved && ensure_attached() && W2S && Camera_get_main) {
        std::vector<void*> targets;
        bool plh = (g_esp_src == 1);
        if (plh) enum_plh_players(targets);
        else     find_targets(targets);
        void* cam = Camera_get_main(NULL);
        if (cam) {
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            for (void* obj : targets) {
                Vector3 anchor; float headoff, feetoff;
                if (plh) {
                    // real players: direct fields, no Transform needed
                    if (*(bool*)((char*)obj + g_pd_local)) continue;      // skip self
                    int hp = *(int*)((char*)obj + g_pd_health);
                    if (hp <= 0) continue;                                 // dead/respawning
                    if (g_enemies_only && g_local_team >= 0) {
                        int tm = *(int*)((char*)obj + g_pd_team);
                        if (tm == g_local_team) continue;
                    }
                    anchor = *(Vector3*)((char*)obj + g_pd_pos);
                    headoff = g_pd_head_off; feetoff = g_pd_feet_off;
                } else {
                    if (!Tf_get_pos || !g_type_obj) continue;
                    if (g_enemies_only && g_off_team && g_local_team >= 0) {
                        int tm = obj_team(obj);
                        if (tm == g_local_team) continue;
                    }
                    if (!obj_pos(obj, anchor)) continue;
                    headoff = g_head_off; feetoff = g_feet_off;
                }
                Vector3 top = anchor; top.y += headoff;
                Vector3 bot = anchor; bot.y += feetoff;
                Vector3 sTop = W2S(cam, top, NULL);
                Vector3 sBot = W2S(cam, bot, NULL);
                if (sBot.z <= 0.0f || sTop.z <= 0.0f) continue;   // behind camera
                float botY = screenH - sBot.y;      // Unity bottom-left -> UIKit top-left
                float topY = screenH - sTop.y;
                float cx   = (sTop.x + sBot.x) * 0.5f;
                if (cx <= 0 || cx >= screenW) continue;
                float h = botY - topY; if (h < 6) h = 6;
                float w = h * g_width_mult;
                ImVec2 tl(cx - w*0.5f, topY), br(cx + w*0.5f, botY);
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
    // Only bind pointers (safe) and raise the overlay. il2cpp resolve is NOT
    // done here — it's a manual button in-game, so the menu always appears and
    // a bad/early runtime call can't kill startup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        bind_pointers();
        setup_overlay();
    });
}
