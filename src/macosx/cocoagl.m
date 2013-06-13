/*         ______   ___    ___ 
 *        /\  _  \ /\_ \  /\_ \ 
 *        \ \ \L\ \\//\ \ \//\ \      __     __   _ __   ___ 
 *         \ \  __ \ \ \ \  \ \ \   /'__`\ /'_ `\/\`'__\/ __`\
 *          \ \ \/\ \ \_\ \_ \_\ \_/\  __//\ \L\ \ \ \//\ \L\ \
 *           \ \_\ \_\/\____\/\____\ \____\ \____ \ \_\\ \____/
 *            \/_/\/_/\/____/\/____/\/____/\/___L\ \/_/ \/___/
 *                                           /\____/
 *                                           \_/__/
 *
 *      MacOS X quartz windowed gfx driver
 *
 *      By Angelo Mottola.
 *
 *      See readme.txt for copyright information.
 */


#include "allegro.h"
#include "allegro/internal/aintern.h"
#include "allegro/platform/aintosx.h"

#ifndef ALLEGRO_MACOSX
   #error something is wrong with the makefile
#endif

#define PREFIX_I "al-osxgl INFO: "
#define PREFIX_W "al-osxgl WARNING: "

static BITMAP *osx_gl_window_init(int, int, int, int, int);
static void gfx_cocoa_enable_acceleration(GFX_VTABLE *vtable);

static void osx_gl_window_exit(BITMAP *);

// private bitmap that is actually rendered to
BITMAP* displayed_video_bitmap;

//other vars
static AllegroWindowDelegate *osx_window_delegate = NULL;
static AllegroCocoaGLView *osx_gl_view = NULL;
static NSOpenGLContext *osx_gl_context;

#define MAX_ATTRIBUTES           64
static NSOpenGLPixelFormat *init_pixel_format(int windowed);
static void osx_gl_setup();
static void osx_gl_destroy();
static void osx_gl_create_screen_texture(int width, int height, int color_depth);
static void osx_gl_setup_arrays(int width, int height);

static GLuint osx_screen_texture = 0;


GFX_DRIVER gfx_cocoagl_window =
{
   GFX_COCOAGL_WINDOW,
   empty_string, 
   empty_string,
   "Cocoa GL window", 
   osx_gl_window_init,
   osx_gl_window_exit,
   NULL,                         /* AL_METHOD(int, scroll, (int x, int y)); */
   NULL,                         /* AL_METHOD(void, vsync, (void)); */
   NULL,                         /* AL_METHOD(void, set_palette, (AL_CONST struct RGB *p, int from, int to, int retracesync)); */
   NULL,                         /* AL_METHOD(int, request_scroll, (int x, int y)); */
   NULL,                         /* AL_METHOD(int, poll_scroll, (void)); */
   NULL,                         /* AL_METHOD(void, enable_triple_buffer, (void)); */
   NULL,                         /* AL_METHOD(struct BITMAP *, create_video_bitmap, (int width, int height)); */
   NULL,                         /* AL_METHOD(void, destroy_video_bitmap, (struct BITMAP *bitmap)); */
   NULL,                         /* AL_METHOD(int, show_video_bitmap, (BITMAP *bitmap)); */
   NULL,                         /* AL_METHOD(int, request_video_bitmap, (BITMAP *bitmap)); */
   NULL,                         /* AL_METHOD(BITMAP *, create_system_bitmap, (int width, int height)); */
   NULL,                         /* AL_METHOD(void, destroy_system_bitmap, (BITMAP *bitmap)); */
   osx_mouse_set_sprite,         /* AL_METHOD(int, set_mouse_sprite, (BITMAP *sprite, int xfocus, int yfocus)); */
   osx_mouse_show,               /* AL_METHOD(int, show_mouse, (BITMAP *bmp, int x, int y)); */
   osx_mouse_hide,               /* AL_METHOD(void, hide_mouse, (void)); */
   osx_mouse_move,               /* AL_METHOD(void, move_mouse, (int x, int y)); */
   NULL,                         /* AL_METHOD(void, drawing_mode, (void)); */
   NULL,                         /* AL_METHOD(void, save_video_state, (void)); */
   NULL,                         /* AL_METHOD(void, restore_video_state, (void)); */
   NULL,                         /* AL_METHOD(void, set_blender_mode, (int mode, int r, int g, int b, int a)); */
   NULL,                         /* AL_METHOD(int, fetch_mode_list, (void)); */
   0, 0,                         /* physical (not virtual!) screen size */
   TRUE,                         /* true if video memory is linear */
   0,                            /* bank size, in bytes */
   0,                            /* bank granularity, in bytes */
   0,                            /* video memory size, in bytes */
   0,                            /* physical address of video memory */
   TRUE                          /* true if driver runs windowed */
};

