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
#include <cmath>

#include "imgui.h"
#include "imgui_impl_metal.h"

struct Vector3 { float x, y, z; };

// Resolved Unity methods (called by address; trailing arg = hidden MethodInfo*)
typedef Vector3 (*Cam_W2S_t)(void* camera, Vector3 pos, void* method);      // Camera.WorldToScreenPoint(Vector3)
typedef void*   (*Cam_get_main_t)(void* method);                            // Camera.get_main
typedef Vector3 (*Tf_get_pos_t)(void* transform, void* method);            // Transform.get_position
typedef void*   (*FindObjs_t)(void* type, void* method);                    // Object.FindObjectsOfType(Type)
typedef void*   (*Comp_get_tf_t)(void* component, void* method);           // Component.get_transform
typedef int32_t (*Cam_pixelDim_t)(void* camera, void* method);             // Camera.get_pixelWidth/Height

static Cam_W2S_t      W2S             = NULL;
static Cam_get_main_t Camera_get_main = NULL;
static Tf_get_pos_t   Tf_get_pos      = NULL;
static FindObjs_t     FindObjs        = NULL;
static Comp_get_tf_t  Comp_get_tf     = NULL;
static Cam_pixelDim_t Camera_get_pixelWidth  = NULL;
static Cam_pixelDim_t Camera_get_pixelHeight = NULL;

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

// RVAs (UnityFramework, build 260720) --------------------------------------
// Re-derived after the game updated past 260206 (which caused the domain_get
// hang / domain_assembly_open crash — those RVAs pointed into the WRONG,
// stale binary). Verified two ways: (1) Mach-O symbol table for il2cpp_*
// exports, (2) fresh Il2CppDumper run against the 260720 UnityFramework+metadata.
#define RVA_W2S              0x47b1be4   // Camera.WorldToScreenPoint(Vector3) -> Vector3
#define RVA_GET_MAIN         0x47b1eb0   // Camera.get_main
#define RVA_TF_POS           0x47f36f8   // Transform.get_position -> Vector3
#define RVA_FINDOBJS         0x47ee9b8   // Object.FindObjectsOfType(Type) -> Object[]
#define RVA_GET_TRANSFORM    0x47e8b58   // Component.get_transform -> Transform
#define RVA_GET_PIXEL_WIDTH  0x47b1658   // Camera.get_pixelWidth -> int
#define RVA_GET_PIXEL_HEIGHT 0x47b1698   // Camera.get_pixelHeight -> int

#define RVA_il2cpp_domain_get            0x25797f0
#define RVA_il2cpp_domain_assembly_open  0x25797f4
#define RVA_il2cpp_assembly_get_image    0x25792dc
#define RVA_il2cpp_class_from_name       0x2579310
#define RVA_il2cpp_class_get_type        0x2579378
#define RVA_il2cpp_type_get_object       0x2579d0c
#define RVA_il2cpp_object_get_class      0x2579c20
#define RVA_il2cpp_class_get_name        0x257933c
#define RVA_il2cpp_thread_attach         0x2579cb0
#define RVA_il2cpp_thread_current        0x2579cac
#define RVA_il2cpp_class_get_field_from_name 0x2579330
#define RVA_il2cpp_field_static_get_value    0x2579a2c

// Live-tunable target -------------------------------------------------------
static char      g_image_name[64] = "UnityFramework";
static char      g_target_ns[64]  = "";        // BotAI / Player have no namespace
static char      g_target_cls[64] = "BotAI";   // what to draw boxes on
static uintptr_t g_off_tf         = 0x20;      // Transform field inside target (BotAI._meshesRoot)
static uintptr_t g_off_team       = 0x0;       // team int inside target (0 = disabled)
// pos_mode 1 (Component.get_transform(self), the BotAI component's OWN root
// transform) is confirmed correct on-target; pos_mode 0 (_meshesRoot field)
// projects to some other anchor entirely (a decoration/effect socket, not
// the body) and was the source of the "floats above the character" bug.
static int       g_pos_mode       = 1;         // 0 = field @g_off_tf, 1 = Component.get_transform(self)
static float     g_head_off       = 0.2f;      // world units from anchor up to box TOP
static float     g_feet_off       = -1.9f;     // world units from anchor down to box BOTTOM
static float     g_width_mult     = 0.45f;     // box width as fraction of its height

// --- Blockpost-native player source (class PLH holds a static player array) --
// Cross-referenced from the Android source (PlayerData layout) against the BPM
// 260720 dump. Build 260720 inserted one extra string field at 0x20 vs 260206,
// shifting every field after it by +8; also PLH now exposes TWO static arrays
// (0x10 and 0x18) instead of one — 0x10 is the one in the same slot the old
// single-array build used, so that's the default. Class/field names are
// obfuscated per-build and WILL change again on the next game update — hence
// the live text inputs below instead of hardcoding forever.
// Default to FindObjectsOfType(BotAI) — confirmed correct on-target in a bots
// match. PLH mode is for real networked players; in a bots-only match its
// array slots are mostly stale/unused, which used to slip past the sanity
// check and draw garbage boxes nowhere near anyone. Switch to PLH manually
// once you're in a real player match.
static int  g_esp_src   = 0;            // 0 = FindObjectsOfType(class), 1 = PLH players
static char g_plh_cls[32]   = "PLH";
static char g_plh_field[32] = "PAFMAJGGFBD";   // auto-picked by resolve_all; this is just the last winner
// Every field PLH could plausibly hold the player array under, tried automatically.
static const char* g_plh_field_candidates[] = { "PAFMAJGGFBD", "AAHFKKPKJEP" };
static uintptr_t g_pd_pos    = 0xa4;    // PlayerData.Pos    (Vector3)
static uintptr_t g_pd_health = 0x58;    // PlayerData.health (int)
static uintptr_t g_pd_team   = 0x40;    // PlayerData.team   (int)
static uintptr_t g_pd_local  = 0x28;    // PlayerData.localplayer (bool)
static uintptr_t g_pd_zombie = 0x11c;   // PlayerData.zombie (bool)
static void*     g_plh_klass = NULL;
static void*     g_plh_fld   = NULL;    // the static field handle for the array
static int       g_plh_field_score = -1; // how many entries in the auto-picked field looked like real players
static float     g_pd_head_off = 1.6f;  // Pos is at feet-ish -> box top above
static float     g_pd_feet_off = -0.1f; // small drop below Pos to feet

