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
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <vector>
#include <mutex>
#include <string>
#include <cmath>
#include <fstream>
#include <algorithm>
#include <substrate.h>

#include "imgui.h"
#include "imgui_impl_metal.h"

// Bump this every release — shown in the always-on load indicator so it's
// obvious whether the loader actually replaced the running dylib with the
// latest one, vs a stale cached copy.
#define BUILD_TAG "v0.11.1-hidfix"

static double g_overlay_start_time = 0;
static bool   g_gesture_host_found = false;

struct Vector3 { float x, y, z; };
struct Quat { float x, y, z, w; };   // Unity Quaternion layout

// Resolved Unity methods (called by address; trailing arg = hidden MethodInfo*)
typedef Vector3 (*Cam_W2S_t)(void* camera, Vector3 pos, void* method);      // Camera.WorldToScreenPoint(Vector3)
typedef void*   (*Cam_get_main_t)(void* method);                            // Camera.get_main
typedef Vector3 (*Tf_get_pos_t)(void* transform, void* method);            // Transform.get_position
typedef void*   (*FindObjs_t)(void* type, void* method);                    // Object.FindObjectsOfType(Type)
typedef void*   (*Comp_get_tf_t)(void* component, void* method);           // Component.get_transform
typedef int32_t (*Cam_pixelDim_t)(void* camera, void* method);             // Camera.get_pixelWidth/Height
typedef uint8_t (*Physics_Raycast_t)(Vector3 origin, Vector3 direction, float maxDistance, int32_t layerMask, void* method); // Physics.Raycast(...) -> bool (il2cpp bool = 1 byte)
typedef void    (*Tf_set_rot_t)(void* transform, Quat value, void* method);  // Transform.set_rotation(Quaternion)

static Cam_W2S_t      W2S             = NULL;
static Cam_get_main_t Camera_get_main = NULL;
static Tf_get_pos_t   Tf_get_pos      = NULL;
static FindObjs_t     FindObjs        = NULL;
static Physics_Raycast_t Physics_Raycast = NULL;
static Tf_set_rot_t   Tf_set_rotation  = NULL;
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
#define RVA_PHYSICS_RAYCAST  0x483dac4   // Physics.Raycast(Vector3,Vector3,float,int) -> bool
#define RVA_TF_SET_ROTATION  0x47f3bec   // Transform.set_rotation(Quaternion)

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
static int  g_esp_src   = 1;            // hardcoded to PLH players (real players, bone-accurate) — the only ESP mode that ships now
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

// --- Aimbot: SetInputs hook, writes the camera-rotation quaternion --------
// ExampleCharacterController.lookInputVector (0xFC) turned out to be the
// WRONG field — writing it never reliably steered the camera. The actual
// field is a quaternion, m_qCameraRotation, INSIDE the inputs struct passed
// BY REFERENCE to SetInputs. A reference implementation for this game (a
// DIFFERENT, older BPM build) put it at offset 0x18 — but that build's
// struct layout doesn't match ours: OUR dump's own struct definition
// (`public struct LOJIJGDIIEB`, the exact type SetInputs takes) shows
//   0x0  float moveAxisForward
//   0x4  float moveAxisRight
//   0x8  Quaternion  <- m_qCameraRotation, HERE, not 0x18
//   0x18 bool jumpDown
//   0x19 bool crouchDown
//   0x1A bool crouchUp
// Writing 16 bytes at 0x18 (the old, cross-build-borrowed offset) was
// smashing the jump/crouch bools AND writing 13 bytes past the end of the
// struct into adjacent heap memory — exactly what caused the random
// jumping/crouching. Verified directly against OUR OWN dump this time,
// not borrowed from a different build again.
static uintptr_t g_ecc_camrot_off = 0x8;  // PlayerCharacterInputs.m_qCameraRotation (Quaternion) inside the SetInputs arg struct — verified against our own dump's struct layout
static char      g_ecc_ns[64]    = "KinematicCharacterController.Examples";
static char      g_ecc_cls[64]   = "ExampleCharacterController";
static void*     g_ecc_type_obj  = NULL;   // cached System.Type for the above
static bool      g_aimbot_on         = false;
// Assist mode: blend from the REAL current view (whatever the player's own
// manual input already set this tick) toward the target, instead of from
// our own persistent auto-lock state. The persistent-state design (below)
// exists specifically so a fully idle player still converges onto a
// stationary target — but that same design is what was fighting manual
// aiming: writing 300+ times/sec from an independent trajectory that never
// reads the player's own movement back overwrites it outright. Blending
// from the real value instead composes with whatever the player does each
// tick (small nudge toward target, layered on top of their own input) — the
// actual behavior a controller/console "aim assist" has, as opposed to a
// full auto-lock.
static bool      g_assist_mode       = false;
static float     g_aimbot_fov_px     = 220.0f;  // max screen-space distance (UI points) from crosshair to consider a target
// Constant-angular-speed turn rate, degrees/second, NOT a 0..1 lerp fraction.
// A fixed-fraction slerp (the old g_aimbot_smooth) takes the SAME percentage
// of whatever the current gap is every tick — which means a big fresh gap
// (just-acquired target) moves a big ABSOLUTE angle on the very first frame
// (the "resкий рывок"/sudden jerk), and a tiny gap (converged onto a now-
// stationary target) moves an imperceptibly tiny angle forever after,
// visually reading as "stopped following". A capped max-degrees-per-frame
// step fixes both: the very first frame is limited exactly the same as every
// later one (no jerk possible), and it keeps closing the gap at a constant
// rate all the way to an exact lock instead of decaying asymptotically.
static float     g_aimbot_turn_speed_dps = 900.0f;
static bool      g_aimbot_wallcheck  = true;   // skip targets with no clear line of sight (Physics.Raycast)
static bool      g_multipoint_on     = true;   // sample multiple points around each selected hitbox instead of only its exact center
static int       g_multipoint_count  = 8;      // ring samples around each hitbox, 3..12

// Which bones count as valid aim/trigger hitboxes — multi-select, indexed
// directly by BoneIdx (0..14; index 9 is an unused gap in that enum and
// always stays false). Default: chest only, matching the old single-bone
// Combo's default.
static bool      g_hitbox_sel[15] = { false,false,true,false, false,false,false,false,false,
                                       false, false,false,false,false, false };
static const int  kAllBoneIndices[] = { BONE_STOMACH, BONE_LOWERCHEST, BONE_CHEST, BONE_HEAD,
                                         BONE_R_UPARM, BONE_R_LOARM, BONE_R_HAND, BONE_R_UPLEG, BONE_R_LOLEG,
                                         BONE_L_UPARM, BONE_L_LOARM, BONE_L_HAND, BONE_L_UPLEG, BONE_L_LOLEG };
static const char* kBoneNames[] = { "Stomach","Lower Chest","Chest","Head",
                                     "R UpperArm","R LowerArm","R Hand","R UpperLeg","R LowerLeg",
                                     "L UpperArm","L LowerArm","L Hand","L UpperLeg","L LowerLeg" };
static const int  kAllBoneCount = 14;

// UI-facing hitbox groups: the 14 individual bones above are still what
// aiming/triggerbot actually check (g_hitbox_sel stays indexed by BoneIdx),
// but the menu only exposes 4 toggle rows — picking a group flips every bone
// inside it together.
static const int kGroupHeadBones[] = { BONE_HEAD };
static const int kGroupBodyBones[] = { BONE_STOMACH, BONE_LOWERCHEST, BONE_CHEST };
static const int kGroupArmsBones[] = { BONE_R_UPARM, BONE_R_LOARM, BONE_R_HAND, BONE_L_UPARM, BONE_L_LOARM, BONE_L_HAND };
static const int kGroupLegsBones[] = { BONE_R_UPLEG, BONE_R_LOLEG, BONE_L_UPLEG, BONE_L_LOLEG };
struct HitboxGroup { const char* name; const int* bones; int count; };
static const HitboxGroup kHitboxGroups[] = {
    { "Head", kGroupHeadBones, 1 },
    { "Body", kGroupBodyBones, 3 },
    { "Arms", kGroupArmsBones, 6 },
    { "Legs", kGroupLegsBones, 4 },
};
static const int kHitboxGroupCount = 4;

// Triggerbot: fires a simulated tap once the crosshair is directly on a
// selected hitbox — independent of the visual aimbot/assist, works with
// pure manual aiming too.
static bool      g_trigger_on              = false;
static float     g_trigger_radius_px       = 25.0f;  // how close to screen-center counts as "on the hitbox"
static float     g_trigger_reaction_min_ms = 0.0f;
static float     g_trigger_reaction_max_ms = 0.0f;
static float     g_trigger_rapid_s         = 0.15f;  // minimum seconds between repeated shots while held on target
static bool      g_trigger_pending         = false;
static double    g_trigger_pending_until   = 0.0;
static double    g_trigger_last_fire_time  = 0.0;
static long      g_trigger_fire_count      = 0;
static float     g_trigger_tap_x           = -1.0f, g_trigger_tap_y = -1.0f; // draggable marker; -1 = not yet placed (defaults to screen center once known)
// Diagnostic-only (temporary): declared up here (not next to g_hidClient
// below, where they're actually written) so render_frame — which comes
// BEFORE the IOHID section in this file — can read them for the on-screen
// trigger debug line. Remove alongside that debug line once confirmed.
static long      g_hid_dispatch_count      = 0;
static bool      g_hid_client_ok           = false;
static float     g_hid_last_tap_x          = -1.0f, g_hid_last_tap_y = -1.0f;
// Persistent aim-turn state, updated ourselves frame-to-frame instead of
// re-reading the inputs struct's "cur" field as the slerp start point. The
// struct's field turned out to reflect the game's own (untouched, since the
// player isn't moving their finger) view each tick rather than our previous
// write — so blending from it every frame recomputed the SAME step from the
// SAME baseline to the SAME target and just froze partway there instead of
// continuing to converge. Blending from our own last output instead makes
// each tick a genuine step further along, so a stationary target actually
// gets walked all the way onto over successive frames. Reset to invalid
// whenever we don't have a live target this tick, so re-acquiring one
// reseeds cleanly from the real current view instead of slerping from a
// stale value that might now point somewhere unrelated.
static Quat      g_aim_state_quat{};
static bool      g_aim_state_valid    = false;