static BITMAP *osx_gl_window_init(int w, int h, int v_w, int v_h, int color_depth)
{
    NSRect rect = NSMakeRect(0, 0, w, h);
    GFX_VTABLE* vtable = _get_vtable(color_depth);

    _unix_lock_mutex(osx_event_mutex);

    if (color_depth != 8 && color_depth != 32)
        ustrzcpy(allegro_error, ALLEGRO_ERROR_SIZE, get_config_text("Unsupported color depth"));

    /* final blit will be in 32bit even in palette mode */
    if (color_depth == 8)
        color_depth = 32;

    displayed_video_bitmap = create_bitmap_ex(color_depth, w, h);

    gfx_cocoagl_window.w = w;
    gfx_cocoagl_window.h = h;
    gfx_cocoagl_window.vid_mem = w * h * BYTES_PER_PIXEL(color_depth);

    gfx_cocoa_enable_acceleration(vtable);

    // setup REAL window
	osx_window_mutex=_unix_create_mutex();
    _unix_lock_mutex(osx_window_mutex);

    osx_window = [[AllegroWindow alloc] initWithContentRect: rect
												  styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
													backing: NSBackingStoreBuffered
													  defer: NO];

    osx_window_delegate = [[[AllegroWindowDelegate alloc] init] autorelease];
    [osx_window setDelegate: (id<NSWindowDelegate>)osx_window_delegate];
    [osx_window setOneShot: YES];
    [osx_window setAcceptsMouseMovedEvents: YES];
    [osx_window setViewsNeedDisplay: NO];
    [osx_window setReleasedWhenClosed: YES];
    [osx_window center];

    set_window_title(osx_window_title);
	[osx_window makeKeyAndOrderFront: nil];

    osx_gl_view = [[AllegroCocoaGLView alloc] initWithFrame: rect];
	[osx_window setContentView: osx_gl_view];
    osx_gl_context = [[osx_gl_view openGLContext] retain];
	[osx_gl_context makeCurrentContext];

    // enable vsync
    GLint val = 1;
    [osx_gl_context setValues:&val forParameter:NSOpenGLCPSwapInterval];

    /* Print out OpenGL version info */
	TRACE(PREFIX_I "OpenGL Version: %s\n",
          (AL_CONST char*)glGetString(GL_VERSION));
	TRACE(PREFIX_I "Vendor: %s\n",
          (AL_CONST char*)glGetString(GL_VENDOR));
	TRACE(PREFIX_I "Renderer: %s\n",
          (AL_CONST char*)glGetString(GL_RENDERER));

    osx_gfx_mode = OSX_GFX_GL_WINDOW;

    osx_gl_setup();

    [osx_gl_context flushBuffer];
    [NSOpenGLContext clearCurrentContext];
    _unix_unlock_mutex(osx_window_mutex);
    _unix_unlock_mutex(osx_event_mutex);

    return displayed_video_bitmap;
}

static void osx_gl_window_exit(BITMAP *bmp)
{
    _unix_lock_mutex(osx_event_mutex);

    if (osx_window) {
        osx_gl_destroy();

        [osx_gl_context release];
        osx_gl_context = nil;
        
        [osx_gl_view release];
        osx_gl_view = nil;
        
        [osx_window close];
        osx_window = nil;
    }
    destroy_bitmap(displayed_video_bitmap);
    _unix_destroy_mutex(osx_window_mutex);
    osx_gfx_mode = OSX_GFX_NONE;

    _unix_unlock_mutex(osx_event_mutex);
}

void gfx_cocoa_enable_acceleration(GFX_VTABLE *vtable)
{  
    gfx_capabilities |= (GFX_HW_VRAM_BLIT | GFX_HW_MEM_BLIT);
}

struct MyVertex {
    GLfloat x;
    GLfloat y;
};
static struct MyVertex gl_VertexCoords[4];
static struct MyVertex gl_TextureCoords[4];

