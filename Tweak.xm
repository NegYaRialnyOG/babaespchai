#include <substrate.h>
#include <mach-o/dyld.h>
#include <CoreGraphics/CoreGraphics.h>

struct Vector3 { float x, y, z; };
struct Vector2 { float x, y; };
struct Rect { float x, y, width, height; };

typedef Vector2 (*WorldToScreenPoint_t)(void* camera, Vector3 worldPoint);
typedef void* (*Camera_get_main_t)();

WorldToScreenPoint_t WorldToScreenPoint = NULL;
Camera_get_main_t Camera_get_main = NULL;

void (*orig_Player_OnGUI)(void* player_instance);

void hk_Player_OnGUI(void* player_instance) {
    orig_Player_OnGUI(player_instance);
    if (!player_instance) return;
    
    void* main_camera = Camera_get_main ? Camera_get_main() : NULL;
    if (!main_camera) return;

    Vector3 target_world_pos = *(Vector3*)((uintptr_t)player_instance + 0x24);
    Vector2 screen_pos = WorldToScreenPoint(main_camera, target_world_pos);

    float screen_height = [UIScreen mainScreen].bounds.size.height;
    float screen_width = [UIScreen mainScreen].bounds.size.width;
    float screenY = screen_height - screen_pos.y;

    if (screen_pos.x > 0 && screen_pos.x < screen_width && screenY > 0 && screenY < screen_height) {
        // 2D Box ESP Logic
    }
}

%ctor {
    uintptr_t base = _dyld_get_image_vmaddr_slide(0);
    WorldToScreenPoint = (WorldToScreenPoint_t)(base + 0x3410F44);
    uintptr_t player_ongui_addr = base + 0x166953C;
    MSHookFunction((void *)player_ongui_addr, (void *)&hk_Player_OnGUI, (void **)&orig_Player_OnGUI);
}