// Diagnostic-only (temporary): computed target vs actually-applied camera
// orientation in human-readable euler degrees, for the on-screen aim debug
// line — remove once the aim direction is confirmed correct on-device.
static Vector3   g_aim_dbg_target_euler{};
static Vector3   g_aim_dbg_applied_euler{};
static bool      g_aim_dbg_valid       = false;

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
static int  g_local_team   = -1;   // manual override; -1 = use auto-detected (PLH only)
static int  g_auto_local_team_display = -1;  // last auto-detected team, for the UI

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
    Physics_Raycast = (Physics_Raycast_t)(B + RVA_PHYSICS_RAYCAST);
    Tf_set_rotation = (Tf_set_rot_t)(B + RVA_TF_SET_ROTATION);

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

// Line-of-sight check for one specific world point, used both for the
// selected aim bone and for the multipoint fallback scan below. The margin
// excluded from the very end of the ray (so the target's OWN collider isn't
// what the raycast hits) used to be a PERCENTAGE of total distance
// (dist*0.92f) — that's the actual bug behind "raycast says clear but you
// can see a wall in front of the head, only an arm pokes out": for a target
// 20 units away, 8% is 1.6 world units, so any wall sitting within that
// last 1.6 units of the target (i.e. a thin wall right behind/beside them)
// fell inside the excluded zone and was never actually tested. A FIXED
// small margin (world units, not distance-scaled) closes that hole at any
// range.
static bool bone_is_visible(Vector3 eye, Vector3 point) {
    if (!g_aimbot_wallcheck || !Physics_Raycast) return true;
    Vector3 toTarget{ point.x - eye.x, point.y - eye.y, point.z - eye.z };
    float dist = sqrtf(toTarget.x*toTarget.x + toTarget.y*toTarget.y + toTarget.z*toTarget.z);
    if (dist <= 0.01f) return true;
    Vector3 rayDir{ toTarget.x/dist, toTarget.y/dist, toTarget.z/dist };
    const float kTargetSkin = 0.25f; // fixed world-unit margin, not a % of dist
    float castDist = dist - kTargetSkin;
    if (castDist < 0.01f) castDist = 0.01f;
    return Physics_Raycast(eye, rayDir, castDist, ~0, NULL) == 0;
}

// A bone position is a single point at the CENTER of e.g. the head — but the
// head has actual volume, and it's extremely common to see only an EDGE of
// it (peeking around a corner, over a crate, etc.) while the center point
// specifically is still occluded. Checking only the center meant those
// exactly-visible-at-the-edge cases got rejected as "blocked" even though a
// human would clearly see (and could shoot) the sliver that's exposed. This
// samples a small ring of points around the bone, offset along the camera-
// facing right/up axes (built from eye->bone direction, not the character's
// own facing, so "left/right/up/down" here means what's actually left/
// right/up/down from the PLAYER'S viewpoint) rather than only ever testing
// dead-center. Returns the first visible sample (center first), still
// anchored to the same bone — this is NOT the separate other-bone fallback
// below, it's sub-bone precision for the one bone that's actually selected.
static const float kBoneVisRadius = 0.18f; // approx. half-width of a head-sized hitbox, world units
static bool find_visible_point_near(Vector3 eye, Vector3 center, float radius, Vector3& outPoint) {
    if (bone_is_visible(eye, center)) { outPoint = center; return true; }
    Vector3 look{ center.x - eye.x, center.y - eye.y, center.z - eye.z };
    float lm = sqrtf(look.x*look.x + look.y*look.y + look.z*look.z);
    if (lm < 0.001f) return false;
    look.x /= lm; look.y /= lm; look.z /= lm;
    Vector3 worldUp{0.0f, 1.0f, 0.0f};
    Vector3 right{ look.y*worldUp.z - look.z*worldUp.y,
                   look.z*worldUp.x - look.x*worldUp.z,
                   look.x*worldUp.y - look.y*worldUp.x };
    float rl = sqrtf(right.x*right.x + right.y*right.y + right.z*right.z);
    if (rl < 0.001f) { right = Vector3{1.0f, 0.0f, 0.0f}; } else { right.x/=rl; right.y/=rl; right.z/=rl; }
    Vector3 up{ right.y*look.z - right.z*look.y,
                right.z*look.x - right.x*look.z,
                right.x*look.y - right.y*look.x };
    // Evenly-spaced ring of g_multipoint_count samples (user-configurable,
    // 3..12) instead of a fixed 8 — more points means finer coverage of the
    // hitbox's edge at the cost of a few extra raycasts per candidate.
    int n = g_multipoint_count;
    if (n < 3) n = 3;
    if (n > 12) n = 12;
    for (int i = 0; i < n; i++) {
        float ang = (2.0f * (float)M_PI) * ((float)i / (float)n);
        float ox = cosf(ang), oy = sinf(ang);
        Vector3 p;
        p.x = center.x + right.x*ox*radius + up.x*oy*radius;
        p.y = center.y + right.y*ox*radius + up.y*oy*radius;
        p.z = center.z + right.z*ox*radius + up.z*oy*radius;
        if (bone_is_visible(eye, p)) { outPoint = p; return true; }
    }
    return false;
}

// Same ring geometry as find_visible_point_near above, but instead of
// stopping at the first VISIBLE sample (what aiming wants), this calls back
// for every sample point — center first, then the full multipoint ring if
// enabled — so a caller can test each one against its own condition (here:
// "is the crosshair on it") rather than just "can I see it". Kept separate
// from find_visible_point_near rather than refactored into it, so the
// already-working aim path is untouched.
template <typename F>
static void for_each_hitbox_sample_point(Vector3 eye, Vector3 center, float radius, bool multipointOn, F&& fn) {
    if (fn(center)) return;
    if (!multipointOn) return;
    Vector3 look{ center.x - eye.x, center.y - eye.y, center.z - eye.z };
    float lm = sqrtf(look.x*look.x + look.y*look.y + look.z*look.z);
    if (lm < 0.001f) return;
    look.x /= lm; look.y /= lm; look.z /= lm;
    Vector3 worldUp{0.0f, 1.0f, 0.0f};
    Vector3 right{ look.y*worldUp.z - look.z*worldUp.y,
                   look.z*worldUp.x - look.x*worldUp.z,
                   look.x*worldUp.y - look.y*worldUp.x };
    float rl = sqrtf(right.x*right.x + right.y*right.y + right.z*right.z);
    if (rl < 0.001f) { right = Vector3{1.0f, 0.0f, 0.0f}; } else { right.x/=rl; right.y/=rl; right.z/=rl; }
    Vector3 up{ right.y*look.z - right.z*look.y,
                right.z*look.x - right.x*look.z,
                right.x*look.y - right.y*look.x };
    int n = g_multipoint_count;
    if (n < 3) n = 3;
    if (n > 12) n = 12;
    for (int i = 0; i < n; i++) {
        float ang = (2.0f * (float)M_PI) * ((float)i / (float)n);
        float ox = cosf(ang), oy = sinf(ang);
        Vector3 p;
        p.x = center.x + right.x*ox*radius + up.x*oy*radius;
        p.y = center.y + right.y*ox*radius + up.y*oy*radius;
        p.z = center.z + right.z*ox*radius + up.z*oy*radius;
        if (fn(p)) return;
    }
}