// --- Real skeleton anchors, exactly like the Android source's Esp::Render ---
// PlayerData.po -> PlayerObject; PlayerObject.tr (0xF8) is a single base/legs
// Transform, PlayerObject.trhb (0x100) is a Transform[] of bones indexed by
// PlayerBones_t (head=3, chest=2, lowerChest=1, stomach=0, arms=4..6/10..12,
// legs=7..8/13..14). Verified byte-for-byte against the BPM 260720 dump — same
// offsets as the Android build, no shift (PlayerObject is a different class
// than PlayerData, so the +8 insertion there doesn't apply here). When these
// resolve, box top/bottom AND a full skeleton use real bone positions instead
// of a flat Pos field — this is what the source actually does.
static uintptr_t g_pd_po     = 0x30;    // PlayerData.po -> PlayerObject
static uintptr_t g_po_tr     = 0xf8;    // PlayerObject.tr  (Transform, base/legs)
static uintptr_t g_po_trhb   = 0x100;   // PlayerObject.trhb (Transform[], bones)
enum BoneIdx { BONE_STOMACH=0, BONE_LOWERCHEST=1, BONE_CHEST=2, BONE_HEAD=3,
               BONE_R_UPARM=4, BONE_R_LOARM=5, BONE_R_HAND=6, BONE_R_UPLEG=7, BONE_R_LOLEG=8,
               BONE_L_UPARM=10, BONE_L_LOARM=11, BONE_L_HAND=12, BONE_L_UPLEG=13, BONE_L_LOLEG=14 };
static bool      g_skeleton_on = false;

// --- Name / Health / Armor / Weapon (ports of Esp::Name/Health/Armor/Weapon
// from the source). All PLH-only, same as skeleton — these fields aren't
// exposed on BotAI. Offsets confirmed against the BPM 260720 dump exactly the
// way PlayerObject/PlayerData were: playername/armor/currwpn all shift by the
// same uniform +8 as the rest of PlayerData; the weapon-item chain
// (PlayerWeaponObject "it" @0x18, BaseItemInfo "codename" @0x18) is a
// SEPARATE class from PlayerData so it keeps the Android source's original,
// unshifted offsets.
static uintptr_t g_pd_name    = 0x18;   // PlayerData.playername (string_t*)
static uintptr_t g_pd_armor   = 0x5c;   // PlayerData.armor (int)
static uintptr_t g_pd_currwpn = 0x138;  // PlayerData.currwpn -> PlayerWeaponObject
static uintptr_t g_pwo_it     = 0x18;   // PlayerWeaponObject.it -> BaseItemInfo
static uintptr_t g_item_name  = 0x18;   // BaseItemInfo.codename (string_t*)
static bool      g_show_name       = false;
static bool      g_show_health_bar = false;
static bool      g_show_health_txt = false;
static bool      g_show_armor_bar  = false;
static bool      g_show_weapon     = false;

static uintptr_t g_image_base = 0;
static void*     g_dom        = NULL;   // il2cpp domain
static void*     g_asmb       = NULL;   // Assembly-CSharp assembly
static void*     g_img        = NULL;   // Assembly-CSharp image
static void*     g_type_obj   = NULL;   // cached System.Type for g_target_cls
static bool      g_resolved   = false;  // resolve_all completed at least once
static int       g_resolve_step = 0;    // last stage reached (for crash localization)
static int       g_prev_step  = -999;   // step persisted from a PREVIOUS run (survives crash)

// Persist the step we're ABOUT to attempt to disk, so if that call crashes the
// app, the number survives and we read it back on the next launch. The step
// with no matching "done" is the offending il2cpp call.
static void write_step(int s) {
    g_resolve_step = s;
    @autoreleasepool {
        NSString* p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/esp_step.txt"];
        [[NSString stringWithFormat:@"%d", s] writeToFile:p atomically:YES
                                                 encoding:NSUTF8StringEncoding error:nil];
    }
}
static int read_step() {
    @autoreleasepool {
        NSString* p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/esp_step.txt"];
        NSString* s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        return s ? s.intValue : -999;
    }
}

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

