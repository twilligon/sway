#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_shm *shm;
static struct wl_output *output_obj;
static struct zwlr_screencopy_manager_v1 *screencopy;

static struct {
    struct wl_buffer *buffer;
    void *data;
    uint32_t width, height, stride, format;
    bool done, failed;
} ss;

static int create_shm_file(size_t size) {
    char name[] = "/tmp/wl_shm-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) return -1;
    unlink(name);
    if (ftruncate(fd, size) < 0) { close(fd); return -1; }
    return fd;
}

static void handle_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame,
        uint32_t fmt, uint32_t w, uint32_t h, uint32_t stride) {
    ss.width = w; ss.height = h; ss.stride = stride; ss.format = fmt;
    size_t size = stride * h;
    int fd = create_shm_file(size);
    ss.data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    ss.buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride, fmt);
    wl_shm_pool_destroy(pool);
    close(fd);
    zwlr_screencopy_frame_v1_copy(frame, ss.buffer);
}
static void handle_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fl) {}
static void handle_ready(void *d, struct zwlr_screencopy_frame_v1 *f,
        uint32_t a, uint32_t b, uint32_t c) { ss.done = true; }
static void handle_failed(void *d, struct zwlr_screencopy_frame_v1 *f) {
    ss.failed = true; ss.done = true;
}
static void handle_damage(void *d, struct zwlr_screencopy_frame_v1 *f,
        uint32_t x, uint32_t y, uint32_t w, uint32_t h) {}
static void handle_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f,
        uint32_t fmt, uint32_t w, uint32_t h) {}
static void handle_buffer_done(void *d, struct zwlr_screencopy_frame_v1 *f) {}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = handle_buffer, .flags = handle_flags, .ready = handle_ready,
    .failed = handle_failed, .damage = handle_damage,
    .linux_dmabuf = handle_dmabuf, .buffer_done = handle_buffer_done,
};

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
        const char *iface, uint32_t ver) {
    if (!strcmp(iface, wl_shm_interface.name))
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name) && !output_obj)
        output_obj = wl_registry_bind(r, name, &wl_output_interface, 1);
    else if (!strcmp(iface, zwlr_screencopy_manager_v1_interface.name))
        screencopy = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, 3);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) {}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

int main(int argc, char *argv[]) {
    const char *outfile = argc > 1 ? argv[1] : "/dev/stdout";
    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "No display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(display);
    if (!shm || !output_obj || !screencopy) { fprintf(stderr, "Missing globals\n"); return 1; }

    struct zwlr_screencopy_frame_v1 *frame =
        zwlr_screencopy_manager_v1_capture_output(screencopy, 0, output_obj);
    zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, NULL);
    while (!ss.done) if (wl_display_dispatch(display) < 0) return 1;
    if (ss.failed) { fprintf(stderr, "Capture failed\n"); return 1; }

    // Output as PPM
    FILE *f = fopen(outfile, "wb");
    if (!f) { perror("fopen"); return 1; }
    fprintf(f, "P6\n%u %u\n255\n", ss.width, ss.height);
    for (uint32_t y = 0; y < ss.height; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)ss.data + y * ss.stride);
        for (uint32_t x = 0; x < ss.width; x++) {
            uint32_t p = row[x];
            uint8_t rgb[3] = { (p>>16)&0xFF, (p>>8)&0xFF, p&0xFF };
            fwrite(rgb, 1, 3, f);
        }
    }
    fclose(f);

    // Print center pixel info to stderr
    uint32_t cx = ss.width/2, cy = ss.height/2;
    uint32_t *crow = (uint32_t *)((uint8_t *)ss.data + cy * ss.stride);
    uint32_t cp = crow[cx];
    fprintf(stderr, "size=%ux%u center=0x%08x R=%u G=%u B=%u\n",
        ss.width, ss.height, cp, (cp>>16)&0xFF, (cp>>8)&0xFF, cp&0xFF);

    wl_display_disconnect(display);
    return 0;
}