// Resolve exactly like the Android source: NO il2cpp_domain_get (that hung),
// NO thread_attach. Then AUTO-PICK whichever candidate PLH field actually
// holds sane player data — no manual retyping needed when the game updates
// and obfuscated names shuffle. Only falls back to hand-editing the field
// name in the menu if every candidate scores 0 (rare: a brand new field
// layout, not just a renamed one).
static void install_aimbot_hook();  // defined below; forward-declared for use here
static void maybe_triggerbot();     // defined below (needs find_game_root_view); forward-declared for use in main_pump
static void resolve_all() {
    write_step(10); bind_pointers();
    install_aimbot_hook();
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
    write_step(16); g_ecc_type_obj = g_img ? type_object_for(g_ecc_ns, g_ecc_cls) : NULL;
    write_step(17); g_dom = NULL; g_resolved = true;
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

            // Auto-detect the local player's team from the localplayer flag —
            // no need to hand-type "Local team" for PLH (that field stays
            // around only as a manual override / for BotAI mode, where there's
            // no such flag to read). Was the actual reason "Enemies only" did
            // nothing: g_local_team defaults to -1 (disabled) and nobody had
            // typed a team number in, so the filter's guard never activated.
            int autoLocalTeam = -1;
            if (plh) {
                for (void* obj : targets) {
                    if (*(bool*)((char*)obj + g_pd_local)) {
                        autoLocalTeam = *(int*)((char*)obj + g_pd_team);
                        break;
                    }
                }
            }
            const int effectiveLocalTeam = (g_local_team >= 0) ? g_local_team : autoLocalTeam;
            g_auto_local_team_display = autoLocalTeam;

            for (void* obj : targets) {
                Vector3 anchor; float headoff, feetoff;
                if (plh) {
                    if (*(bool*)((char*)obj + g_pd_local)) continue;
                    int hp = *(int*)((char*)obj + g_pd_health);
                    if (hp <= 0) continue;
                    if (g_enemies_only && effectiveLocalTeam >= 0) {
                        int tm = *(int*)((char*)obj + g_pd_team);
                        if (tm == effectiveLocalTeam) continue;
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
// Visual aimbot: writes into the local player's own
// ExampleCharacterController.lookInputVector — the same field the game's own
// touch-drag code writes every frame, so the camera visibly turns exactly
// like a real drag would. Target = nearest-to-screen-center living enemy
// within g_aimbot_fov_px, aimed at a real bone when available (else the flat
// Pos field), turned toward at a constant g_aimbot_turn_speed_dps so it never snaps.
//
// MUST run from inside the SetInputs hook below, not an async timer: a plain
// periodic field write got silently overwritten every frame by the game's
// own input processing before ever being consumed (confirmed empirically —
// it only had a visible, one-off effect once, right as the player died and
// normal input processing paused). Calling this from the hook, AFTER
// forwarding to the real SetInputs, guarantees our write lands in the exact
// frame window between "game finished its own input processing" and
// "controller consumes lookInputVector for rotation" — every single frame.
// Quaternion layout matches Unity's own (x,y,z,w), 16 bytes — standard, not
// build-specific.

// Replaces a prior Euler-angle (pitch/yaw/roll -> Quaternion.Euler) approach
// that was removed after it turned out to point aim in a consistently wrong
// absolute direction while still tracking target movement correctly — the
// exact signature of an Euler axis-order/sign mistake (see git history for
// the old euler_to_quat_unity if a future session needs to A/B it again).
// Builds the "look at target" quaternion DIRECTLY from the eye->target direction via a
// right/up/forward basis + matrix->quaternion conversion (Shepperd's
// method), instead of going through pitch/yaw/roll Euler angles at all.
// This sidesteps Euler axis-order/sign pitfalls entirely — there is no
// pitch/yaw/roll ordering to get subtly wrong, no atan2/asin sign-convention
// trick needed. Cross-product order (cross(up, forward) for "right") is
// Unity's own left-handed convention, verified against Unity's actual
// coordinate axes (up=+Y, forward=+Z => right=+X).
static Quat quat_look_rotation(Vector3 forward, Vector3 upHint) {
    float flen = sqrtf(forward.x*forward.x + forward.y*forward.y + forward.z*forward.z);
    if (flen < 0.0001f) return Quat{0.0f, 0.0f, 0.0f, 1.0f};
    forward.x /= flen; forward.y /= flen; forward.z /= flen;

    Vector3 right{ upHint.y*forward.z - upHint.z*forward.y,
                   upHint.z*forward.x - upHint.x*forward.z,
                   upHint.x*forward.y - upHint.y*forward.x };
    float rlen = sqrtf(right.x*right.x + right.y*right.y + right.z*right.z);
    if (rlen < 0.0001f) right = Vector3{1.0f, 0.0f, 0.0f};
    else { right.x /= rlen; right.y /= rlen; right.z /= rlen; }

    Vector3 up{ forward.y*right.z - forward.z*right.y,
                forward.z*right.x - forward.x*right.z,
                forward.x*right.y - forward.y*right.x };

    float m00=right.x, m01=up.x, m02=forward.x;
    float m10=right.y, m11=up.y, m12=forward.y;
    float m20=right.z, m21=up.z, m22=forward.z;

    Quat q;
    float trace = m00 + m11 + m22;
    if (trace > 0.0f) {
        float s = sqrtf(trace + 1.0f) * 2.0f;
        q.w = 0.25f * s;
        q.x = (m21 - m12) / s;
        q.y = (m02 - m20) / s;
        q.z = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
        float s = sqrtf(1.0f + m00 - m11 - m22) * 2.0f;
        q.w = (m21 - m12) / s;
        q.x = 0.25f * s;
        q.y = (m01 + m10) / s;
        q.z = (m02 + m20) / s;
    } else if (m11 > m22) {
        float s = sqrtf(1.0f + m11 - m00 - m22) * 2.0f;
        q.w = (m02 - m20) / s;
        q.x = (m01 + m10) / s;
        q.y = 0.25f * s;
        q.z = (m12 + m21) / s;
    } else {
        float s = sqrtf(1.0f + m22 - m00 - m11) * 2.0f;
        q.w = (m10 - m01) / s;
        q.x = (m02 + m20) / s;
        q.y = (m12 + m21) / s;
        q.z = 0.25f * s;
    }
    float n = sqrtf(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w);
    if (n > 0.0001f) { q.x/=n; q.y/=n; q.z/=n; q.w/=n; }
    return q;
}

// Debug-only: quaternion -> euler degrees, for on-screen diagnostic text.
// Never used for actual aiming math, only for human-readable display.
static Vector3 quat_to_euler_deg(Quat q) {
    const float r2d = 180.0f / (float)M_PI;
    Vector3 e;
    float sinp = 2.0f*(q.w*q.x - q.y*q.z);
    e.x = (fabsf(sinp) >= 1.0f ? copysignf((float)M_PI/2.0f, sinp) : asinf(sinp)) * r2d;
    e.y = atan2f(2.0f*(q.w*q.y + q.z*q.x), 1.0f - 2.0f*(q.x*q.x + q.y*q.y)) * r2d;
    e.z = atan2f(2.0f*(q.w*q.z + q.x*q.y), 1.0f - 2.0f*(q.y*q.y + q.z*q.z)) * r2d;
    return e;
}

// Proper spherical interpolation (Shoemake). NLERP (plain lerp+normalize)
// only approximates constant angular velocity and gets visibly uneven
// (eases oddly, "sticks" near the ends) once the angle between a and b is
// more than a few degrees — exactly the case here since a fresh target can
// be 90+ degrees from the current view. Slerp walks the shortest arc at a
// constant rate instead, so panning speed feels the same regardless of how
// far off-target the camera currently is.
static Quat quat_slerp(Quat a, Quat b, float t) {
    float dot = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w;
    if (dot < 0.0f) { b.x = -b.x; b.y = -b.y; b.z = -b.z; b.w = -b.w; dot = -dot; }
    Quat r;
    if (dot > 0.9995f) {
        // Nearly identical: sin(theta0) below would be ~0 (divide-by-zero
        // risk), and linear blending is visually indistinguishable here anyway.
        r.x = a.x + (b.x - a.x) * t;
        r.y = a.y + (b.y - a.y) * t;
        r.z = a.z + (b.z - a.z) * t;
        r.w = a.w + (b.w - a.w) * t;
    } else {
        float theta0 = acosf(dot);
        float theta  = theta0 * t;
        float sinTheta0 = sinf(theta0);
        float s0 = cosf(theta) - dot * (sinf(theta) / sinTheta0);
        float s1 = sinf(theta) / sinTheta0;
        r.x = s0*a.x + s1*b.x;
        r.y = s0*a.y + s1*b.y;
        r.z = s0*a.z + s1*b.z;
        r.w = s0*a.w + s1*b.w;
    }
    float n = sqrtf(r.x*r.x + r.y*r.y + r.z*r.z + r.w*r.w);
    if (n > 0.0001f) { r.x/=n; r.y/=n; r.z/=n; r.w/=n; }
    return r;
}

// Steps `from` toward `to` at a constant angular speed (degrees/sec), not a
// fixed percentage of the remaining gap. Fixes two symptoms of the old
// fixed-fraction slerp in one shot: a fresh, large gap (first frame after
// acquiring a target) is capped to the exact same max-degrees-per-frame as
// every other frame — so acquisition can never produce a sudden jump/jerk —
// and a shrinking gap (converging onto a now-stationary target) keeps
// closing at that same constant rate instead of decaying into an
// imperceptible asymptotic crawl that reads as "stopped tracking".
static Quat quat_step_toward(Quat from, Quat to, float maxDegPerSec, float dt) {
    float dot = from.x*to.x + from.y*to.y + from.z*to.z + from.w*to.w;
    float dotAbs = dot < 0.0f ? -dot : dot;
    if (dotAbs > 1.0f) dotAbs = 1.0f;
    float angleDeg = 2.0f * acosf(dotAbs) * (180.0f / (float)M_PI);
    if (angleDeg < 0.0001f) return to;
    float maxStepDeg = maxDegPerSec * dt;
    float t = maxStepDeg / angleDeg;
    if (t >= 1.0f) return to;   // within one step of the target — snap exactly, no residual crawl
    return quat_slerp(from, to, t);
}

// Shared target-finding logic: enumerate PLH players, pick the closest one
// to the crosshair within FOV that's actually visible (edge-sampled around
// the selected bone), and hand back where to look and from where. Used by
// BOTH aim mechanisms below — the visual aimbot (turns the camera) and the
// silent aim (only spoofs the server, screen never moves) — so target
// selection and visibility logic stay identical between the two regardless
// of which one is doing the actual aiming.
static bool find_aim_target(void*& outCam, Vector3& outEye, Vector3& outAimPoint) {
    if (!g_resolved || !W2S || !Camera_get_main || !Tf_get_pos || !Comp_get_tf) return false;

    void* cam = Camera_get_main(NULL);
    if (!cam) return false;

    float gameW = Camera_get_pixelWidth  ? (float)Camera_get_pixelWidth(cam, NULL)  : g_scrW;
    float gameH = Camera_get_pixelHeight ? (float)Camera_get_pixelHeight(cam, NULL) : g_scrH;
    if (gameW <= 0) gameW = g_scrW;
    if (gameH <= 0) gameH = g_scrH;
    if (g_scrW <= 0 || g_scrH <= 0 || gameW <= 0 || gameH <= 0) return false;
    const float sx = g_scrW / gameW, sy = g_scrH / gameH;
    const float cxScreen = g_scrW * 0.5f, cyScreen = g_scrH * 0.5f;

    // Eye = the render camera's own transform position — the game's actual
    // view origin, no guessing needed.
    void* camTf = Comp_get_tf(cam, NULL);
    if (!safe_ptr(camTf)) return false;
    Vector3 eye = Tf_get_pos(camTf, NULL);

    std::vector<void*> players;
    enum_plh_players(players);

    int autoLocalTeam = -1;
    for (void* obj : players) {
        if (*(bool*)((char*)obj + g_pd_local)) { autoLocalTeam = *(int*)((char*)obj + g_pd_team); break; }
    }
    const int effectiveLocalTeam = (g_local_team >= 0) ? g_local_team : autoLocalTeam;

    // Multi-hitbox: try every SELECTED bone on every candidate player, and
    // pick whichever single (player, bone) pair lands closest to the
    // crosshair — not just one fixed bone per player anymore.
    void* best = NULL; float bestDist2 = 1e18f; Vector3 bestAimPoint{};
    for (void* obj : players) {
        if (*(bool*)((char*)obj + g_pd_local)) continue;
        int hp = *(int*)((char*)obj + g_pd_health);
        if (hp <= 0) continue;
        if (g_enemies_only && effectiveLocalTeam >= 0) {
            int tm = *(int*)((char*)obj + g_pd_team);
            if (tm == effectiveLocalTeam) continue;
        }

        for (int bi = 0; bi < kAllBoneCount; bi++) {
            int boneIdx = kAllBoneIndices[bi];
            if (!g_hitbox_sel[boneIdx]) continue;
            Vector3 aimPoint;
            if (!get_bone_pos(obj, boneIdx, aimPoint)) continue;

            Vector3 s = W2S(cam, aimPoint, NULL);
            if (s.z <= 0.0f) continue;
            float ux = s.x * sx, uy = g_scrH - (s.y * sy);
            float dx = ux - cxScreen, dy = uy - cyScreen;
            float d2 = dx*dx + dy*dy;
            if (d2 > g_aimbot_fov_px * g_aimbot_fov_px) continue;
            if (d2 >= bestDist2) continue;

            Vector3 finalAimPoint = aimPoint;
            if (g_aimbot_wallcheck && Physics_Raycast) {
                if (g_multipoint_on) {
                    // Aim at whatever visible edge of this hitbox is exposed
                    // (dead-center if clear, otherwise a sliver around it) —
                    // reject only if no part of it is visible at all.
                    Vector3 edgePoint;
                    if (!find_visible_point_near(eye, aimPoint, kBoneVisRadius, edgePoint)) continue;
                    finalAimPoint = edgePoint;
                } else {
                    if (!bone_is_visible(eye, aimPoint)) continue;
                }
            }

            bestDist2 = d2; best = obj; bestAimPoint = finalAimPoint;
        }
    }
    if (!best) return false;

    outCam = cam;
    outEye = eye;
    outAimPoint = bestAimPoint;
    return true;
}

static void apply_aimbot(void* controller, void* inputsPtr) {
    if (!g_aimbot_on) { g_aim_state_valid = false; g_aim_dbg_valid = false; return; }
    if (!safe_ptr(controller) || !safe_ptr(inputsPtr)) { g_aim_state_valid = false; g_aim_dbg_valid = false; return; }

    void* cam; Vector3 eye, aimPoint;
    if (!find_aim_target(cam, eye, aimPoint)) {
        // Target lost (full-lock mode only — assist mode never sets
        // g_aim_state_valid, so it never reaches here; it was already
        // tracking the real value every tick, nothing to hand back). Used to
        // ease the hand-back over a few ticks, but that read as the camera
        // still being dragged around on its own for a beat after letting go
        // — so instead just stop overriding immediately. Full lock never
        // moves the "real" value out from under itself while it's locked
        // (nothing else is dragging the camera meanwhile), so there's
        // nothing to snap back TO here — letting go is a true no-op on the
        // very next tick.
        g_aim_state_valid = false;
        g_aim_dbg_valid = false;
        return;
    }

    // Direction eye->target (NOT target->eye — this is the actual forward
    // vector the camera should end up facing). Previously this went through
    // an eye-minus-target sign trick feeding a hand-rolled pitch/yaw/atan2
    // formula into euler_to_quat_unity; replaced with quat_look_rotation
    // (see its own comment) which builds the quaternion directly from this
    // vector — no Euler axis-order/sign convention involved at all anymore.
    Vector3 forward{ aimPoint.x - eye.x, aimPoint.y - eye.y, aimPoint.z - eye.z };
    float mag = sqrtf(forward.x*forward.x + forward.y*forward.y + forward.z*forward.z);
    if (mag < 0.001f) { g_aim_state_valid = false; g_aim_dbg_valid = false; return; }

    // The field that steers the camera is a quaternion (m_qCameraRotation)
    // INSIDE the inputs struct passed to SetInputs, at offset 0x8 in OUR
    // build's own struct layout (verified directly against dump.cs — an
    // earlier attempt borrowed 0x18 from a different build and it was wrong,
    // see g_ecc_camrot_off's declaration comment). Must be written BEFORE
    // calling the original SetInputs so the game actually consumes our value
    // this frame, not after.
    Quat targetQ = quat_look_rotation(forward, Vector3{0.0f, 1.0f, 0.0f});
    Quat* cur = (Quat*)((char*)inputsPtr + g_ecc_camrot_off);
    float turnSpeed = g_aimbot_turn_speed_dps; if (turnSpeed < 10.0f) turnSpeed = 10.0f;
    const float dt = 1.0f / 60.0f;

    Quat blendFrom;
    if (g_assist_mode) {
        // Assist: blend from the REAL current value (*cur), which already
        // includes whatever the player just did manually — a small nudge
        // toward target composes with manual input on top of it, instead of
        // fighting it. No persistent state is kept in this mode at all.
        g_aim_state_valid = false;
        blendFrom = *cur;
    } else {
        // Full lock: blend from OUR OWN last output, not from *cur. *cur
        // reflects the game's real (untouched) view each tick rather than
        // what we wrote last frame, so blending from it every tick would
        // recompute the identical step from the identical baseline to the
        // identical target — the camera would turn partway toward a
        // stationary enemy and then just freeze instead of continuing to
        // close the gap. Seed from the real value only once, on
        // acquisition, then every subsequent tick genuinely advances
        // further from where we left off.
        if (!g_aim_state_valid) { g_aim_state_quat = *cur; g_aim_state_valid = true; }
        blendFrom = g_aim_state_quat;
    }

    // Constant-angular-speed step (quat_step_toward), not a fixed-fraction
    // slerp — see its own comment for why: no jerk on acquisition, no stall
    // once converged onto a stationary target.
    Quat blended = quat_step_toward(blendFrom, targetQ, turnSpeed, dt);
    if (!g_assist_mode) g_aim_state_quat = blended;
    *cur = blended;

    // m_qCameraRotation alone didn't visibly turn the camera — it likely only
    // feeds movement-relative-to-look math (what the antiaim code in the
    // reference used it for: deliberately diverging from the real view is
    // the whole point of anti-aim, which only makes sense if this field
    // ISN'T what renders). So also set the camera's own Transform rotation
    // directly — Unity renders exactly what a Camera's Transform says,
    // full stop, no indirection possible. Done here (inside the SetInputs
    // hook) since that's already proven to run every frame reliably; if the
    // camera's own look-update runs later in the frame and stomps this, the
    // effect will be inconsistent and we'll know to hook that instead.
    if (Tf_set_rotation) {
        void* camTfForSet = Comp_get_tf(cam, NULL);
        if (safe_ptr(camTfForSet)) Tf_set_rotation(camTfForSet, blended, NULL);
    }

    // Diagnostic only (see g_aim_dbg_* declaration) — lets a screenshot show
    // exactly what we computed vs what we wrote, instead of guessing again
    // if direction is still off after the quat_look_rotation switch.
    g_aim_dbg_target_euler = quat_to_euler_deg(targetQ);
    g_aim_dbg_applied_euler = quat_to_euler_deg(blended);
    g_aim_dbg_valid = true;
}

// ---------------------------------------------------------------------------
// SetInputs hook (visual aim). Keeps its real name because it's a public
// contract method of the open-source KinematicCharacterController asset
// that couldn't be safely renamed by whatever obfuscated the rest of the
// assembly. We write into the `inputs` struct's m_qCameraRotation quaternion
// at offset 0x8 (verified against our own dump's struct layout) before
// forwarding to the original, which is what actually applies our aim.
#define RVA_ECC_SETINPUTS 0x2d8f68c
typedef void (*ECC_SetInputs_t)(void*, void*, void*);
static ECC_SetInputs_t Orig_ECC_SetInputs = NULL;
static bool g_aimbot_hook_installed = false;

static void Hook_ECC_SetInputs(void* thiz, void* inputs, void* method) {
    // Modify BEFORE forwarding — the original SetInputs is what actually
    // consumes m_qCameraRotation for this frame, so our value must already
    // be in place when it runs, not written after the fact.
    apply_aimbot(thiz, inputs);
    if (Orig_ECC_SetInputs) Orig_ECC_SetInputs(thiz, inputs, method);
}

static void install_aimbot_hook() {
    if (g_aimbot_hook_installed || !g_image_base) return;
    void* target = (void*)(g_image_base + RVA_ECC_SETINPUTS);
    MSHookFunction(target, (void*)Hook_ECC_SetInputs, (void**)&Orig_ECC_SetInputs);
    g_aimbot_hook_installed = true;
}


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
    // Aimbot itself now runs from inside the SetInputs hook (installed once
    // in resolve_all), not here — see apply_aimbot's comment for why a plain
    // periodic write from this timer never survived to be used.
    maybe_triggerbot(); // main-thread only (UIKit touch injection) — this timer already runs on the main thread
}

// ---------------------------------------------------------------------------
// Config save/load — plain key=value text files in the app's own Documents
// directory (same sandbox-writable location the Loader already caches its
// downloaded dylib in). Deliberately not JSON: nothing here needs nested
// structure, and a hand-rolled key=value scanner is a few lines instead of
// pulling in a parser for something this small.
static NSString* config_dir() {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* dir = [paths.firstObject stringByAppendingPathComponent:@"BlockpostESP_configs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static std::vector<std::string> list_configs() {
    std::vector<std::string> out;
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:config_dir() error:nil];
    for (NSString* f in files) {
        if ([f.pathExtension isEqualToString:@"cfg"]) {
            out.push_back(std::string([[f stringByDeletingPathExtension] UTF8String]));
        }
    }
    std::sort(out.begin(), out.end());
    return out;
}

// Names only English letters + underscore, per spec — everything else is
// silently dropped rather than rejecting the whole input, so partial typos
// don't force a full retype.
static std::string sanitize_config_name(const char* raw) {
    std::string s;
    for (const char* p = raw; *p; p++) {
        if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || *p == '_') s += *p;
    }
    return s;
}

static bool save_config(const std::string& name) {
    if (name.empty()) return false;
    NSString* path = [config_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.cfg", name.c_str()]];
    std::ofstream f([path UTF8String]);
    if (!f.is_open()) return false;
    f << "esp_on=" << (g_esp_on?1:0) << "\n";
    f << "enemies_only=" << (g_enemies_only?1:0) << "\n";
    f << "local_team=" << g_local_team << "\n";
    f << "box_top=" << g_pd_head_off << "\n";
    f << "box_bottom=" << g_pd_feet_off << "\n";
    f << "skeleton=" << (g_skeleton_on?1:0) << "\n";
    f << "show_name=" << (g_show_name?1:0) << "\n";
    f << "show_health_bar=" << (g_show_health_bar?1:0) << "\n";
    f << "show_health_txt=" << (g_show_health_txt?1:0) << "\n";
    f << "show_armor_bar=" << (g_show_armor_bar?1:0) << "\n";
    f << "show_weapon=" << (g_show_weapon?1:0) << "\n";
    f << "aimbot_on=" << (g_aimbot_on?1:0) << "\n";
    f << "assist_mode=" << (g_assist_mode?1:0) << "\n";
    f << "aimbot_fov_px=" << g_aimbot_fov_px << "\n";
    f << "aimbot_turn_speed_dps=" << g_aimbot_turn_speed_dps << "\n";
    f << "aimbot_wallcheck=" << (g_aimbot_wallcheck?1:0) << "\n";
    f << "multipoint_on=" << (g_multipoint_on?1:0) << "\n";
    f << "multipoint_count=" << g_multipoint_count << "\n";
    {
        std::string bits;
        for (int i = 0; i < 15; i++) bits += g_hitbox_sel[i] ? '1' : '0';
        f << "hitbox_sel=" << bits << "\n";
    }
    f << "trigger_on=" << (g_trigger_on?1:0) << "\n";
    f << "trigger_radius_px=" << g_trigger_radius_px << "\n";
    f << "trigger_reaction_min_ms=" << g_trigger_reaction_min_ms << "\n";
    f << "trigger_reaction_max_ms=" << g_trigger_reaction_max_ms << "\n";
    f << "trigger_rapid_s=" << g_trigger_rapid_s << "\n";
    f << "trigger_tap_x=" << g_trigger_tap_x << "\n";
    f << "trigger_tap_y=" << g_trigger_tap_y << "\n";
    return true;
}

static bool load_config(const std::string& name) {
    if (name.empty()) return false;
    NSString* path = [config_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.cfg", name.c_str()]];
    std::ifstream f([path UTF8String]);
    if (!f.is_open()) return false;
    std::string line;
    while (std::getline(f, line)) {
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq), val = line.substr(eq + 1);
        if (val.empty()) continue;
        if (key=="esp_on") g_esp_on = (val=="1");
        else if (key=="enemies_only") g_enemies_only = (val=="1");
        else if (key=="local_team") g_local_team = atoi(val.c_str());
        else if (key=="box_top") g_pd_head_off = (float)atof(val.c_str());
        else if (key=="box_bottom") g_pd_feet_off = (float)atof(val.c_str());
        else if (key=="skeleton") g_skeleton_on = (val=="1");
        else if (key=="show_name") g_show_name = (val=="1");
        else if (key=="show_health_bar") g_show_health_bar = (val=="1");
        else if (key=="show_health_txt") g_show_health_txt = (val=="1");
        else if (key=="show_armor_bar") g_show_armor_bar = (val=="1");
        else if (key=="show_weapon") g_show_weapon = (val=="1");
        else if (key=="aimbot_on") g_aimbot_on = (val=="1");
        else if (key=="assist_mode") g_assist_mode = (val=="1");
        else if (key=="aimbot_fov_px") g_aimbot_fov_px = (float)atof(val.c_str());
        else if (key=="aimbot_turn_speed_dps") g_aimbot_turn_speed_dps = (float)atof(val.c_str());
        else if (key=="aimbot_wallcheck") g_aimbot_wallcheck = (val=="1");
        else if (key=="multipoint_on") g_multipoint_on = (val=="1");
        else if (key=="multipoint_count") g_multipoint_count = atoi(val.c_str());
        else if (key=="hitbox_sel") { for (int i=0;i<15 && i<(int)val.size();i++) g_hitbox_sel[i] = (val[i]=='1'); }
        else if (key=="trigger_on") g_trigger_on = (val=="1");
        else if (key=="trigger_radius_px") g_trigger_radius_px = (float)atof(val.c_str());
        else if (key=="trigger_reaction_min_ms") g_trigger_reaction_min_ms = (float)atof(val.c_str());
        else if (key=="trigger_reaction_max_ms") g_trigger_reaction_max_ms = (float)atof(val.c_str());
        else if (key=="trigger_rapid_s") g_trigger_rapid_s = (float)atof(val.c_str());
        else if (key=="trigger_tap_x") g_trigger_tap_x = (float)atof(val.c_str());
        else if (key=="trigger_tap_y") g_trigger_tap_y = (float)atof(val.c_str());
    }
    return true;
}

static bool remove_config(const std::string& name) {
    if (name.empty()) return false;
    NSString* path = [config_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.cfg", name.c_str()]];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:nil] ? true : false;
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
    // Was capped at 380px wide — too narrow for this content at any font
    // size, which is why labels like "Trigger radius (px)"/"Reaction min
    // (ms)" were getting clipped off the right edge, and the window couldn't
    // be resized past it to compensate. Let it go as wide as the screen.
    ImGui::SetNextWindowSizeConstraints(ImVec2(240, 0), ImVec2(screenW > 0 ? screenW - 20 : 900.0f, 9999));
    ImGui::Begin("Blockpost ESP");
    {
        ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
        rects.push_back(CGRectMake(wp.x, wp.y, ws.x, ws.y));

        if (ImGui::BeginTabBar("##tabs")) {
            if (ImGui::BeginTabItem("Visual")) {
                ImGui::Checkbox("ESP", &g_esp_on);
                ImGui::SameLine();
                ImGui::Checkbox("Enemies only", &g_enemies_only);
                ImGui::InputInt("Local team", &g_local_team);
                ImGui::SameLine(); ImGui::TextDisabled("(auto=%d, -1 uses auto)", g_auto_local_team_display);
                ImGui::SliderFloat("Box top",    &g_pd_head_off, -1.0f, 3.0f);
                ImGui::SliderFloat("Box bottom", &g_pd_feet_off, -3.0f, 1.0f);
                ImGui::SameLine();
                if (ImGui::Button("Reset##box")) { g_pd_head_off = 1.6f; g_pd_feet_off = -0.1f; }
                ImGui::Checkbox("Skeleton (real bones)", &g_skeleton_on);
                ImGui::Checkbox("Name", &g_show_name); ImGui::SameLine();
                ImGui::Checkbox("Health bar", &g_show_health_bar); ImGui::SameLine();
                ImGui::Checkbox("Health text", &g_show_health_txt);
                ImGui::Checkbox("Armor bar", &g_show_armor_bar); ImGui::SameLine();
                ImGui::Checkbox("Weapon name", &g_show_weapon);
                ImGui::EndTabItem();
            }

            if (ImGui::BeginTabItem("Combat")) {
                ImGui::SeparatorText("Aimbot");
                ImGui::Checkbox("Aimbot (visual)", &g_aimbot_on);
                ImGui::Checkbox("Assist mode", &g_assist_mode);
                ImGui::SameLine(); ImGui::TextDisabled("(nudges toward target, composes with manual aim instead of overriding it)");
                ImGui::SliderFloat("FOV (px)", &g_aimbot_fov_px, 20.0f, 600.0f);
                ImGui::SliderFloat("Turn speed (deg/s)", &g_aimbot_turn_speed_dps, 60.0f, 3000.0f);
                ImGui::SameLine(); ImGui::TextDisabled("(constant speed — never jerks, never stalls)");
                ImGui::Checkbox("Wallcheck", &g_aimbot_wallcheck);

                ImGui::SeparatorText("Multipoints");
                ImGui::Checkbox("Enabled##mp", &g_multipoint_on);
                ImGui::SameLine(); ImGui::TextDisabled("(aim at a visible edge of the hitbox, not just dead-center)");
                ImGui::SliderInt("Point count", &g_multipoint_count, 3, 12);

                ImGui::SeparatorText("Hitboxes");
                if (ImGui::Button("Select all")) { for (int i = 0; i < kAllBoneCount; i++) g_hitbox_sel[kAllBoneIndices[i]] = true; }
                ImGui::SameLine();
                if (ImGui::Button("Clear")) { for (int i = 0; i < kAllBoneCount; i++) g_hitbox_sel[kAllBoneIndices[i]] = false; }
                for (int g = 0; g < kHitboxGroupCount; g++) {
                    const HitboxGroup& grp = kHitboxGroups[g];
                    bool anySel = false;
                    for (int i = 0; i < grp.count; i++) if (g_hitbox_sel[grp.bones[i]]) anySel = true;
                    if (ImGui::Selectable(grp.name, anySel)) {
                        bool turnOn = !anySel;
                        for (int i = 0; i < grp.count; i++) g_hitbox_sel[grp.bones[i]] = turnOn;
                    }
                }

                ImGui::SeparatorText("Triggerbot");
                ImGui::Checkbox("Triggerbot", &g_trigger_on);
                ImGui::SameLine(); ImGui::TextDisabled("(independent of Aimbot — works with manual aim too)");
                ImGui::SliderFloat("Trigger radius (px)", &g_trigger_radius_px, 5.0f, 80.0f);
                ImGui::SliderFloat("Reaction min (ms)", &g_trigger_reaction_min_ms, 0.0f, 1000.0f);
                ImGui::SliderFloat("Reaction max (ms)", &g_trigger_reaction_max_ms, 0.0f, 1000.0f);
                ImGui::SameLine(); ImGui::TextDisabled("(both 0 = instant, no recheck)");
                ImGui::SliderFloat("Rapid (s between shots)", &g_trigger_rapid_s, 0.03f, 1.0f);
                ImGui::Text("pending=%d  fired=%ld", g_trigger_pending ? 1 : 0, g_trigger_fire_count);
                if (g_trigger_on) ImGui::TextDisabled("Drag the red marker on screen onto the fire button/zone.");
                ImGui::EndTabItem();
            }

            if (ImGui::BeginTabItem("Config")) {
                static char cfgName[64] = "";
                static std::vector<std::string> cfgList;
                static int cfgSel = -1;
                static std::string cfgStatus;
                static bool cfgListLoaded = false;
                if (!cfgListLoaded) { cfgList = list_configs(); cfgListLoaded = true; }

                ImGui::InputText("Name", cfgName, sizeof(cfgName));
                ImGui::SameLine(); ImGui::TextDisabled("(a-z, A-Z, _ only)");

                if (ImGui::Button("Create")) {
                    std::string clean = sanitize_config_name(cfgName);
                    if (clean.empty()) cfgStatus = "empty name";
                    else {
                        bool exists = false;
                        for (auto& c : cfgList) if (c == clean) exists = true;
                        if (exists) cfgStatus = "\"" + clean + "\" already exists — use Save to overwrite";
                        else if (save_config(clean)) { cfgList = list_configs(); cfgStatus = "created " + clean; }
                        else cfgStatus = "failed to create";
                    }
                }
                ImGui::SameLine();
                if (ImGui::Button("Save")) {
                    std::string target = (cfgSel >= 0 && cfgSel < (int)cfgList.size()) ? cfgList[cfgSel] : sanitize_config_name(cfgName);
                    if (target.empty()) cfgStatus = "no config selected/named";
                    else if (save_config(target)) { cfgList = list_configs(); cfgStatus = "saved " + target; }
                    else cfgStatus = "failed to save";
                }
                ImGui::SameLine();
                if (ImGui::Button("Load")) {
                    if (cfgSel >= 0 && cfgSel < (int)cfgList.size()) {
                        cfgStatus = load_config(cfgList[cfgSel]) ? ("loaded " + cfgList[cfgSel]) : "failed to load";
                    } else cfgStatus = "select a config first";
                }
                ImGui::SameLine();
                if (ImGui::Button("Remove")) {
                    if (cfgSel >= 0 && cfgSel < (int)cfgList.size()) {
                        std::string removed = cfgList[cfgSel];
                        if (remove_config(removed)) { cfgList = list_configs(); cfgSel = -1; cfgStatus = "removed " + removed; }
                        else cfgStatus = "failed to remove";
                    } else cfgStatus = "select a config first";
                }

                if (!cfgStatus.empty()) ImGui::TextDisabled("%s", cfgStatus.c_str());

                ImGui::SeparatorText("Saved configs");
                for (int i = 0; i < (int)cfgList.size(); i++) {
                    bool selected = (cfgSel == i);
                    if (ImGui::Selectable(cfgList[i].c_str(), selected)) {
                        cfgSel = i;
                        strncpy(cfgName, cfgList[i].c_str(), sizeof(cfgName) - 1);
                        cfgName[sizeof(cfgName) - 1] = 0;
                    }
                }
                if (cfgList.empty()) ImGui::TextDisabled("(none yet)");
                ImGui::EndTabItem();
            }

            if (ImGui::BeginTabItem("Inject")) {
                ImGui::TextColored(ImVec4(1.0f, 0.85f, 0.2f, 1.0f),
                    "Press this ONLY while you are actually IN A MATCH");
                ImGui::TextDisabled("(not the menu/lobby — player and camera objects\ndon't exist yet outside a live match, so resolving\nthere can never succeed no matter how many times\nit retries)");
                ImGui::Spacing();
                if (ImGui::Button("Inject / Resolve now", ImVec2(-1, 0))) {
                    g_want_resolve = true;
                }
                ImGui::Spacing();
                if (g_resolved) {
                    ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.4f, 1.0f), "Resolved — players seen: %d", g_plh_count);
                } else {
                    ImGui::TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "Not resolved yet");
                }
                ImGui::EndTabItem();
            }
            ImGui::EndTabBar();
        }
    }
    ImGui::End();
    } // g_menu_open

    // Publish display size for the main-thread pump, then DRAW cached boxes.
    // No il2cpp/game reads happen on this (render) thread anymore.
    g_scrW = screenW; g_scrH = screenH;
    if (g_trigger_tap_x < 0.0f && g_scrW > 0) { g_trigger_tap_x = g_scrW * 0.5f; g_trigger_tap_y = g_scrH * 0.5f; }

    // Draggable triggerbot tap-point marker — only shown while the settings
    // menu itself is open (calibrate it, close the menu, marker goes away).
    if (g_menu_open && g_trigger_on && g_scrW > 0 && g_scrH > 0) {
        ImGui::SetNextWindowPos(ImVec2(g_trigger_tap_x - 22, g_trigger_tap_y - 22), ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(44, 44), ImGuiCond_Always);
        ImGui::Begin("##triggerpoint", nullptr,
                      ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar |
                      ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoSavedSettings);
        {
            ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
            rects.push_back(CGRectMake(wp.x, wp.y, ws.x, ws.y));
            if (ImGui::IsWindowHovered() && ImGui::IsMouseDragging(ImGuiMouseButton_Left)) {
                ImVec2 dd = ImGui::GetMouseDragDelta(ImGuiMouseButton_Left);
                ImGui::ResetMouseDragDelta(ImGuiMouseButton_Left);
                wp.x += dd.x; wp.y += dd.y;
                ImGui::SetWindowPos(wp);
            }
            g_trigger_tap_x = wp.x + ws.x * 0.5f;
            g_trigger_tap_y = wp.y + ws.y * 0.5f;
            ImDrawList* dlm = ImGui::GetWindowDrawList();
            ImVec2 c(wp.x + ws.x * 0.5f, wp.y + ws.y * 0.5f);
            dlm->AddCircle(c, 18.0f, IM_COL32(255, 60, 60, 255), 24, 3.0f);
            dlm->AddLine(ImVec2(c.x - 24, c.y), ImVec2(c.x + 24, c.y), IM_COL32(255, 60, 60, 200), 2.0f);
            dlm->AddLine(ImVec2(c.x, c.y - 24), ImVec2(c.x, c.y + 24), IM_COL32(255, 60, 60, 200), 2.0f);
        }
        ImGui::End();
    }
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

    // Always-visible, self-fading "I loaded" indicator — independent of the
    // menu/gesture entirely, so a loader-delivered build can be confirmed as
    // running even if something else (gesture, resolve, network) is broken.
    // Bump BUILD_TAG per release so it's obvious a NEW dylib is what's active,
    // not a stale cached one the loader failed to replace.
    if (g_overlay_start_time > 0) {
        double elapsed = [NSDate timeIntervalSinceReferenceDate] - g_overlay_start_time;
        if (elapsed < 20.0) {
            ImDrawList* dl = ImGui::GetForegroundDrawList();
            char buf[128];
            snprintf(buf, sizeof(buf), "Blockpost ESP loaded [%s] gesture-host=%s — 3-finger double-tap for menu",
                     BUILD_TAG, g_gesture_host_found ? "game-view" : "FALLBACK(own view, may not work)");
            draw_outlined_text(dl, ImVec2(10, 10), IM_COL32(120,255,120,255), buf);
        }
    }

    // Temporary diagnostics for the aim-direction and triggerbot-fire fixes —
    // always visible (not gated on menu open) so they're screenshottable
    // during a real match. Remove once both are confirmed working on-device.
    {
        ImDrawList* dl = ImGui::GetForegroundDrawList();
        float y = 32.0f;
        if (g_aimbot_on && g_aim_dbg_valid) {
            char buf[160];
            snprintf(buf, sizeof(buf), "aim target=(p%.1f y%.1f) applied=(p%.1f y%.1f)",
                     g_aim_dbg_target_euler.x, g_aim_dbg_target_euler.y,
                     g_aim_dbg_applied_euler.x, g_aim_dbg_applied_euler.y);
            draw_outlined_text(dl, ImVec2(10, y), IM_COL32(255,220,120,255), buf);
            y += 18.0f;
        }
        if (g_trigger_on) {
            char buf[180];
            snprintf(buf, sizeof(buf), "trigger wallcheck=%d hid_ok=%d dispatched=%ld fired=%ld tap=(%.0f,%.0f)",
                     g_aimbot_wallcheck ? 1 : 0, g_hid_client_ok ? 1 : 0, g_hid_dispatch_count, g_trigger_fire_count,
                     g_hid_last_tap_x, g_hid_last_tap_y);
            draw_outlined_text(dl, ImVec2(10, y), IM_COL32(255,220,120,255), buf);
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

// ---------------------------------------------------------------------------
// iOS keyboard bridge for ImGui::InputText. There's no imgui_impl_ios here —
// only imgui_impl_metal for drawing — and touch input is fed to ImGui as
// plain mouse position/button events (see ESPView.feedTouch below), nothing
// that would ever summon the system keyboard. So tapping the Config tab's
// Name field just silently did nothing: ImGui thought it had focus, but no
// UIResponder ever asked iOS for a keyboard. Fix: a zero-size, invisible
// UITextField piggybacks — it becomes first responder (which is what
// actually raises the real keyboard) whenever ImGui itself reports a widget
// wants text input, and every keystroke is intercepted in the delegate
// before it touches the field's own (unused) text storage and is pushed
// straight into ImGui's input queue instead.
@interface ESPKeyboardBridge : NSObject <UITextFieldDelegate>
@end
@implementation ESPKeyboardBridge
- (BOOL)textField:(UITextField*)tf shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)s {
    ImGuiIO& io = ImGui::GetIO();
    if (s.length == 0 && range.length > 0) {
        io.AddKeyEvent(ImGuiKey_Backspace, true);
        io.AddKeyEvent(ImGuiKey_Backspace, false);
    } else if (s.length > 0) {
        io.AddInputCharactersUTF8(s.UTF8String);
    }
    return NO; // keep the field's own text empty — ImGui owns the actual buffer
}
@end
static UITextField*       g_kbField  = nil;
static ESPKeyboardBridge* g_kbBridge = nil;

// Polled once per frame: mirrors ImGui's notion of "a text widget is active"
// onto UIKit's actual first-responder state, which is what shows/hides the
// real keyboard.
static void sync_keyboard_bridge() {
    if (!g_kbField) return;
    bool want = ImGui::GetIO().WantTextInput;
    if (want && !g_kbField.isFirstResponder) {
        [g_kbField becomeFirstResponder];
    } else if (!want && g_kbField.isFirstResponder) {
        [g_kbField resignFirstResponder];
    }
}

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
    sync_keyboard_bridge();
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

// 3-finger double-tap toggles the menu. MUST be attached to the GAME's own
// view, not ours: UIKit's hitTest is evaluated PER TOUCH at the moment that
// touch begins, not once for the whole gesture. With 3 fingers landing a few
// milliseconds apart (never truly simultaneous), the first 1-2 touches get
// hit-tested — and committed to whichever view claims them — before the 3rd
// one even exists, so a "let 3+ finger events through to our own window"
// hitTest override only ever sees the LAST finger, never all three at once,
// and the recognizer can never satisfy numberOfTouchesRequired=3. That was
// the actual bug in the previous attempt at this. The game's own window
// naturally receives every touch already (it's what the user is touching),
// so attaching there sidesteps the whole per-touch hit-testing problem.
@interface ESPGestureTarget : NSObject
- (void)onTripleTap:(UITapGestureRecognizer*)g;
@end
@implementation ESPGestureTarget
- (void)onTripleTap:(UITapGestureRecognizer*)g { g_menu_open = !g_menu_open; }
@end
static ESPGestureTarget* g_gestureTarget = nil;

// Robust discovery of the game's own root view: UIApplication.keyWindow is
// deprecated and returned nil in exactly this app (confirmed via diagnostic
// logging), so try the modern per-scene API first, then fall back through
// keyWindow, then just the first window with a root VC.
static UIView* find_game_root_view() {
    if (@available(iOS 13.0, *)) {
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene* ws = (UIWindowScene*)scene;
            for (UIWindow* w in ws.windows) {
                if (w.isKeyWindow && w.rootViewController) return w.rootViewController.view;
            }
        }
    }
    UIWindow* kw = [UIApplication sharedApplication].keyWindow;
    if (kw.rootViewController) return kw.rootViewController.view;
    for (UIWindow* w in [UIApplication sharedApplication].windows) {
        if (w.rootViewController) return w.rootViewController.view;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// Auto Shoot: fires by simulating a real tap, NOT by calling any native fire
// function directly. The actual fire RPC (Client::send_attackv2) has the
// SAME kind of ambiguity send_pos had — 0 explicit C# params, dozens of
// same-shaped candidates in Client alone — too risky to call blind. So
// instead this synthesizes the input a real player gives to shoot: a tap.
//
// FIRST attempt at that (kept only in git history now) built a UITouch via
// private KVC keys and called touchesBegan: directly on the game's root
// UIView. That never fires here: Unity doesn't listen on the standard
// UIResponder chain of an arbitrary UIView, it reads touches off its own
// input surface, so a hand-built UITouch injected via touchesBegan: on the
// wrong view is simply never seen by the game at all.
//
// This version instead injects at the IOHID layer — the same layer the
// digitizer (touchscreen) driver itself posts real finger events on via
// IOHIDEventSystemClient — so it looks like a real hardware touch to EVERY
// app, Unity included, no view/responder-chain guessing required. This is
// the same private-but-long-stable technique used by jailbreak
// autoclicker/autotap tools for years. The struct/consts aren't in the
// public SDK headers, but the signatures below have been stable across iOS
// versions; still genuinely best-effort until confirmed on a real device —
// if it turns out to need normalized (0..1) coordinates instead of raw
// points on this iOS version, that's the first thing to try adjusting.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern "C" {
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
// Real signature per IOHIDEvent.h (IOKit private headers) — verified against
// the actual header, NOT re-derived from memory. The PREVIOUS declaration
// here had an extra bogus `uint32_t buttonMask` parameter that does not
// exist in the real function, and used `float` for x/y/z/tipPressure/twist
// where the real type (IOHIDFloat) is `double` on 64-bit (which is every
// iOS device this runs on). Both are ABI-breaking: on arm64 AAPCS64,
// integer/pointer args and float/double args are allocated into SEPARATE
// register files (GPRs vs FPRs) independently, in declaration order within
// each file. The bogus extra GPR-classified `buttonMask` argument shifted
// every GPR arg after it by one slot — so what we thought was `buttonMask=0`
// landed in the register the REAL function reads as `range`, meaning the
// real `range` was ALWAYS 0 regardless of what we intended, and our real
// `range`/`touch` values landed in the registers the real function reads as
// `touch`/`options`. A digitizer event with range=false is never treated as
// an actual finger touching the glass — this alone was enough to make
// EVERY injected tap a silent no-op, independent of the HID entitlement
// (which was already correctly present) or marker placement. The
// float-vs-double mismatch on top of that would have corrupted the
// coordinate/pressure values too. This is the actual root cause of
// "выстрел не работает от слова совсем" — confirmed by cross-referencing
// the real IOHIDEvent.h signature, not guessed.
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator,
                                                    uint64_t timeStamp,
                                                    uint32_t index,
                                                    uint32_t identity,
                                                    uint32_t eventMask,
                                                    double x, double y, double z,
                                                    double tipPressure, double twist,
                                                    int range, int touch,
                                                    uint32_t options);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
}

// kIOHIDDigitizerEventRange / kIOHIDDigitizerEventTouch — bit 0 / bit 1 of
// the digitizer eventMask, per the long-standing private IOHIDEventTypes.h.
enum { kHIDDigitizerRange = 1 << 0, kHIDDigitizerTouch = 1 << 1 };

static IOHIDEventSystemClientRef g_hidClient = NULL;
// g_hid_dispatch_count / g_hid_client_ok are declared earlier in the file
// (near g_trigger_fire_count) so render_frame can read them; defined here
// only in the sense that this is where they get WRITTEN.

static void hid_dispatch_finger(CGPoint pt, bool touching, uint32_t identity) {
    if (!g_hidClient) g_hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    g_hid_client_ok = (g_hidClient != NULL);
    if (!g_hidClient) return;

    CGRect bounds = [UIScreen mainScreen].bounds;
    double nx = (bounds.size.width  > 0) ? (double)(pt.x / bounds.size.width)  : 0.0;
    double ny = (bounds.size.height > 0) ? (double)(pt.y / bounds.size.height) : 0.0;

    IOHIDEventRef ev = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        /*index*/ 1, identity,
        (kHIDDigitizerRange | kHIDDigitizerTouch),
        nx, ny, /*z*/ 0.0, /*tipPressure*/ touching ? 1.0 : 0.0, /*twist*/ 0.0,
        /*range*/ touching ? 1 : 0, /*touch*/ touching ? 1 : 0, /*options*/ 0);
    if (!ev) return;
    IOHIDEventSystemClientDispatchEvent(g_hidClient, ev);
    g_hid_dispatch_count++;
    g_hid_last_tap_x = pt.x; g_hid_last_tap_y = pt.y;
    CFRelease(ev);
}