// Decode a managed (il2cpp) string using the standard, version-stable layout:
// Il2CppObject header (klass ptr + monitor, 16 bytes) + int32 length @0x10 +
// UTF-16LE chars starting @0x14. Good enough for player names/weapon
// codenames (ASCII/BMP) without needing the source's std::wstring_convert
// (deprecated, and we'd rather not carry the extra dependency for this).
static std::string read_il2cpp_string(void* strPtr) {
    if (!safe_ptr(strPtr)) return "";
    int32_t len = *(int32_t*)((char*)strPtr + 0x10);
    if (len <= 0 || len > 128) return "";
    const uint16_t* chars = (const uint16_t*)((char*)strPtr + 0x14);
    std::string out;
    out.reserve(len);
    for (int32_t i = 0; i < len; i++) {
        uint16_t c = chars[i];
        if (c == 0) break;
        if (c < 0x80) out.push_back((char)c);
        else out.push_back('?');   // non-ASCII: keep length sane, skip full UTF-8 encoding
    }
    return out;
}

// Draw text with a 1px black outline so it stays readable over any
// background — standard technique, substitutes for the source's custom
// embedded-font renderer which we don't carry.
static void draw_outlined_text(ImDrawList* dl, ImVec2 pos, ImU32 color, const char* text) {
    static const ImVec2 offs[4] = { {-1,0}, {1,0}, {0,-1}, {0,1} };
    for (auto& o : offs) dl->AddText(ImVec2(pos.x + o.x, pos.y + o.y), IM_COL32(0,0,0,255), text);
    dl->AddText(pos, color, text);
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
    Camera_get_pixelWidth  = (Cam_pixelDim_t)(B + RVA_GET_PIXEL_WIDTH);
    Camera_get_pixelHeight = (Cam_pixelDim_t)(B + RVA_GET_PIXEL_HEIGHT);

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
__attribute__((unused)) static bool ensure_attached() {
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
static char g_asm_name[48] = "Assembly-CSharp.dll";   // exactly like the source

// Resolve exactly like the Android source: NO il2cpp_domain_get (that's what
// hung at step 11), NO thread_attach. Just domain_assembly_open(NULL, name).
// Score a candidate static field: read it, count entries that look like a
// LIVE real PlayerData — alive (hp>0, not just "small int"), sane team, AND a
// finite/plausible world position. hp==0 or a default-zeroed struct passes a
// loose "small int" check trivially, which is exactly what made stale/unused
// array slots in a bots match masquerade as real players before. Returns -1
// if the field itself doesn't resolve or isn't a readable array.
static int score_plh_field(void* fld) {
    if (!fld || !il2cpp_field_static_get_value) return -1;
    void* arr = NULL;
    il2cpp_field_static_get_value(fld, &arr);
    if (!safe_ptr(arr)) return -1;
    int cnt = *(int*)((char*)arr + 0x18);
    if (cnt < 0 || cnt > 256) return -1;
    int good = 0;
    for (int i = 0; i < cnt; i++) {
        void* o = *(void**)((char*)arr + 0x20 + (uintptr_t)i * 8);
        if (!safe_ptr(o)) continue;
        int hp = *(int*)((char*)o + g_pd_health);
        int tm = *(int*)((char*)o + g_pd_team);
        if (hp <= 0 || hp > 1000) continue;         // must be alive, not a default/dead slot
        if (tm < -1 || tm > 16) continue;
        Vector3 p = *(Vector3*)((char*)o + g_pd_pos);
        bool finite = (p.x == p.x) && (p.y == p.y) && (p.z == p.z);  // reject NaN
        if (!finite) continue;
        if (fabsf(p.x) > 100000.0f || fabsf(p.y) > 100000.0f || fabsf(p.z) > 100000.0f) continue;
        good++;
    }
    return good;
}

// Real per-bone anchors for a PLH player, mirroring the source's
// PlayerSystem::getObject/getTransform/getTransforms + Esp::Render. Returns
// false (leaving outputs untouched) if this player's PlayerObject/bones
// aren't available — caller should fall back to the flat Pos-based box.
static bool get_bone_pos(void* pd, int boneIdx, Vector3& outPos) {
    if (!safe_ptr(pd) || !Tf_get_pos) return false;
    void* po = *(void**)((char*)pd + g_pd_po);
    if (!safe_ptr(po)) return false;
    void* trhbArr = *(void**)((char*)po + g_po_trhb);
    if (!safe_ptr(trhbArr)) return false;
    int cnt = *(int*)((char*)trhbArr + 0x18);
    if (boneIdx < 0 || boneIdx >= cnt) return false;
    void* bone = *(void**)((char*)trhbArr + 0x20 + (uintptr_t)boneIdx * 8);
    if (!safe_ptr(bone)) return false;
    outPos = Tf_get_pos(bone, NULL);
    return true;
}

// The "base" anchor (PlayerObject.tr) used for the legs/bottom of the box —
// distinct from any bone, this is the character's own root transform.
static bool get_base_pos(void* pd, Vector3& outPos) {
    if (!safe_ptr(pd) || !Tf_get_pos) return false;
    void* po = *(void**)((char*)pd + g_pd_po);
    if (!safe_ptr(po)) return false;
    void* tr = *(void**)((char*)po + g_po_tr);
    if (!safe_ptr(tr)) return false;
    outPos = Tf_get_pos(tr, NULL);
    return true;
}

// Resolve exactly like the Android source: NO il2cpp_domain_get (that hung),
// NO thread_attach. Then AUTO-PICK whichever candidate PLH field actually
// holds sane player data — no manual retyping needed when the game updates
// and obfuscated names shuffle. Only falls back to hand-editing the field
// name in the menu if every candidate scores 0 (rare: a brand new field
// layout, not just a renamed one).
static void resolve_all() {
    write_step(10); bind_pointers();
    write_step(11); g_asmb = il2cpp_domain_assembly_open ? il2cpp_domain_assembly_open(NULL, g_asm_name) : NULL;
    write_step(12); g_img  = (g_asmb && il2cpp_assembly_get_image) ? il2cpp_assembly_get_image(g_asmb) : NULL;
    write_step(13); g_plh_klass = (g_img && il2cpp_class_from_name) ? il2cpp_class_from_name(g_img, "", g_plh_cls) : NULL;

    write_step(14);
    void* best_fld = NULL; int best_score = -1; const char* best_name = NULL;
    if (g_plh_klass && il2cpp_class_get_field_from_name) {
        for (const char* cand : g_plh_field_candidates) {
            void* fld = il2cpp_class_get_field_from_name(g_plh_klass, cand);
            int sc = score_plh_field(fld);
            if (sc > best_score) { best_score = sc; best_fld = fld; best_name = cand; }
        }
        // last-resort: the name currently in the (possibly hand-edited) text box
        void* fld = il2cpp_class_get_field_from_name(g_plh_klass, g_plh_field);
        int sc = score_plh_field(fld);
        if (sc > best_score) { best_score = sc; best_fld = fld; best_name = g_plh_field; }
    }
    g_plh_fld = best_fld;
    if (best_name && best_name != g_plh_field) { strncpy(g_plh_field, best_name, sizeof(g_plh_field)-1); g_plh_field[sizeof(g_plh_field)-1]=0; }
    g_plh_field_score = best_score;

    write_step(15); g_type_obj = g_img ? type_object_for(g_target_ns, g_target_cls) : NULL;
    write_step(16); g_dom = NULL; g_resolved = true;
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

// ESP boxes are COMPUTED on the main thread (all il2cpp/game reads happen there)
// and only DRAWN on the MTKView render thread. Calling il2cpp from the render
// thread deadlocked against the GC / Metal locks — that was the RESOLVE freeze.
// health/armor default -1 = "no data" (BotAI mode never fills these).
struct Box {
    float x, y, w, h;
    int health = -1, armor = -1;
    std::string name, weapon;
};
static std::mutex        g_boxes_mtx;
static std::vector<Box>  g_boxes;

// Calibration markers: screen position of the FIRST target's raw anchor
// (zero offset) and the same anchor +1.0 world unit up. Drawn as dots in-game
// so a single screenshot gives exact pixel ground-truth for where the anchor
// sits relative to the character — no more guessing box top/bottom offsets.
struct CalibMarks { bool valid; float x0, y0, x1, y1; };
static std::mutex   g_calib_mtx;
static CalibMarks   g_calib = { false, 0, 0, 0, 0 };

// Skeleton line segments (PLH mode only — needs PlayerObject.trhb bones,
// which BotAI doesn't expose), computed on the main thread and drawn by the
// render thread same as boxes.
struct SkelSeg { float x1, y1, x2, y2; };
static std::mutex           g_skel_mtx;
static std::vector<SkelSeg> g_skel_segs;
static bool              g_want_resolve = false;   // button -> main thread does resolve_all
static bool              g_want_debug   = false;   // button -> main thread builds debug dump
static bool              g_want_replh   = false;   // button -> main thread re-resolves PLH class/field
static float             g_scrW = 0, g_scrH = 0;   // last display size from render thread
static int               g_plh_count = 0;          // players seen by last main pump

// Compute ESP boxes on the MAIN thread. Mirrors the old inline projection but
// writes results into g_boxes for the render thread to draw.
static void compute_boxes() {
    std::vector<Box> boxes;
    float screenW = g_scrW, screenH = g_scrH;
    bool calibDone = false;
    if (g_esp_on && g_resolved && W2S && Camera_get_main && screenW > 0) {
        std::vector<void*> targets;
        bool plh = (g_esp_src == 1);
        if (plh) enum_plh_players(targets); else find_targets(targets);
        void* cam = Camera_get_main(NULL);
        if (cam) {
            // Camera.WorldToScreenPoint returns coordinates in Unity's PIXEL
            // space (Camera.pixelWidth/pixelHeight — the real render-target
            // resolution, e.g. under Retina scaling or dynamic resolution),
            // NOT the UIKit POINT space our MTKView reports (view.bounds).
            // Treating them as the same space is why boxes only lined up
            // near one screen corner and drifted everywhere else — a scale
            // mismatch grows with distance from the origin. Rescale every
            // projected point into UI points before using it.
            float gameW = Camera_get_pixelWidth  ? (float)Camera_get_pixelWidth(cam, NULL)  : screenW;
            float gameH = Camera_get_pixelHeight ? (float)Camera_get_pixelHeight(cam, NULL) : screenH;
            if (gameW <= 0) gameW = screenW;
            if (gameH <= 0) gameH = screenH;
            const float sx = screenW / gameW;
            const float sy = screenH / gameH;
            auto toUI = [&](const Vector3& s, float& ux, float& uy) {
                ux = s.x * sx;
                uy = screenH - (s.y * sy);
            };

            // Two entries whose world anchors land within DEDUP_DIST of each
            // other are treated as the same character (this is what produced
            // the "doubled box" — some source lists can carry two live
            // pointers for one physical target, e.g. a base object plus a
            // hitbox/proxy) and only the first is kept.
            const float DEDUP_DIST2 = 0.3f * 0.3f;
            std::vector<Vector3> accepted;
            std::vector<SkelSeg> skelSegs;
            const float aspect = (screenH > 0) ? (screenW / screenH) : 1.7778f;
            for (void* obj : targets) {
                Vector3 anchor; float headoff, feetoff;
                if (plh) {
                    if (*(bool*)((char*)obj + g_pd_local)) continue;
                    int hp = *(int*)((char*)obj + g_pd_health);
                    if (hp <= 0) continue;
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
                bool dup = false;
                for (const Vector3& a : accepted) {
                    float dx = a.x - anchor.x, dy = a.y - anchor.y, dz = a.z - anchor.z;
                    if (dx*dx + dy*dy + dz*dz < DEDUP_DIST2) { dup = true; break; }
                }
                if (dup) continue;
                accepted.push_back(anchor);

                // Prefer real bone anchors (matches the source exactly): head
                // bone for the top, the character's own base transform for
                // the bottom. Only PLH targets expose PlayerObject.trhb; if
                // it's missing (or we're in BotAI mode) fall back to the
                // flat single-anchor + slider-offset method.
                bool haveBones = false;
                Vector3 headBone{}, basePos{};
                if (plh) haveBones = get_bone_pos(obj, BONE_HEAD, headBone) && get_base_pos(obj, basePos);

                if (!calibDone) {
                    Vector3 p0 = anchor;
                    Vector3 p1 = anchor; p1.y += 1.0f;
                    Vector3 s0 = W2S(cam, p0, NULL);
                    Vector3 s1 = W2S(cam, p1, NULL);
                    if (s0.z > 0.0f && s1.z > 0.0f) {
                        float ux0, uy0, ux1, uy1;
                        toUI(s0, ux0, uy0);
                        toUI(s1, ux1, uy1);
                        std::lock_guard<std::mutex> l(g_calib_mtx);
                        g_calib = { true, ux0, uy0, ux1, uy1 };
                        calibDone = true;
                    }
                }

                Vector3 top, bot;
                if (haveBones) {
                    top = headBone; top.y += 0.42f;   // clear the top of the head, per the source
                    bot = basePos;  bot.y += -0.10f;  // just below the base transform, per the source
                } else {
                    top = anchor; top.y += headoff;
                    bot = anchor; bot.y += feetoff;
                }
                Vector3 sTop = W2S(cam, top, NULL);
                Vector3 sBot = W2S(cam, bot, NULL);
                if (sBot.z <= 0.0f || sTop.z <= 0.0f) continue;
                float uxTop, uyTop, uxBot, uyBot;
                toUI(sTop, uxTop, uyTop);
                toUI(sBot, uxBot, uyBot);
                float topY = uyTop, botY = uyBot;
                float cx = (uxTop + uxBot) * 0.5f;
                if (cx <= 0 || cx >= screenW) continue;
                float h = botY - topY; if (h < 6) h = 6;
                // Real bone anchors get the source's aspect-corrected width
                // formula; the flat-anchor fallback keeps its own tuned
                // g_width_mult (changing that formula would break BotAI mode,
                // which is already confirmed correctly proportioned).
                float w = haveBones ? (h * 0.60f * (2.0f / aspect)) : (h * g_width_mult);

                if (haveBones && g_skeleton_on) {
                    static const int pairs[][2] = {
                        {BONE_L_UPLEG,BONE_L_LOLEG}, {BONE_L_LOARM,BONE_L_HAND}, {BONE_L_UPARM,BONE_L_LOARM},
                        {BONE_HEAD,BONE_L_UPARM}, {BONE_HEAD,BONE_CHEST}, {BONE_CHEST,BONE_LOWERCHEST},
                        {BONE_R_UPLEG,BONE_R_LOLEG}, {BONE_LOWERCHEST,BONE_R_UPLEG}, {BONE_R_UPARM,BONE_HEAD},
                        {BONE_R_UPARM,BONE_R_LOARM}, {BONE_R_HAND,BONE_R_LOARM}, {BONE_LOWERCHEST,BONE_L_UPLEG},
                    };
                    for (auto& pr : pairs) {
                        Vector3 a, b;
                        if (!get_bone_pos(obj, pr[0], a) || !get_bone_pos(obj, pr[1], b)) continue;
                        Vector3 sa = W2S(cam, a, NULL), sb = W2S(cam, b, NULL);
                        if (sa.z <= 0.0f || sb.z <= 0.0f) continue;
                        float ax, ay, bx, by;
                        toUI(sa, ax, ay); toUI(sb, bx, by);
                        skelSegs.push_back(SkelSeg{ax, ay, bx, by});
                    }
                }
                Box box{ cx - w*0.5f, topY, w, h };
                if (plh) {
                    if (g_show_health_bar || g_show_health_txt) box.health = *(int*)((char*)obj + g_pd_health);
                    if (g_show_armor_bar) box.armor = *(int*)((char*)obj + g_pd_armor);
                    if (g_show_name) {
                        void* nameStr = *(void**)((char*)obj + g_pd_name);
                        box.name = read_il2cpp_string(nameStr);
                    }
                    if (g_show_weapon) {
                        void* pwo = *(void**)((char*)obj + g_pd_currwpn);
                        if (safe_ptr(pwo)) {
                            void* item = *(void**)((char*)pwo + g_pwo_it);
                            if (safe_ptr(item)) {
                                void* wname = *(void**)((char*)item + g_item_name);
                                box.weapon = read_il2cpp_string(wname);
                            }
                        }
                    }
                }
                boxes.push_back(box);
            }
            { std::lock_guard<std::mutex> l(g_skel_mtx); g_skel_segs.swap(skelSegs); }
        }
    }
    if (!calibDone) { std::lock_guard<std::mutex> l(g_calib_mtx); g_calib.valid = false; }
    if (!(g_esp_on && g_skeleton_on)) { std::lock_guard<std::mutex> l(g_skel_mtx); g_skel_segs.clear(); }
    { std::lock_guard<std::mutex> l(g_boxes_mtx); g_boxes.swap(boxes); }
}

// The main-thread pump: does all il2cpp/game work off the render thread.
static void main_pump() {
    if (g_want_resolve) { g_want_resolve = false; resolve_all(); }
    if (g_want_replh) {
        g_want_replh = false;
        if (g_img && il2cpp_class_from_name && il2cpp_class_get_field_from_name) {
            g_plh_klass = il2cpp_class_from_name(g_img, "", g_plh_cls);
            g_plh_fld = g_plh_klass ? il2cpp_class_get_field_from_name(g_plh_klass, g_plh_field) : NULL;
        }
    }
    if (g_want_debug) {
        g_want_debug = false;
        g_debug_text = build_debug_dump();
        [UIPasteboard generalPasteboard].string =
            [NSString stringWithUTF8String:g_debug_text.c_str()];
    }
    if (g_resolved) { std::vector<void*> v; g_plh_count = enum_plh_players(v); }
    if (g_esp_on && g_resolved) compute_boxes();
}

// Menu visibility, toggled by a 3-finger double-tap anywhere on screen (see
// ESPGestureTarget below). Starts hidden — ESP boxes/skeleton draw regardless,
// this only gates the settings window itself.
static bool g_menu_open = false;

static void render_frame(float screenW, float screenH) {
    std::vector<CGRect> rects;

    if (g_menu_open) {
    ImGui::SetNextWindowSize(ImVec2(300, 0), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(30, 40), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSizeConstraints(ImVec2(240, 0), ImVec2(380, 9999));
    ImGui::Begin("Blockpost ESP");
    {
        ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
        rects.push_back(CGRectMake(wp.x, wp.y, ws.x, ws.y));

        ImGui::Checkbox("ESP", &g_esp_on); ImGui::SameLine();
        // BotAI has no known team offset (g_off_team==0) so "enemies only"
        // is a silent no-op in that mode — grey it out instead of pretending
        // it works, rather than leave it clickable-but-broken.
        bool enemiesOnlyUsable = (g_esp_src == 1) || (g_off_team != 0);
        ImGui::BeginDisabled(!enemiesOnlyUsable);
        ImGui::Checkbox("Enemies only", &g_enemies_only);
        ImGui::EndDisabled();
        if (!enemiesOnlyUsable) { ImGui::SameLine(); ImGui::TextDisabled("(no team data in BotAI mode)"); }
        ImGui::RadioButton("PLH players (real)", &g_esp_src, 1); ImGui::SameLine();
        ImGui::RadioButton("FindObjectsOfType", &g_esp_src, 0);
        ImGui::InputInt("Local team", &g_local_team);
        if (g_esp_src == 1) {
            ImGui::SliderFloat("Box top",   &g_pd_head_off, -1.0f, 3.0f);
            ImGui::SliderFloat("Box bottom",&g_pd_feet_off, -3.0f, 1.0f);
            ImGui::SameLine();
            if (ImGui::Button("Reset##pd")) { g_pd_head_off = 1.6f; g_pd_feet_off = -0.1f; }
        } else {
            ImGui::SliderFloat("Box top",   &g_head_off, -3.0f, 3.0f);
            ImGui::SliderFloat("Box bottom",&g_feet_off, -3.0f, 3.0f);
            ImGui::SameLine();
            if (ImGui::Button("Reset##bot")) { g_head_off = 0.2f; g_feet_off = -1.9f; }
        }
        if (g_esp_src != 1) ImGui::SliderFloat("Box width", &g_width_mult, 0.1f, 1.0f);

        if (g_esp_src == 1) {
            ImGui::Checkbox("Skeleton (real bones)", &g_skeleton_on);
            ImGui::SameLine(); ImGui::TextDisabled("(PLH only)");
            ImGui::Checkbox("Name", &g_show_name); ImGui::SameLine();
            ImGui::Checkbox("Health bar", &g_show_health_bar); ImGui::SameLine();
            ImGui::Checkbox("Health text", &g_show_health_txt);
            ImGui::Checkbox("Armor bar", &g_show_armor_bar); ImGui::SameLine();
            ImGui::Checkbox("Weapon name", &g_show_weapon);
        }

        if (ImGui::CollapsingHeader("Target / offsets (advanced)")) {
            ImGui::InputText("image", g_image_name, sizeof(g_image_name));
            ImGui::InputText("namespace", g_target_ns, sizeof(g_target_ns));
            ImGui::InputText("class", g_target_cls, sizeof(g_target_cls));
            ImGui::RadioButton("pos: field", &g_pos_mode, 0); ImGui::SameLine();
            ImGui::RadioButton("pos: get_transform()", &g_pos_mode, 1);
            ImGui::InputScalar("tf off",   ImGuiDataType_U64, &g_off_tf,   0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team off", ImGuiDataType_U64, &g_off_team, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            if (ImGui::Button("Apply / Re-resolve")) g_want_resolve = true;
            ImGui::SameLine();
            if (ImGui::Button("Target = Player")) {
                strcpy(g_target_cls, "Player"); g_target_ns[0] = 0;
                g_pos_mode = 1;               // Player: position via get_transform()
                g_want_resolve = true;
            }
            ImGui::SameLine();
            if (ImGui::Button("Target = BotAI")) {
                strcpy(g_target_cls, "BotAI"); g_target_ns[0] = 0;
                g_pos_mode = 1; g_off_tf = 0x20;   // get_transform() is the confirmed-correct anchor
                g_want_resolve = true;
            }
        }

        ImGui::SeparatorText("State");
        if (ImGui::Button("RESOLVE il2cpp (tap in-game)")) g_want_resolve = true;
        ImGui::Text("resolved=%d step=%d attached=%d", g_resolved ? 1 : 0, g_resolve_step, g_attached ? 1 : 0);
        ImGui::Text("PREV RUN reached step=%d", g_prev_step);
        ImGui::TextDisabled("(10 bind,11 asm_open,12 img,13 PLHcls,14 fld,15 type,16 done)");
        ImGui::InputText("assembly", g_asm_name, sizeof(g_asm_name));
        ImGui::Text("base=0x%lx", (unsigned long)g_image_base);
        ImGui::Text("dom=%p asmb=%p", g_dom, g_asmb);
        ImGui::Text("img=%p type_obj=%p", g_img, g_type_obj);
        ImGui::Text("PLH klass=%p fld=%p (auto: %s, score=%d)", g_plh_klass, g_plh_fld, g_plh_field, g_plh_field_score);
        ImGui::Text("PLH players now=%d  boxes=%d", g_plh_count, (int)g_boxes.size());
        {
            std::lock_guard<std::mutex> l(g_calib_mtx);
            if (g_calib.valid)
                ImGui::Text("CALIB yellow=(%.0f,%.0f) cyan=(%.0f,%.0f) [1 unit = %.1fpx]",
                             g_calib.x0, g_calib.y0, g_calib.x1, g_calib.y1, g_calib.y0 - g_calib.y1);
            else
                ImGui::TextDisabled("CALIB: no target in view");
        }

        if (ImGui::CollapsingHeader("PlayerData offsets")) {
            ImGui::InputText("PLH class", g_plh_cls, sizeof(g_plh_cls));
            ImGui::InputText("PLH field (array)", g_plh_field, sizeof(g_plh_field));
            ImGui::InputScalar("Pos",    ImGuiDataType_U64, &g_pd_pos,    0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("health", ImGuiDataType_U64, &g_pd_health, 0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("team",   ImGuiDataType_U64, &g_pd_team,   0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            ImGui::InputScalar("local",  ImGuiDataType_U64, &g_pd_local,  0,0,"%lx", ImGuiInputTextFlags_CharsHexadecimal);
            if (ImGui::Button("Re-resolve PLH field")) g_want_replh = true;  // main-thread pump does the actual call
        }

        ImGui::SeparatorText("Self-test / offset explorer");
        ImGui::Checkbox("2. class names", &g_dbg_names);
        ImGui::Checkbox("3. positions", &g_dbg_pos);
        ImGui::Checkbox("4. project (W2S)", &g_dbg_w2s);

        if (ImGui::Button("Copy Debug (probe + scan)")) g_want_debug = true;
        ImGui::SameLine(); ImGui::TextDisabled("(-> paste to Nyx)");
    }
    ImGui::End();
    } // g_menu_open

    // Publish display size for the main-thread pump, then DRAW cached boxes.
    // No il2cpp/game reads happen on this (render) thread anymore.
    g_scrW = screenW; g_scrH = screenH;
    {
        ImDrawList* dl = ImGui::GetForegroundDrawList();
        std::lock_guard<std::mutex> l(g_boxes_mtx);
        for (const Box& b : g_boxes) {
            ImVec2 tl(b.x, b.y), br(b.x + b.w, b.y + b.h);
            dl->AddRect(ImVec2(tl.x-1,tl.y-1), ImVec2(br.x+1,br.y+1), IM_COL32(0,0,0,180), 0,0,3.0f);
            dl->AddRect(tl, br, IM_COL32(255,40,40,255), 0,0,1.5f);

            if (!b.name.empty()) {
                ImVec2 ts = ImGui::CalcTextSize(b.name.c_str());
                draw_outlined_text(dl, ImVec2(b.x + b.w*0.5f - ts.x*0.5f, b.y - ts.y - 3),
                                    IM_COL32(255,255,255,255), b.name.c_str());
            }
            if (b.health >= 0) {
                float barW = 4.0f, bx0 = b.x - barW - 3, bx1 = b.x - 3;
                ImU32 col = b.health > 75 ? IM_COL32(60,220,60,255) : b.health > 50 ? IM_COL32(230,220,40,255)
                          : b.health > 25 ? IM_COL32(255,150,30,255) : IM_COL32(230,50,50,255);
                float ratio = b.health > 100 ? 1.0f : b.health / 100.0f;
                float filledH = b.h * ratio;
                dl->AddRectFilled(ImVec2(bx0, b.y), ImVec2(bx1, b.y+b.h), IM_COL32(0,0,0,160));
                dl->AddRectFilled(ImVec2(bx0, b.y + (b.h - filledH)), ImVec2(bx1, b.y+b.h), col);
                dl->AddRect(ImVec2(bx0, b.y), ImVec2(bx1, b.y+b.h), IM_COL32(0,0,0,255));
                if (g_show_health_txt) {
                    char buf[8]; snprintf(buf, sizeof(buf), "%d", b.health);
                    ImVec2 ts = ImGui::CalcTextSize(buf);
                    draw_outlined_text(dl, ImVec2(bx0 - ts.x - 2, b.y + b.h - ts.y), col, buf);
                }
            }
            if (b.armor >= 0 && b.armor > 0) {
                float barH = 4.0f, ay0 = b.y + b.h + 3, ay1 = ay0 + barH;
                float ratio = b.armor > 100 ? 1.0f : b.armor / 100.0f;
                float filledW = b.w * ratio;
                dl->AddRectFilled(ImVec2(b.x, ay0), ImVec2(b.x+b.w, ay1), IM_COL32(0,0,0,160));
                dl->AddRectFilled(ImVec2(b.x, ay0), ImVec2(b.x+filledW, ay1), IM_COL32(60,170,255,255));
                dl->AddRect(ImVec2(b.x, ay0), ImVec2(b.x+b.w, ay1), IM_COL32(0,0,0,255));
            }
            if (!b.weapon.empty()) {
                ImVec2 ts = ImGui::CalcTextSize(b.weapon.c_str());
                float yoff = b.y + b.h + (b.armor > 0 ? 12.0f : 4.0f);
                draw_outlined_text(dl, ImVec2(b.x + b.w*0.5f - ts.x*0.5f, yoff),
                                    IM_COL32(200,200,255,255), b.weapon.c_str());
            }
        }
    }
    {
        std::lock_guard<std::mutex> l(g_skel_mtx);
        if (!g_skel_segs.empty()) {
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            for (const SkelSeg& s : g_skel_segs)
                dl->AddLine(ImVec2(s.x1, s.y1), ImVec2(s.x2, s.y2), IM_COL32(80,220,255,255), 1.5f);
        }
    }
    // Calibration dots: yellow = raw anchor (zero offset), cyan = anchor +1
    // world unit up. Screenshot these next to the character and the exact
    // pixel gap tells us precisely what offset the box top/bottom need —
    // no more guessing.
    {
        std::lock_guard<std::mutex> l(g_calib_mtx);
        if (g_calib.valid) {
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            dl->AddCircleFilled(ImVec2(g_calib.x0, g_calib.y0), 5.0f, IM_COL32(255,255,0,255));
            dl->AddCircleFilled(ImVec2(g_calib.x1, g_calib.y1), 5.0f, IM_COL32(0,255,255,255));
            dl->AddLine(ImVec2(g_calib.x0, g_calib.y0), ImVec2(g_calib.x1, g_calib.y1), IM_COL32(255,255,255,180), 1.5f);
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
    // Always let a genuine 3-finger touch reach OUR window (and therefore our
    // gesture recognizer below), regardless of the menu's capture rects — this
    // is how the menu gets opened in the first place when it's hidden. Relying
    // on finding "the game's own window" via the deprecated, sometimes-nil
    // UIApplication.keyWindow was fragile (confirmed broken on this build);
    // intercepting inside our OWN window sidesteps that entirely. A stray
    // 3-finger touch during normal one/two-thumb play essentially never
    // happens, so this doesn't interfere with gameplay.
    if (event.allTouches.count >= 3) return [super hitTest:point withEvent:event];
    std::lock_guard<std::mutex> l(g_rects_mtx);
    for (const CGRect& r : g_capture_rects)
        if (CGRectContainsPoint(r, point)) return [super hitTest:point withEvent:event];
    return nil;
}
@end

// 3-finger double-tap toggles the menu. The recognizer lives on OUR OWN view
// (ESPView, below) — ESPWindow.hitTest above carves out an exception so
// 3-finger touches always reach it even while the menu is closed and
// everything else passes through to the game untouched.
@interface ESPGestureTarget : NSObject
- (void)onTripleTap:(UITapGestureRecognizer*)g;
@end
@implementation ESPGestureTarget
- (void)onTripleTap:(UITapGestureRecognizer*)g { g_menu_open = !g_menu_open; }
@end
static ESPGestureTarget* g_gestureTarget = nil;

static ESPWindow*   g_window   = nil;
static ESPRenderer* g_renderer = nil;

static void setup_overlay() {
    g_prev_step = read_step();   // what the last run reached before dying (if any)

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
    ImGui::GetStyle().TouchExtraPadding = ImVec2(6.0f, 6.0f);  // finger-sized hit targets, incl. the resize grip
    ImGui_ImplMetal_Init(device);

    g_renderer = [ESPRenderer new];
    g_renderer.queue = [device newCommandQueue];
    mtk.delegate = g_renderer;
    [g_window makeKeyAndVisible];

    // Attached to OUR OWN view — ESPWindow.hitTest carves out the exception
    // that lets 3-finger touches reach it regardless of the menu's open state.
    g_gestureTarget = [ESPGestureTarget new];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:g_gestureTarget action:@selector(onTripleTap:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    [mtk addGestureRecognizer:tap];

    // Main-thread pump: ALL il2cpp/game reads happen here, never on the render
    // thread. Matched to the render thread's 60fps so boxes update every
    // drawn frame instead of visibly lagging behind at half rate.
    [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES
                                      block:^(NSTimer* t) { main_pump(); }];
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