static void osx_gl_setup()
{
    glEnable(GL_CULL_FACE);
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
//    glEnable(GL_TEXTURE_2D);
//    glDisable(GL_DEPTH_TEST);
//    glDisable(GL_LIGHTING);
//    glDisable(GL_BLEND);
//    glDisable(GL_SCISSOR_TEST);
    glShadeModel(GL_FLAT);
    
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    
    glViewport(0, 0, gfx_cocoagl_window.w, gfx_cocoagl_window.h);
    glScissor(0, 0, gfx_cocoagl_window.w, gfx_cocoagl_window.h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnableClientState(GL_VERTEX_ARRAY);
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINES);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glVertexPointer(2, GL_FLOAT, sizeof(struct MyVertex), (const GLvoid*)&gl_VertexCoords[0]);
    glTexCoordPointer(2, GL_FLOAT, sizeof(struct MyVertex), (const GLvoid*)&gl_TextureCoords[0]);

	glActiveTexture(GL_TEXTURE0);

    osx_gl_create_screen_texture(gfx_cocoagl_window.w, gfx_cocoagl_window.h, 32);
    osx_gl_setup_arrays(gfx_cocoagl_window.w, gfx_cocoagl_window.h);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();

    glOrtho(0, gfx_cocoagl_window.w - 1, 0, gfx_cocoagl_window.h - 1, 0, 1);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
}

static void osx_gl_destroy()
{
    if (osx_screen_texture != 0)
    {
        glDeleteTextures(1, &osx_screen_texture);
    }
}

static void osx_gl_create_screen_texture(int width, int height, int color_depth)
{
    if (osx_screen_texture != 0)
    {
        glDeleteTextures(1, &osx_screen_texture);
    }
    
    glGenTextures(1, &osx_screen_texture);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, osx_screen_texture);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    GLuint format = GL_RGBA;
    GLuint internalFormat = GL_RGB;
    if (color_depth != 32) {
        TRACE(PREFIX_I "unsupported color depth\n");
    }
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, internalFormat, width, height, 0, format, GL_UNSIGNED_BYTE, NULL);
}

static void osx_gl_setup_arrays(int width, int height)
{
    gl_VertexCoords[0].x = 0;
    gl_VertexCoords[0].y = 0;
    gl_TextureCoords[0].x = 0;
    gl_TextureCoords[0].y = height;

    gl_VertexCoords[1].x = width;
    gl_VertexCoords[1].y = 0;
    gl_TextureCoords[1].x = width;
    gl_TextureCoords[1].y = height;

    gl_VertexCoords[2].x = 0;
    gl_VertexCoords[2].y = height;
    gl_TextureCoords[2].x = 0;
    gl_TextureCoords[2].y = 0;
    
    gl_VertexCoords[3].x = width;
    gl_VertexCoords[3].y = height;
    gl_TextureCoords[3].x = width;
    gl_TextureCoords[3].y = 0;
}

void osx_gl_render()
{
    _unix_lock_mutex(osx_window_mutex);
    [osx_gl_context makeCurrentContext];
    glTexSubImage2D(GL_TEXTURE_RECTANGLE_EXT, 0,
                    0, 0, gfx_cocoagl_window.w, gfx_cocoagl_window.h,
                    GL_RGBA, GL_UNSIGNED_BYTE, displayed_video_bitmap->line[0]);
    
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glFinish();
    [osx_gl_context flushBuffer];
    [NSOpenGLContext clearCurrentContext];
    _unix_unlock_mutex(osx_window_mutex);
}

/* NSOpenGLPixelFormat *init_pixel_format(int windowed)
 *
 * Generate a pixel format. First try and get all the 'suggested' settings.
 * If this fails, just get the 'required' settings,
 * or nil if no format can be found
 */
static NSOpenGLPixelFormat *init_pixel_format(int windowed)
{
    NSOpenGLPixelFormatAttribute attribs[MAX_ATTRIBUTES], *attrib;
	attrib=attribs;
//    *attrib++ = NSOpenGLPFADoubleBuffer;

    /* Always request one of fullscreen or windowed */
	if (windowed) {
		*attrib++ = NSOpenGLPFAWindow;
		*attrib++ = NSOpenGLPFABackingStore;
	} else {
		*attrib++ = NSOpenGLPFAFullScreen;
		*attrib++ = NSOpenGLPFAScreenMask;
		*attrib++ = CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay);
	}
    *attrib++ = NSOpenGLPFAAccelerated;
	*attrib = 0;

	NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes: attribs];

	return pf;
}

@implementation AllegroCocoaGLView

- (void)resetCursorRects
{
    [super resetCursorRects];
    [self addCursorRect: NSMakeRect(0, 0, gfx_cocoagl_window.w, gfx_cocoagl_window.h)
                 cursor: osx_cursor];
    [osx_cursor setOnMouseEntered: YES];
}
/* Custom view: when created, select a suitable pixel format */
- (id) initWithFrame: (NSRect) frame
{
	NSOpenGLPixelFormat* pf = init_pixel_format(TRUE);
	if (pf) {
        self = [super initWithFrame:frame pixelFormat: pf];
        [pf release];
        return self;
	}
	else
	{
        TRACE(PREFIX_W "Unable to find suitable pixel format\n");
	}
	return nil;
}
@end