// `identity` is meant to uniquely track ONE continuous physical contact —
// reusing the same fixed identity (was hardcoded =2) across many rapid
// separate taps (triggerbot can fire every g_trigger_rapid_s, default
// 0.15s) risks the digitizer state machine treating a new down as a
// continuation of a not-yet-fully-released previous touch, especially with
// only a 50ms gap between our own down/up. A fresh identity per tap avoids
// that ambiguity — cheap, well-justified regardless of whether it turns out
// to be the actual reason fires aren't landing.
static void inject_tap(CGPoint point) {
    static uint32_t s_next_identity = 100;  // clear of any real-finger identity range
    uint32_t identity = s_next_identity++;
    hid_dispatch_finger(point, true, identity);
    // Release phase a beat later — a brief tap, not a held-down touch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hid_dispatch_finger(point, false, identity);
    });
}

// Triggerbot's own condition check, deliberately independent of the visual
// aimbot/assist state — works with pure manual aiming too, exactly like a
// standalone triggerbot should. Used to only test each selected bone's flat
// CENTER point — but with multipoint on, the aimbot/ESP already treat the
// hitbox as the whole sampled ring, not just its center, so a crosshair
// sitting on a visible EDGE of the hitbox (peeking a sliver of head over
// cover, say) looked "on target" visually but the trigger's own center-only
// check disagreed and never fired. Now tests every multipoint sample of the
// hitbox (via for_each_hitbox_sample_point, same ring as the aimbot uses) —
// ANY of them within g_trigger_radius_px of the crosshair counts.
//
// Wallcheck: unlike find_aim_target (aimbot), this previously had NO
// occlusion test at all — for_each_hitbox_sample_point only enumerates
// screen-space sample points, it never calls bone_is_visible itself (that's
// deliberate, see its own comment — a caller-supplied condition decides what
// "hit" means). Triggerbot's condition here didn't supply one, so it fired
// on any screen-space crosshair alignment even through walls/geometry,
// completely ignoring the Wallcheck setting that visibly sits right above
// Triggerbot in the same Combat tab. Fixed by gating each sample point on
// bone_is_visible(eye, p) too, same as the aimbot already does.
static bool crosshair_on_selected_hitbox() {
    if (!g_resolved || !W2S || !Camera_get_main || !Comp_get_tf || !Tf_get_pos) return false;
    void* cam = Camera_get_main(NULL);
    if (!cam) return false;
    float gameW = Camera_get_pixelWidth  ? (float)Camera_get_pixelWidth(cam, NULL)  : g_scrW;
    float gameH = Camera_get_pixelHeight ? (float)Camera_get_pixelHeight(cam, NULL) : g_scrH;
    if (gameW <= 0) gameW = g_scrW;
    if (gameH <= 0) gameH = g_scrH;
    if (g_scrW <= 0 || g_scrH <= 0 || gameW <= 0 || gameH <= 0) return false;
    const float sx = g_scrW / gameW, sy = g_scrH / gameH;
    const float cxScreen = g_scrW * 0.5f, cyScreen = g_scrH * 0.5f;

    void* camTf = Comp_get_tf(cam, NULL);
    if (!safe_ptr(camTf)) return false;
    Vector3 eye = Tf_get_pos(camTf, NULL);

    std::vector<void*> players;
    enum_plh_players(players);
    int autoLocalTeam = -1;
    for (void* obj : players) {
        if (*(bool*)((char*)obj + g_pd_local)) { autoLocalTeam = *(int*)((char*)obj + g_pd_team); break; }
    }
    const int effectiveLocalTeam = (g_local_team >= 0) ? g_local_team : autoLocalTeam;

    for (void* obj : players) {
        if (*(bool*)((char*)obj + g_pd_local)) continue;
        int hp = *(int*)((char*)obj + g_pd_health);
        if (hp <= 0) continue;
        if (g_enemies_only && effectiveLocalTeam >= 0) {
            int tm = *(int*)((char*)obj + g_pd_team);
            if (tm == effectiveLocalTeam) continue;
        }
        for (int bi = 0; bi < kAllBoneCount; bi++) {
            int boneIdx = kAllBoneIndices[bi];
            if (!g_hitbox_sel[boneIdx]) continue;
            Vector3 center;
            if (!get_bone_pos(obj, boneIdx, center)) continue;

            bool hit = false;
            for_each_hitbox_sample_point(eye, center, kBoneVisRadius, g_multipoint_on, [&](Vector3 p) {
                if (g_aimbot_wallcheck && !bone_is_visible(eye, p)) return false;
                Vector3 s = W2S(cam, p, NULL);
                if (s.z <= 0.0f) return false;
                float ux = s.x * sx, uy = g_scrH - (s.y * sy);
                float dx = ux - cxScreen, dy = uy - cyScreen;
                if (dx*dx + dy*dy <= g_trigger_radius_px * g_trigger_radius_px) { hit = true; return true; }
                return false;
            });
            if (hit) return true;
        }
    }
    return false;
}

static void maybe_triggerbot() {
    if (!g_trigger_on) { g_trigger_pending = false; return; }
    if (g_scrW <= 0 || g_scrH <= 0) { g_trigger_pending = false; return; }

    bool onTarget = crosshair_on_selected_hitbox();
    double now = [NSDate timeIntervalSinceReferenceDate];

    if (!onTarget) { g_trigger_pending = false; return; }

    // Rapid-fire floor: don't fire faster than this even across separate
    // acquisitions, not just within one hold.
    if (now - g_trigger_last_fire_time < g_trigger_rapid_s) return;

    CGPoint tapPoint = CGPointMake(g_trigger_tap_x, g_trigger_tap_y);

    if (!g_trigger_pending) {
        // Just acquired: arm the (possibly randomized) reaction-time wait.
        float minMs = g_trigger_reaction_min_ms;
        float maxMs = g_trigger_reaction_max_ms;
        if (maxMs < minMs) maxMs = minMs;
        float ms = minMs;
        if (maxMs > minMs) ms += (arc4random_uniform(10001) / 10000.0f) * (maxMs - minMs);
        if (ms <= 0.0f) {
            // reaction=0: fire immediately, no recheck needed — matches
            // "если делай стоит 0 можешь не проверять".
            g_trigger_last_fire_time = now;
            g_trigger_fire_count++;
            inject_tap(tapPoint);
            return;
        }
        g_trigger_pending = true;
        g_trigger_pending_until = now + (ms / 1000.0);
        return;
    }

    if (now >= g_trigger_pending_until) {
        // Reaction time elapsed AND onTarget is still true right now (the
        // early-return above already handles "no longer on target" by
        // resetting g_trigger_pending) — this IS the recheck: still on the
        // selected hitbox → shoot, otherwise this line is simply never
        // reached this tick.
        g_trigger_pending = false;
        g_trigger_last_fire_time = now;
        g_trigger_fire_count++;
        inject_tap(tapPoint);
    }
}

static ESPWindow*   g_window   = nil;
static ESPRenderer* g_renderer = nil;

static void setup_overlay() {
    g_overlay_start_time = [NSDate timeIntervalSinceReferenceDate];
    g_prev_step = read_step();   // what the last run reached before dying (if any)
    // Grab the GAME's real root view BEFORE creating our own overlay window
    // below (which becomes key-and-visible and would otherwise shadow it).
    UIView* gameRootView = find_game_root_view();

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

    g_kbBridge = [ESPKeyboardBridge new];
    g_kbField = [[UITextField alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
    g_kbField.delegate = g_kbBridge;
    g_kbField.autocorrectionType = UITextAutocorrectionTypeNo;
    g_kbField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    g_kbField.spellCheckingType = UITextSpellCheckingTypeNo;
    [mtk addSubview:g_kbField];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL;
    // Menu used to look huge AND blurry: default font baked at 13px, then
    // stretched 1.4x via FontGlobalScale (a bitmap upscale — blur, not
    // sharpness) on top of a 1.3x style scale. Bake the font at its real
    // target size instead (crisp, no upscale blur) and drop the style scale
    // back to normal — this only shrinks/sharpens the SETTINGS MENU, not the
    // in-world ESP boxes/skeleton, which are drawn separately in screen space.
    ImFontConfig fontCfg;
    fontCfg.SizePixels = 18.0f;
    io.Fonts->AddFontDefault(&fontCfg);
    io.FontGlobalScale = 1.0f;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.0f);
    ImGui::GetStyle().TouchExtraPadding = ImVec2(5.0f, 5.0f);  // finger-sized hit targets, incl. the resize grip
    ImGui_ImplMetal_Init(device);

    g_renderer = [ESPRenderer new];
    g_renderer.queue = [device newCommandQueue];
    mtk.delegate = g_renderer;
    [g_window makeKeyAndVisible];

    // Attached to the GAME's own view (found above, before our window stole
    // key-window status) so every finger of the 3-finger tap is naturally
    // hit-tested there together — see find_game_root_view's comment for why
    // this can't live on our own overlay window instead. cancelsTouchesInView
    // = NO keeps normal 1-2 finger gameplay completely unaffected.
    g_gestureTarget = [ESPGestureTarget new];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:g_gestureTarget action:@selector(onTripleTap:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    UIView* gestureHost = gameRootView ?: mtk;
    g_gesture_host_found = (gameRootView != nil);
    [gestureHost addGestureRecognizer:tap];
    NSLog(@"[BlockpostESP] gesture host = %@ (gameRootView=%@)", gestureHost, gameRootView);

    // Main-thread pump: ALL il2cpp/game reads happen here, never on the render
    // thread. Matched to the render thread's 60fps so boxes update every
    // drawn frame instead of visibly lagging behind at half rate.
    //
    // MUST be added via NSRunLoopCommonModes, NOT scheduledTimerWithTimeInterval:
    // (which only registers in NSDefaultRunLoopMode). While the player is
    // actively touching the screen — dragging to look around, moving,
    // shooting, basically all of normal gameplay — the main run loop switches
    // to UITrackingRunLoopMode for smooth touch tracking, and a Default-mode-
    // only timer simply does not fire during that. That's why resolve/boxes/
    // triggerbot all looked like they "only worked while the menu was open":
    // opening the menu is the one time the player ISN'T continuously
    // dragging, so the run loop drops back to Default mode and the timer
    // resumes. Registering the timer in Common modes makes it fire in BOTH.
    {
        NSTimer* pumpTimer = [NSTimer timerWithTimeInterval:1.0/60.0 repeats:YES
                                                       block:^(NSTimer* t) { main_pump(); }];
        [[NSRunLoop mainRunLoop] addTimer:pumpTimer forMode:NSRunLoopCommonModes];
    }
}

// ---------------------------------------------------------------------------
%ctor {
    // Bind pointers (safe) and raise the overlay first, so the menu appears
    // even if something below goes wrong. Resolve+hook-install fully
    // automatic now: a single delayed attempt used to need a manual
    // button-mash to retry whenever it landed too early (e.g. game state not
    // ready yet at t=6s) — replaced with a repeating timer that keeps
    // re-triggering resolve every 2s until g_resolved actually goes true,
    // then stops itself. No user interaction needed at all.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        bind_pointers();
        setup_overlay();
        // Same UITrackingRunLoopMode issue as the main pump timer above —
        // scheduledTimerWithTimeInterval: alone would silently stop retrying
        // resolve the moment the player starts actually playing (dragging to
        // look around). Common modes so it keeps retrying during real gameplay.
        __block NSTimer* retryTimer = nil;
        retryTimer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer* t) {
            if (g_resolved) { [t invalidate]; return; }
            g_want_resolve = true;
        }];
        [[NSRunLoop mainRunLoop] addTimer:retryTimer forMode:NSRunLoopCommonModes];
        (void)retryTimer;
    });
}
