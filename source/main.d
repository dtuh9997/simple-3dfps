/*******************************************************************************
 * mini3dfps.d -- 用 D 语言写的极简 3D 第一人称射击小游戏
 *
 * 平台 : Linux / FreeBSD / macOS (GLFW 3.2+ / OpenGL 3.3 core)
 * 依赖 : bindbc-glfw, bindbc-opengl (由 dub 自动拉取)
 * 编译 : dub build --build=release      运行: dub run
 *
 * 操作:
 *   WASD 移动   空格 跳跃   Shift 疾跑   鼠标 瞄准   左键 射击
 *   R 换弹   1-6 切换已拥有的武器   B 打开/关闭购买菜单   ESC 暂停/释放鼠标
 *
 * 武器(6 把, 玩家和机器人共用同一套参数):
 *   0 栓动步枪 BOLT    伤害 95  间隔 1.45s  弹匣 5   半自动  初始武器
 *   1 手枪     PISTOL  伤害 35  间隔 0.28s  弹匣 12  半自动  $200
 *   2 冲锋枪   SMG     伤害 22  间隔 0.085s 弹匣 30  全自动  $100
 *   3 半自动步枪 SEMI  伤害 42  间隔 0.30s  弹匣 20  半自动  $800
 *   4 突击步枪 AR      伤害 30  间隔 0.105s 弹匣 30  全自动  $1200
 *   5 战斗霰弹枪 SHOTGUN 伤害 17x8 间隔 0.85s 弹匣 6  半自动  $600
 *
 * 规则:
 *   100x100 地图, 每局随机生成掩体; 场上始终 7 名机器人(被淘汰后重生, 重生时换枪)
 *   机器人按自己手里的枪决定交战距离、点射长度、射速和后坐, 同样分半自动/全自动
 *   淘汰一名玩家 +$300(基础) + 连杀奖励; 淘汰 50 人后任务完成
 ******************************************************************************/
module main;

import std.stdio : writeln, writefln;
import std.math;
import std.random;
import std.format : format;
import std.string : toStringz;
import std.algorithm : clamp, min, max;

import bindbc.glfw;
import bindbc.opengl;

//==============================================================================
// 常量
//==============================================================================
enum float PI_F       = 3.14159265358979f;
enum float MAP_HALF   = 50.0f;    // 地图 100x100 => [-50, 50]
enum int   BOT_COUNT  = 7;
enum int   WPN_COUNT  = 6;        // 武器总数
enum int   KILL_TARGET = 50;
enum int   MONEY_PER_KILL = 300;
enum float GRAVITY    = 24.0f;
enum float EYE_H      = 1.62f;    // 眼高(相对脚底)
enum float P_RADIUS   = 0.38f;
enum float P_HEIGHT   = 1.80f;
enum float JUMP_SPEED = 7.2f;
enum float WALK_SPEED = 5.6f;
enum float RUN_SPEED  = 8.4f;
enum float MOUSE_SENS = 0.0022f;   // 默认灵敏度(每像素转多少弧度)
enum float VIEW_FOV   = 78.0f;

// ---- 鼠标设置(可在游戏里改, 也可用命令行参数改) ----
__gshared float sensX    = MOUSE_SENS;   // 水平灵敏度
__gshared float sensY    = MOUSE_SENS;   // 垂直灵敏度
__gshared bool  invertX  = false;        // 反转左右
__gshared bool  invertY  = false;        // 反转上下(部分玩家的习惯)

//==============================================================================
// 数学
//==============================================================================
struct Vec3
{
    float x = 0, y = 0, z = 0;
    this(float x, float y, float z) { this.x = x; this.y = y; this.z = z; }
    Vec3 opBinary(string op : "+")(Vec3 o) const { return Vec3(x + o.x, y + o.y, z + o.z); }
    Vec3 opBinary(string op : "-")(Vec3 o) const { return Vec3(x - o.x, y - o.y, z - o.z); }
    Vec3 opBinary(string op : "*")(float s) const { return Vec3(x * s, y * s, z * s); }
    void opOpAssign(string op : "+")(Vec3 o) { x += o.x; y += o.y; z += o.z; }
    void opOpAssign(string op : "-")(Vec3 o) { x -= o.x; y -= o.y; z -= o.z; }
    void opOpAssign(string op : "*")(float s) { x *= s; y *= s; z *= s; }
}

float dot(Vec3 a, Vec3 b)   { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3  cross(Vec3 a, Vec3 b) { return Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
float len(Vec3 a)           { return sqrt(dot(a, a)); }
Vec3  norm(Vec3 a)          { float l = len(a); return (l > 1e-6f) ? a * (1.0f / l) : Vec3(0, 0, 0); }
float dist(Vec3 a, Vec3 b)  { float dx = a.x-b.x, dy = a.y-b.y, dz = a.z-b.z; return sqrt(dx*dx + dy*dy + dz*dz); }
float radians(float d)      { return d * PI_F / 180.0f; }
float lerp(float a, float b, float t) { return a + (b - a) * t; }

/// 由 yaw/pitch 得到朝向向量 (yaw=0 时朝 -Z)
Vec3 dirFrom(float yaw, float pitch)
{
    float cp = cos(pitch);
    return Vec3(sin(yaw) * cp, sin(pitch), -cos(yaw) * cp);
}

struct Mat4 { float[16] m = 0.0f; }

Mat4 matIdentity()
{
    Mat4 r;
    r.m[0] = 1.0f; r.m[5] = 1.0f; r.m[10] = 1.0f; r.m[15] = 1.0f;
    return r;
}

Mat4 mul(const Mat4 a, const Mat4 b)
{
    Mat4 r;
    for (int c = 0; c < 4; c++)
        for (int w = 0; w < 4; w++)
        {
            float s = 0.0f;
            for (int k = 0; k < 4; k++) s += a.m[k * 4 + w] * b.m[c * 4 + k];
            r.m[c * 4 + w] = s;
        }
    return r;
}

Mat4 perspective(float fovy, float aspect, float near, float far)
{
    Mat4 r;
    float f = 1.0f / tan(fovy * 0.5f);
    r.m[0]  = f / aspect;
    r.m[5]  = f;
    r.m[10] = (far + near) / (near - far);
    r.m[11] = -1.0f;
    r.m[14] = (2.0f * far * near) / (near - far);
    return r;
}

Mat4 ortho2D(float w, float h)   // 屏幕像素坐标, 左上为原点
{
    Mat4 r = matIdentity();
    r.m[0]  =  2.0f / w;
    r.m[5]  = -2.0f / h;
    r.m[12] = -1.0f;
    r.m[13] =  1.0f;
    return r;
}

Mat4 translate(Vec3 t)
{
    Mat4 r = matIdentity();
    r.m[12] = t.x; r.m[13] = t.y; r.m[14] = t.z;
    return r;
}

Mat4 scale(Vec3 s)
{
    Mat4 r = matIdentity();
    r.m[0] = s.x; r.m[5] = s.y; r.m[10] = s.z;
    return r;
}

Mat4 rotY(float a)
{
    Mat4 r = matIdentity();
    float c = cos(a), s = sin(a);
    r.m[0] = c;  r.m[2] = -s;
    r.m[8] = s;  r.m[10] = c;
    return r;
}

Mat4 lookAt(Vec3 eye, Vec3 center, Vec3 up)
{
    Vec3 f = norm(center - eye);
    Vec3 s = norm(cross(f, up));
    Vec3 u = cross(s, f);
    Mat4 r = matIdentity();
    r.m[0] = s.x;  r.m[4] = s.y;  r.m[8]  = s.z;
    r.m[1] = u.x;  r.m[5] = u.y;  r.m[9]  = u.z;
    r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z;
    r.m[12] = -dot(s, eye); r.m[13] = -dot(u, eye); r.m[14] = dot(f, eye);
    return r;
}

/// 由三个正交基 + 位置构造模型矩阵(列 0=right, 1=up, 2=forward)
Mat4 basis(Vec3 right, Vec3 up, Vec3 fwd, Vec3 pos)
{
    Mat4 r = matIdentity();
    r.m[0] = right.x; r.m[1] = right.y; r.m[2] = right.z;
    r.m[4] = up.x;    r.m[5] = up.y;    r.m[6] = up.z;
    r.m[8] = fwd.x;   r.m[9] = fwd.y;   r.m[10] = fwd.z;
    r.m[12] = pos.x;  r.m[13] = pos.y;  r.m[14] = pos.z;
    return r;
}

//==============================================================================
// AABB / 射线
//==============================================================================
struct Box { Vec3 c; Vec3 h; }   // 中心 + 半尺寸

bool boxOverlap(Box a, Box b)
{
    return (fabs(a.c.x - b.c.x) < (a.h.x + b.h.x)) &&
           (fabs(a.c.y - b.c.y) < (a.h.y + b.h.y)) &&
           (fabs(a.c.z - b.c.z) < (a.h.z + b.h.z));
}

/// slab 法射线与 AABB 求交, 命中返回 true 并写入 t
bool rayBox(Vec3 ro, Vec3 rd, Box b, out float tHit)
{
    tHit = 0.0f;
    float t0 = 0.0f, t1 = 1e30f;
    float[3] o  = [ro.x, ro.y, ro.z];
    float[3] d  = [rd.x, rd.y, rd.z];
    float[3] lo = [b.c.x - b.h.x, b.c.y - b.h.y, b.c.z - b.h.z];
    float[3] hi = [b.c.x + b.h.x, b.c.y + b.h.y, b.c.z + b.h.z];
    for (int i = 0; i < 3; i++)
    {
        if (fabs(d[i]) < 1e-8f)
        {
            if (o[i] < lo[i] || o[i] > hi[i]) return false;
        }
        else
        {
            float inv = 1.0f / d[i];
            float ta = (lo[i] - o[i]) * inv;
            float tb = (hi[i] - o[i]) * inv;
            if (ta > tb) { float tmp = ta; ta = tb; tb = tmp; }
            if (ta > t0) t0 = ta;
            if (tb < t1) t1 = tb;
            if (t0 > t1) return false;
        }
    }
    tHit = t0;
    return true;
}

//==============================================================================
// 游戏数据
//==============================================================================
struct WeaponDef
{
    string name;
    string tag;
    float  damage;
    float  fireInterval;  // 两发之间的最小间隔(秒)
    int    magSize;
    float  reloadTime;
    bool   fullAuto;      // true = 按住连发, false = 点一次打一发
    int    price;
    int    pellets;       // 每次击发几颗弹丸 (霰弹枪 > 1)
    float  pelletSpread;  // 弹丸散布(弧度)
    Vec3   vmColor;
    Vec3   vmSize;
    float  spread;        // 准心扩散(弧度)
    float  recoil;        // 每次射击抬枪
    float  botSpread;     // 机器人用这把枪时的额外散布(手感平衡)
    int    botBurstMin;   // 机器人打全自动时的点射长度
    int    botBurstMax;
}

__gshared WeaponDef[WPN_COUNT] WEAPONS;

// 索引: 0 栓动(初始) 1 手枪 2 冲锋枪 3 半自动步枪 4 突击步枪 5 霰弹枪
enum int W_BOLT = 0, W_PISTOL = 1, W_SMG = 2, W_SEMI = 3, W_AR = 4, W_SHOTGUN = 5;

void initWeapons()
{
    //                         名称                   简称      伤害  间隔   弹匣 换弹  全自动 价格  弹丸 弹丸散布
    WEAPONS[W_BOLT] = WeaponDef("BOLT-ACTION RIFLE", "BOLT",   95.0f, 1.45f,  5, 3.20f, false,    0, 1, 0.0f,
                                Vec3(0.34f, 0.24f, 0.14f), Vec3(0.07f, 0.07f, 1.05f), 0.0015f, 0.055f, 0.030f, 1, 1);
    WEAPONS[W_PISTOL] = WeaponDef("PISTOL",          "PISTOL", 35.0f, 0.28f, 12, 1.60f, false,  200, 1, 0.0f,
                                Vec3(0.20f, 0.20f, 0.24f), Vec3(0.06f, 0.09f, 0.36f), 0.0100f, 0.024f, 0.045f, 1, 2);
    WEAPONS[W_SMG] = WeaponDef("SUBMACHINE GUN",     "SMG",    22.0f, 0.085f, 30, 1.90f, true,   100, 1, 0.0f,
                                Vec3(0.16f, 0.17f, 0.19f), Vec3(0.09f, 0.14f, 0.62f), 0.0140f, 0.011f, 0.055f, 4, 9);
    WEAPONS[W_SEMI] = WeaponDef("SEMI-AUTO RIFLE",   "SEMI",   42.0f, 0.30f, 20, 2.30f, false,  800, 1, 0.0f,
                                Vec3(0.22f, 0.26f, 0.30f), Vec3(0.08f, 0.10f, 0.95f), 0.0060f, 0.022f, 0.032f, 1, 3);
    WEAPONS[W_AR] = WeaponDef("ASSAULT RIFLE",       "AR",     30.0f, 0.105f, 30, 2.40f, true,  1200, 1, 0.0f,
                                Vec3(0.18f, 0.22f, 0.28f), Vec3(0.08f, 0.11f, 0.88f), 0.0090f, 0.018f, 0.038f, 3, 7);
    WEAPONS[W_SHOTGUN] = WeaponDef("COMBAT SHOTGUN", "SHOTGUN",17.0f, 0.85f,  6, 3.00f, false,  600, 8, 0.055f,
                                Vec3(0.28f, 0.20f, 0.16f), Vec3(0.09f, 0.10f, 0.74f), 0.0040f, 0.070f, 0.010f, 1, 1);
}

struct Player
{
    Vec3  pos;          // 脚底位置
    float vy = 0.0f;
    float yaw = 0.0f, pitch = 0.0f;
    bool  onGround = true;
    float hp = 100.0f;
    int   money = 0;
    int   kills = 0;
    int   streak = 0;
    int   weapon = 0;
    bool[WPN_COUNT] owned;
    int[WPN_COUNT]  mag;
    float fireTimer = 0.0f;
    float reloadTimer = 0.0f;
    float boltTimer = 0.0f;   // 栓动拉栓动画计时
    float bobT = 0.0f;
    float bobAmt = 0.0f;
    float viewKick = 0.0f;
}

struct Bot
{
    int   id;
    Vec3  pos;
    float vy = 0.0f;
    float yaw = 0.0f;
    float hp = 100.0f;
    bool  alive = true;
    float fireTimer = 0.0f;      // 下一发的冷却
    float reloadTimer = 0.0f;    // 换弹计时
    float respawnTimer = 0.0f;
    float stuckTimer = 0.0f;
    float hitFlash = 0.0f;
    float thinkTimer = 0.0f;
    int   state = 0;             // 0=游荡 1=交战
    int   weapon = 0;            // 机器人手里的武器
    int   mag = 0;               // 当前弹匣余弹
    int   burstLeft = 0;         // 全自动点射剩余发数
    Vec3  wander;
    Vec3  lastPos;
}

struct Tracer { Vec3 a, b; float life; }
struct Feed   { string text; float life; }

enum GState { playing, dead, won, paused }

__gshared Player  player;
__gshared Bot[BOT_COUNT] bots;
__gshared Box[]   covers;
__gshared Tracer[] tracers;
__gshared Feed[]  feeds;
__gshared GState  gstate = GState.playing;
__gshared bool    shopOpen = false;
__gshared float   hitMarkTimer = 0.0f;
__gshared bool    hitMarkKill = false;
__gshared float   hurtTimer = 0.0f;
__gshared float   muzzleTimer = 0.0f;
__gshared float   msgTimer = 0.0f;
__gshared string  shopMsg = "";
__gshared float   gameTime = 0.0f;
__gshared float   fps = 60.0f;

//==============================================================================
// 输入 (由 GLFW 回调写入, 因此必须是 __gshared / 静态数组)
//==============================================================================
__gshared bool[512] keys;
__gshared bool[512] keyHit;
__gshared bool mouseDown = false;
__gshared bool mousePressed = false;
__gshared double lastMX = 0, lastMY = 0;
__gshared double accDX = 0, accDY = 0;
__gshared bool   cursorReady = false;
__gshared int    fbW = 1280, fbH = 720;
__gshared GLFWwindow* window;

extern(C) void keyCB(GLFWwindow* w, int key, int sc, int action, int mods) nothrow
{
    if (key < 0 || key >= 512) return;
    if (action == GLFW_PRESS)   { keys[key] = true;  keyHit[key] = true;  }
    if (action == GLFW_RELEASE) { keys[key] = false; }
}

extern(C) void mouseBtnCB(GLFWwindow* w, int button, int action, int mods) nothrow
{
    if (button != GLFW_MOUSE_BUTTON_LEFT) return;
    if (action == GLFW_PRESS)   { mouseDown = true;  mousePressed = true; }
    if (action == GLFW_RELEASE) { mouseDown = false; }
}

extern(C) void cursorCB(GLFWwindow* w, double x, double y) nothrow
{
    if (!cursorReady) { lastMX = x; lastMY = y; cursorReady = true; return; }
    accDX += x - lastMX;
    accDY += y - lastMY;
    lastMX = x; lastMY = y;
}

extern(C) void fbSizeCB(GLFWwindow* w, int width, int height) nothrow
{
    fbW = width; fbH = height;
}

/// 切换鼠标捕获。重新捕获时必须丢弃这一次的光标 delta,
/// 否则 GLFW 把光标拉回中心会产生一个巨大的位移, 视角瞬间甩飞。
void setCursorCaptured(bool captured)
{
    accDX = 0.0; accDY = 0.0;
    cursorReady = false;
    if (window !is null)
        glfwSetInputMode(window, GLFW_CURSOR,
                         captured ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
}

//==============================================================================
// OpenGL 资源
//==============================================================================
__gshared GLuint progMain, progFlat;
__gshared GLuint boxVAO, boxVBO;
__gshared GLuint flatVAO, flatVBO;      // 用于 HUD 与曳光线
__gshared GLint  m_locMVP, m_locModel, m_locColor, m_locLight, m_locCam, m_locAmb, m_locGrid;
__gshared GLint  f_locMVP, f_locColor;
__gshared float[] hudVerts;   // 每顶点: x, y, z, r, g, b, a  (7 float)
__gshared float[] lineVerts;

immutable string VS_MAIN = `
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
uniform mat4 uMVP;
uniform mat4 uModel;
out vec3 vNormal;
out vec3 vWorld;
void main()
{
    gl_Position = uMVP * vec4(aPos, 1.0);
    vNormal = mat3(uModel) * aNormal;
    vWorld  = (uModel * vec4(aPos, 1.0)).xyz;
}
`;

immutable string FS_MAIN = `
#version 330 core
in vec3 vNormal;
in vec3 vWorld;
uniform vec3  uColor;
uniform vec3  uLightDir;
uniform vec3  uCamPos;
uniform float uAmbient;
uniform float uGrid;
out vec4 fragColor;
void main()
{
    vec3 n = normalize(vNormal);
    float d = max(dot(n, normalize(uLightDir)), 0.0);
    vec3 c = uColor * (uAmbient + 0.80 * d);
    c += uColor * 0.18 * max(dot(n, normalize(vec3(-0.4, 0.6, 0.7))), 0.0);
    if (uGrid > 0.5)
    {
        vec2 g = abs(fract(vWorld.xz * 0.25) - 0.5);
        float line = 1.0 - smoothstep(0.42, 0.5, max(g.x, g.y));
        c = mix(c, vec3(0.30, 0.36, 0.30), line * 0.55);
    }
    float dist = length(vWorld - uCamPos);
    float fog = clamp((dist - 28.0) / 78.0, 0.0, 0.82);
    c = mix(c, vec3(0.62, 0.72, 0.82), fog);
    fragColor = vec4(c, 1.0);
}
`;

immutable string VS_FLAT = `
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aColor;
uniform mat4 uMVP;
out vec4 vColor;
void main()
{
    gl_Position = uMVP * vec4(aPos, 1.0);
    vColor = aColor;
}
`;

immutable string FS_FLAT = `
#version 330 core
in vec4 vColor;
out vec4 fragColor;
void main() { fragColor = vColor; }
`;

GLuint compileShader(GLenum type, string src)
{
    GLuint s = glCreateShader(type);
    const(char)* p = src.toStringz;
    glShaderSource(s, 1, &p, null);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok)
    {
        char[1024] log;
        GLsizei n = 0;
        glGetShaderInfoLog(s, cast(int) log.length, &n, log.ptr);
        writeln("[shader] ", log[0 .. (n > 0 ? n : 0)]);
    }
    return s;
}

GLuint makeProgram(string vs, string fs)
{
    GLuint v = compileShader(GL_VERTEX_SHADER, vs);
    GLuint f = compileShader(GL_FRAGMENT_SHADER, fs);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok)
    {
        char[1024] log;
        GLsizei n = 0;
        glGetProgramInfoLog(p, cast(int) log.length, &n, log.ptr);
        writeln("[program] ", log[0 .. (n > 0 ? n : 0)]);
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return p;
}

/// 生成单位立方体(中心原点, 边长 1), 36 个顶点: pos(3) + normal(3)
void buildBoxMesh()
{
    float[3][6] fn = [
        [ 1.0f, 0.0f, 0.0f], [-1.0f, 0.0f, 0.0f], [0.0f, 1.0f, 0.0f],
        [0.0f,-1.0f, 0.0f], [0.0f, 0.0f, 1.0f], [0.0f, 0.0f,-1.0f]
    ];
    float[3][6] fu = [
        [ 0.0f, 0.0f,-1.0f], [ 0.0f, 0.0f, 1.0f], [1.0f, 0.0f, 0.0f],
        [1.0f, 0.0f, 0.0f], [1.0f, 0.0f, 0.0f], [-1.0f, 0.0f, 0.0f]
    ];
    float[3][6] fv = [
        [ 0.0f, 1.0f, 0.0f], [ 0.0f, 1.0f, 0.0f], [0.0f, 0.0f,-1.0f],
        [0.0f, 0.0f, 1.0f], [0.0f, 1.0f, 0.0f], [ 0.0f, 1.0f, 0.0f]
    ];

    float[] data;
    for (int f = 0; f < 6; f++)
    {
        Vec3 n = Vec3(fn[f][0], fn[f][1], fn[f][2]);
        Vec3 u = Vec3(fu[f][0], fu[f][1], fu[f][2]) * 0.5f;
        Vec3 v = Vec3(fv[f][0], fv[f][1], fv[f][2]) * 0.5f;
        Vec3 p0 = u * (-1.0f) - v;   // -u -v
        Vec3 p1 = u - v;             //  u -v
        Vec3 p2 = u + v;             //  u +v
        Vec3 p3 = u * (-1.0f) + v;   // -u +v
        Vec3[4] quad = [p0, p1, p2, p3];
        int[6] idx = [0, 1, 2, 0, 2, 3];
        for (int i = 0; i < 6; i++)
        {
            Vec3 p = quad[idx[i]];
            data ~= [p.x, p.y, p.z, n.x, n.y, n.z];
        }
    }

    glGenVertexArrays(1, &boxVAO);
    glGenBuffers(1, &boxVBO);
    glBindVertexArray(boxVAO);
    glBindBuffer(GL_ARRAY_BUFFER, boxVBO);
    glBufferData(GL_ARRAY_BUFFER, cast(GLsizeiptr)(data.length * float.sizeof), data.ptr, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * cast(int) float.sizeof, cast(void*) 0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * cast(int) float.sizeof, cast(void*)(3 * float.sizeof));
    glBindVertexArray(0);
}

void buildFlatBuffers()
{
    glGenVertexArrays(1, &flatVAO);
    glGenBuffers(1, &flatVBO);
    glBindVertexArray(flatVAO);
    glBindBuffer(GL_ARRAY_BUFFER, flatVBO);
    glBufferData(GL_ARRAY_BUFFER, 64 * 1024, null, GL_DYNAMIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 7 * cast(int) float.sizeof, cast(void*) 0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 7 * cast(int) float.sizeof, cast(void*)(3 * float.sizeof));
    glBindVertexArray(0);
}

//==============================================================================
// 绘制辅助
//==============================================================================
__gshared Mat4 gVP;

void drawBoxModel(Mat4 model, Vec3 color, float grid = 0.0f)
{
    Mat4 mvp = mul(gVP, model);
    glUniformMatrix4fv(m_locMVP, 1, GL_FALSE, mvp.m.ptr);
    glUniformMatrix4fv(m_locModel, 1, GL_FALSE, model.m.ptr);
    glUniform3f(m_locColor, color.x, color.y, color.z);
    glUniform1f(m_locGrid, grid);
    glBindVertexArray(boxVAO);
    glDrawArrays(GL_TRIANGLES, 0, 36);
}

/// 轴对齐盒: center 为中心, size 为整体尺寸
void drawBox(Vec3 center, Vec3 size, Vec3 color, float grid = 0.0f)
{
    drawBoxModel(mul(translate(center), scale(size)), color, grid);
}

/// 绕 Y 旋转的盒
void drawBoxRot(Vec3 center, Vec3 size, float yaw, Vec3 color)
{
    drawBoxModel(mul(mul(translate(center), rotY(yaw)), scale(size)), color);
}

//------------------------------------------------------------------------------
// 顶点批处理 (HUD / 曳光线)
//------------------------------------------------------------------------------
void pushVert(ref float[] arr, float x, float y, float z, float r, float g, float b, float a)
{
    arr ~= x; arr ~= y; arr ~= z; arr ~= r; arr ~= g; arr ~= b; arr ~= a;
}

void rect2D(ref float[] arr, float x, float y, float w, float h,
            float r, float g, float b, float a)
{
    // 两个三角形, 屏幕坐标 y 向下
    pushVert(arr, x,     y,     0, r, g, b, a);
    pushVert(arr, x,     y + h, 0, r, g, b, a);
    pushVert(arr, x + w, y + h, 0, r, g, b, a);
    pushVert(arr, x,     y,     0, r, g, b, a);
    pushVert(arr, x + w, y + h, 0, r, g, b, a);
    pushVert(arr, x + w, y,     0, r, g, b, a);
}

void rectBorder(ref float[] arr, float x, float y, float w, float h, float th,
                float r, float g, float b, float a)
{
    rect2D(arr, x, y, w, th, r, g, b, a);
    rect2D(arr, x, y + h - th, w, th, r, g, b, a);
    rect2D(arr, x, y, th, h, r, g, b, a);
    rect2D(arr, x + w - th, y, th, h, r, g, b, a);
}

//==============================================================================
// 5x7 点阵字体 (自绘, 无需外部字体文件)
//==============================================================================
ubyte[7] glyphOf(char c)
{
    switch (c)
    {
        case 'A': return [0x0E,0x11,0x11,0x1F,0x11,0x11,0x11];
        case 'B': return [0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E];
        case 'C': return [0x0E,0x11,0x10,0x10,0x10,0x11,0x0E];
        case 'D': return [0x1C,0x12,0x11,0x11,0x11,0x12,0x1C];
        case 'E': return [0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F];
        case 'F': return [0x1F,0x10,0x10,0x1E,0x10,0x10,0x10];
        case 'G': return [0x0E,0x11,0x10,0x17,0x11,0x11,0x0F];
        case 'H': return [0x11,0x11,0x11,0x1F,0x11,0x11,0x11];
        case 'I': return [0x0E,0x04,0x04,0x04,0x04,0x04,0x0E];
        case 'J': return [0x07,0x02,0x02,0x02,0x02,0x12,0x0C];
        case 'K': return [0x11,0x12,0x14,0x18,0x14,0x12,0x11];
        case 'L': return [0x10,0x10,0x10,0x10,0x10,0x10,0x1F];
        case 'M': return [0x11,0x1B,0x15,0x15,0x11,0x11,0x11];
        case 'N': return [0x11,0x19,0x15,0x13,0x11,0x11,0x11];
        case 'O': return [0x0E,0x11,0x11,0x11,0x11,0x11,0x0E];
        case 'P': return [0x1E,0x11,0x11,0x1E,0x10,0x10,0x10];
        case 'Q': return [0x0E,0x11,0x11,0x11,0x15,0x12,0x0D];
        case 'R': return [0x1E,0x11,0x11,0x1E,0x14,0x12,0x11];
        case 'S': return [0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E];
        case 'T': return [0x1F,0x04,0x04,0x04,0x04,0x04,0x04];
        case 'U': return [0x11,0x11,0x11,0x11,0x11,0x11,0x0E];
        case 'V': return [0x11,0x11,0x11,0x11,0x11,0x0A,0x04];
        case 'W': return [0x11,0x11,0x11,0x15,0x15,0x1B,0x11];
        case 'X': return [0x11,0x11,0x0A,0x04,0x0A,0x11,0x11];
        case 'Y': return [0x11,0x11,0x0A,0x04,0x04,0x04,0x04];
        case 'Z': return [0x1F,0x01,0x02,0x04,0x08,0x10,0x1F];
        case '0': return [0x0E,0x11,0x13,0x15,0x19,0x11,0x0E];
        case '1': return [0x04,0x0C,0x04,0x04,0x04,0x04,0x0E];
        case '2': return [0x0E,0x11,0x01,0x02,0x04,0x08,0x1F];
        case '3': return [0x1F,0x02,0x04,0x02,0x01,0x11,0x0E];
        case '4': return [0x02,0x06,0x0A,0x12,0x1F,0x02,0x02];
        case '5': return [0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E];
        case '6': return [0x06,0x08,0x10,0x1E,0x11,0x11,0x0E];
        case '7': return [0x1F,0x01,0x02,0x04,0x08,0x08,0x08];
        case '8': return [0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E];
        case '9': return [0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C];
        case ' ': return [0x00,0x00,0x00,0x00,0x00,0x00,0x00];
        case '.': return [0x00,0x00,0x00,0x00,0x00,0x0C,0x0C];
        case ',': return [0x00,0x00,0x00,0x00,0x0C,0x04,0x08];
        case ':': return [0x00,0x0C,0x0C,0x00,0x0C,0x0C,0x00];
        case '-': return [0x00,0x00,0x00,0x1F,0x00,0x00,0x00];
        case '_': return [0x00,0x00,0x00,0x00,0x00,0x00,0x1F];
        case '>': return [0x08,0x04,0x02,0x01,0x02,0x04,0x08];
        case '<': return [0x02,0x04,0x08,0x10,0x08,0x04,0x02];
        case '/': return [0x01,0x01,0x02,0x04,0x08,0x10,0x10];
        case '\\':return [0x10,0x10,0x08,0x04,0x02,0x01,0x01];
        case '$': return [0x04,0x0F,0x14,0x0E,0x05,0x1E,0x04];
        case '%': return [0x18,0x19,0x02,0x04,0x08,0x13,0x03];
        case '#': return [0x0A,0x0A,0x1F,0x0A,0x1F,0x0A,0x0A];
        case '+': return [0x00,0x04,0x04,0x1F,0x04,0x04,0x00];
        case '=': return [0x00,0x00,0x1F,0x00,0x1F,0x00,0x00];
        case '!': return [0x04,0x04,0x04,0x04,0x04,0x00,0x04];
        case '?': return [0x0E,0x11,0x01,0x02,0x04,0x00,0x04];
        case '(': return [0x02,0x04,0x08,0x08,0x08,0x04,0x02];
        case ')': return [0x08,0x04,0x02,0x02,0x02,0x04,0x08];
        case '[': return [0x0E,0x08,0x08,0x08,0x08,0x08,0x0E];
        case ']': return [0x0E,0x02,0x02,0x02,0x02,0x02,0x0E];
        case '*': return [0x00,0x0A,0x04,0x1F,0x04,0x0A,0x00];
        case '\'':return [0x04,0x04,0x00,0x00,0x00,0x00,0x00];
        case '"': return [0x0A,0x0A,0x00,0x00,0x00,0x00,0x00];
        default:  return [0x00,0x00,0x00,0x00,0x00,0x00,0x00];
    }
}

float textWidth(string s, float sc) { return cast(float) s.length * 6.0f * sc; }

void drawText(ref float[] arr, float x, float y, string s, float sc,
              float r, float g, float b, float a)
{
    float cx = x;
    foreach (ch; s)
    {
        char c = cast(char) ch;
        if (c >= 'a' && c <= 'z') c = cast(char)(c - 'a' + 'A');
        ubyte[7] gl = glyphOf(c);
        for (int row = 0; row < 7; row++)
        {
            ubyte bits = gl[row];
            for (int col = 0; col < 5; col++)
                if (bits & (1 << (4 - col)))
                    rect2D(arr, cx + col * sc, y + row * sc, sc, sc, r, g, b, a);
        }
        cx += 6.0f * sc;
    }
}

void drawTextC(ref float[] arr, float cx, float y, string s, float sc,
               float r, float g, float b, float a)
{
    drawText(arr, cx - textWidth(s, sc) * 0.5f, y, s, sc, r, g, b, a);
}

//==============================================================================
// 地图生成
//==============================================================================
void generateMap(uint seed)
{
    auto rnd = Random(seed);
    covers.length = 0;

    // 四面边界墙 (高 6)
    const float wh = 6.0f;
    covers ~= Box(Vec3(0, wh * 0.5f, -MAP_HALF), Vec3(MAP_HALF, wh * 0.5f, 0.5f));
    covers ~= Box(Vec3(0, wh * 0.5f,  MAP_HALF), Vec3(MAP_HALF, wh * 0.5f, 0.5f));
    covers ~= Box(Vec3(-MAP_HALF, wh * 0.5f, 0), Vec3(0.5f, wh * 0.5f, MAP_HALF));
    covers ~= Box(Vec3( MAP_HALF, wh * 0.5f, 0), Vec3(0.5f, wh * 0.5f, MAP_HALF));

    // 随机掩体
    for (int i = 0; i < 90; i++)
    {
        float w = uniform(1.0f, 5.5f, rnd);
        float h = uniform(0.9f, 3.2f, rnd);
        float d = uniform(1.0f, 5.5f, rnd);
        float x = uniform(-46.0f, 46.0f, rnd);
        float z = uniform(-46.0f, 46.0f, rnd);
        if (sqrt(x * x + z * z) < 7.0f) continue;      // 出生点留空
        covers ~= Box(Vec3(x, h * 0.5f, z), Vec3(w * 0.5f, h * 0.5f, d * 0.5f));
    }
    // 几座高塔, 制造垂直层次
    for (int i = 0; i < 7; i++)
    {
        float x = uniform(-42.0f, 42.0f, rnd);
        float z = uniform(-42.0f, 42.0f, rnd);
        if (sqrt(x * x + z * z) < 10.0f) continue;
        float h = uniform(4.0f, 6.5f, rnd);
        covers ~= Box(Vec3(x, h * 0.5f, z), Vec3(1.6f, h * 0.5f, 1.6f));
    }
    // 长墙掩体
    for (int i = 0; i < 10; i++)
    {
        float x = uniform(-43.0f, 43.0f, rnd);
        float z = uniform(-43.0f, 43.0f, rnd);
        if (sqrt(x * x + z * z) < 12.0f) continue;
        bool alongX = uniform(0, 2, rnd) == 0;
        float L = uniform(6.0f, 14.0f, rnd);
        float h = uniform(1.4f, 2.6f, rnd);
        Vec3 hs = alongX ? Vec3(L * 0.5f, h * 0.5f, 0.5f) : Vec3(0.5f, h * 0.5f, L * 0.5f);
        covers ~= Box(Vec3(x, h * 0.5f, z), hs);
    }
}

bool spotFree(Vec3 p, float r)
{
    Box e = Box(Vec3(p.x, p.y + P_HEIGHT * 0.5f, p.z), Vec3(r, P_HEIGHT * 0.5f, r));
    foreach (ref b; covers)
        if (boxOverlap(e, b)) return false;
    return true;
}

Vec3 randomSpawn(ref Random rnd, float minDistFrom, Vec3 away)
{
    for (int i = 0; i < 200; i++)
    {
        float x = uniform(-46.0f, 46.0f, rnd);
        float z = uniform(-46.0f, 46.0f, rnd);
        Vec3 p = Vec3(x, 0.0f, z);
        if (dist(p, away) < minDistFrom) continue;
        if (!spotFree(p, 0.6f)) continue;
        return p;
    }
    return Vec3(0, 0, 0);
}

/// 给机器人随机挑一把武器 (带权重: 手枪/冲锋枪常见, 突击步枪较少)
int pickBotWeapon(ref Random rnd)
{
    static immutable int[] pool = [
        W_PISTOL, W_PISTOL, W_PISTOL,
        W_SMG,    W_SMG,    W_SMG,
        W_SEMI,   W_SEMI,
        W_AR,     W_AR,
        W_SHOTGUN,
        W_BOLT,
    ];
    int k = uniform(0, cast(int) pool.length, rnd);
    return (k >= 0 && k < cast(int) pool.length) ? pool[k] : W_PISTOL;
}

/// 给机器人换枪并装满弹匣
void equipBot(ref Bot b, int wi)
{
    b.weapon = (wi >= 0 && wi < WPN_COUNT) ? wi : W_PISTOL;
    b.mag = WEAPONS[b.weapon].magSize;
    b.reloadTimer = 0.0f;
    b.burstLeft = 0;
    b.fireTimer = 0.0f;
}

//==============================================================================
// 游戏流程
//==============================================================================
void resetGame()
{
    initWeapons();
    uint seed = cast(uint) uniform(1, 1_000_000_000);
    generateMap(seed);

    player = Player();
    player.pos = Vec3(0, 0, 0);
    player.yaw = 0.0f;
    player.hp = 10000.0f;
    player.money = 0;
    player.kills = 0;
    player.streak = 0;
    player.weapon = W_BOLT;
    player.owned[] = false;
    player.owned[W_BOLT] = true;
    for (int i = 0; i < WPN_COUNT; i++) player.mag[i] = WEAPONS[i].magSize;

    auto rnd = Random(cast(uint)(seed ^ 0x9E3779B9u));
    for (int i = 0; i < BOT_COUNT; i++)
    {
        Bot b;
        b.id = i + 1;
        b.pos = randomSpawn(rnd, 22.0f, Vec3(0, 0, 0));
        b.hp = 100.0f;
        b.alive = true;
        b.yaw = uniform(-PI_F, PI_F, rnd);
        b.wander = randomSpawn(rnd, 5.0f, b.pos);
        b.lastPos = b.pos;
        equipBot(b, pickBotWeapon(rnd));
        bots[i] = b;
    }

    tracers.length = 0;
    feeds.length = 0;
    gstate = GState.playing;
    shopOpen = false;
    setCursorCaptured(true);
    hitMarkTimer = 0.0f;
    hurtTimer = 0.0f;
    muzzleTimer = 0.0f;
    msgTimer = 0.0f;
    shopMsg = "";
    gameTime = 0.0f;
}

void addFeed(string s)
{
    feeds ~= Feed(s, 3.0f);
    if (feeds.length > 4) feeds = feeds[1 .. $];
}

void addTracer(Vec3 a, Vec3 b)
{
    tracers ~= Tracer(a, b, 0.07f);
}

bool hasLOS(Vec3 from, Vec3 to)
{
    Vec3 d = to - from;
    float L = len(d);
    if (L < 0.001f) return true;
    Vec3 rd = d * (1.0f / L);
    foreach (ref b; covers)
    {
        float t;
        if (rayBox(from, rd, b, t) && t < L - 0.05f) return false;
    }
    return true;
}

struct HitResult { bool isBot; int idx; float t; Vec3 point; bool head; }

HitResult raycastWorld(Vec3 ro, Vec3 rd, float maxDist)
{
    HitResult h;
    h.isBot = false; h.idx = -1; h.t = maxDist; h.head = false;

    foreach (ref b; covers)
    {
        float t;
        if (rayBox(ro, rd, b, t) && t < h.t) { h.t = t; h.isBot = false; h.idx = -1; }
    }
    for (int i = 0; i < BOT_COUNT; i++)
    {
        if (!bots[i].alive) continue;
        // 身体
        Box bodyB = Box(bots[i].pos + Vec3(0, 0.92f, 0), Vec3(0.42f, 0.92f, 0.36f));
        float t;
        if (rayBox(ro, rd, bodyB, t) && t < h.t)
        {
            h.t = t; h.isBot = true; h.idx = i;
            h.head = (ro + rd * t).y > bots[i].pos.y + 1.52f;
        }
        // 头(略大, 好打一点)
        Box headB = Box(bots[i].pos + Vec3(0, 1.74f, 0), Vec3(0.30f, 0.26f, 0.30f));
        if (rayBox(ro, rd, headB, t) && t < h.t)
        {
            h.t = t; h.isBot = true; h.idx = i; h.head = true;
        }
    }
    h.point = ro + rd * h.t;
    return h;
}

/// 分轴 AABB 碰撞移动
bool moveEntity(ref Vec3 pos, Vec3 d, float r, float h, ref bool grounded, ref bool hitCeil)
{
    bool blocked = false;
    auto test = (Vec3 p) {
        Box e = Box(Vec3(p.x, p.y + h * 0.5f, p.z), Vec3(r, h * 0.5f, r));
        foreach (ref b; covers) if (boxOverlap(e, b)) return true;
        return false;
    };

    pos.x += d.x;
    if (test(pos)) { pos.x -= d.x; blocked = true; }

    pos.z += d.z;
    if (test(pos)) { pos.z -= d.z; blocked = true; }

    pos.y += d.y;
    if (test(pos))
    {
        pos.y -= d.y;
        blocked = true;
        if (d.y < 0) grounded = true; else hitCeil = true;
    }
    if (pos.y <= 0.0f)
    {
        pos.y = 0.0f;
        if (d.y <= 0.0f) grounded = true;
        blocked = true;
    }
    return blocked;
}

void startReload()
{
    if (player.reloadTimer > 0.0f) return;
    int w = player.weapon;
    if (player.mag[w] >= WEAPONS[w].magSize) return;
    player.reloadTimer = WEAPONS[w].reloadTime;
}

void playerFire()
{
    int w = player.weapon;
    const WeaponDef def = WEAPONS[w];
    if (player.reloadTimer > 0.0f) return;
    if (player.fireTimer > 0.0f) return;      // 射击间隔
    if (player.mag[w] <= 0) { startReload(); return; }

    player.fireTimer = def.fireInterval;
    player.mag[w]--;
    muzzleTimer = 0.045f;
    if (w == W_BOLT) player.boltTimer = def.fireInterval * 0.85f;

    Vec3 eye = player.pos + Vec3(0, EYE_H + player.bobAmt, 0);
    float sp = def.spread + (player.onGround ? 0.0f : 0.02f);

    bool anyHit = false, anyKill = false;

    // 霰弹枪一次打多颗弹丸, 其余武器 pellets == 1
    for (int p = 0; p < def.pellets; p++)
    {
        float ps = (def.pellets > 1) ? def.pelletSpread : 0.0f;
        float tot = sp + ps;
        Vec3 dir = norm(dirFrom(player.yaw   + uniform(-tot, tot),
                                player.pitch + uniform(-tot, tot) + player.viewKick));

        HitResult h = raycastWorld(eye, dir, 220.0f);
        float tEnd = (h.t < 220.0f) ? h.t : 220.0f;
        addTracer(eye + dir * 0.8f + Vec3(0, -0.12f, 0), eye + dir * tEnd);

        if (h.isBot && h.idx >= 0 && bots[h.idx].alive)
        {
            anyHit = true;
            Bot* b = &bots[h.idx];
            float dmg = def.damage * (h.head ? 2.0f : 1.0f);
            b.hp -= dmg;
            b.hitFlash = 0.12f;
            if (b.hp <= 0.0f)
            {
                b.alive = false;
                b.respawnTimer = 1.6f;
                player.kills++;
                player.streak++;
                int reward = MONEY_PER_KILL + (player.streak - 1) * 50;
                player.money += reward;
                anyKill = true;
                addFeed(format("ELIMINATED BOT_%02d (%s)  +$%d", b.id, def.tag, reward));
                if (player.kills >= KILL_TARGET) gstate = GState.won;
            }
        }
    }

    if (anyHit) { hitMarkTimer = 0.18f; hitMarkKill = anyKill; }

    player.viewKick += def.recoil;
    player.pitch += def.recoil * 0.55f;
}

void buyWeapon(int idx)
{
    if (player.owned[idx])
    {
        player.weapon = idx;
        shopMsg = "EQUIPPED";
        msgTimer = 1.2f;
        return;
    }
    if (player.money < WEAPONS[idx].price)
    {
        shopMsg = "NOT ENOUGH CASH";
        msgTimer = 1.4f;
        return;
    }
    player.money -= WEAPONS[idx].price;
    player.owned[idx] = true;
    player.mag[idx] = WEAPONS[idx].magSize;
    player.weapon = idx;
    player.fireTimer = 0.0f;
    player.reloadTimer = 0.0f;
    shopMsg = "PURCHASED";
    msgTimer = 1.2f;
    addFeed(format("BOUGHT %s", WEAPONS[idx].tag));
}

void respawnBot(ref Bot b)
{
    auto rnd = Random(cast(uint) uniform(1, 1_000_000_000));
    b.pos = randomSpawn(rnd, 26.0f, player.pos);
    b.hp = 100.0f;
    b.alive = true;
    b.vy = 0.0f;
    b.state = 0;
    b.fireTimer = uniform(0.3f, 1.4f, rnd);
    b.wander = randomSpawn(rnd, 5.0f, b.pos);
    b.lastPos = b.pos;
    equipBot(b, pickBotWeapon(rnd));   // 重生时换一把枪, 每局遇到的火力不一样
}

/// 机器人拿不同武器时的交战距离 / 期望站位
void botWeaponProfile(int wi, out float engageR, out float keepD)
{
    switch (wi)
    {
        case W_BOLT:    engageR = 46.0f; keepD = 20.0f; break;   // 远远地点
        case W_PISTOL:  engageR = 30.0f; keepD = 10.0f; break;
        case W_SMG:     engageR = 34.0f; keepD = 11.0f; break;
        case W_SEMI:    engageR = 44.0f; keepD = 16.0f; break;
        case W_AR:      engageR = 46.0f; keepD = 15.0f; break;
        case W_SHOTGUN: engageR = 24.0f; keepD =  7.0f; break;   // 必须贴脸
        default:        engageR = 40.0f; keepD = 12.0f; break;
    }
}

/// 机器人开一枪: 用自己手里的武器参数, 全自动/半自动在这里体现为调用频率
void botShoot(int idx, Vec3 playerEye)
{
    Bot* b = &bots[idx];
    const WeaponDef def = WEAPONS[b.weapon];
    if (b.mag <= 0) return;
    b.mag--;

    Vec3  from = b.pos + Vec3(0, 1.40f, 0);
    Vec3  aim  = norm(playerEye - from);
    float d    = dist(b.pos, player.pos);
    float sp   = def.botSpread + clamp(d / 900.0f, 0.0f, 0.05f);

    // 玩家碰撞盒, 用来做真实几何命中
    Box playerBox = Box(player.pos + Vec3(0, P_HEIGHT * 0.5f, 0),
                        Vec3(0.42f, P_HEIGHT * 0.5f, 0.42f));

    for (int p = 0; p < def.pellets; p++)
    {
        float ps  = (def.pellets > 1) ? def.pelletSpread : 0.0f;
        float tot = sp + ps;
        Vec3 dir  = norm(aim + Vec3(uniform(-tot, tot),
                                    uniform(-tot * 0.6f, tot * 0.6f),
                                    uniform(-tot, tot)));
        addTracer(from, from + dir * 60.0f);

        // 1) 几何上要打到玩家
        float t = 0.0f;
        if (!rayBox(from, dir, playerBox, t)) continue;
        if (t > d + 3.0f) continue;

        // 2) 中途不能被掩体挡住
        bool blocked = false;
        foreach (ref c; covers)
        {
            float tc;
            if (rayBox(from, dir, c, tc) && tc < t - 0.15f) { blocked = true; break; }
        }
        if (blocked) continue;

        // 3) 枪法: 越远越不准
        float acc = clamp(0.80f - d / 75.0f, 0.28f, 0.80f);
        if (uniform(0.0f, 1.0f) > acc) continue;

        float dmg = def.damage * uniform(0.70f, 0.95f);
        player.hp -= dmg;
        hurtTimer = 0.35f;
        if (player.hp <= 0.0f)
        {
            player.hp = 0.0f;
            player.streak = 0;
            gstate = GState.dead;
            addFeed(format("KILLED BY BOT_%02d (%s)", b.id, def.tag));
            break;
        }
    }
}

void updateBots(float dt)
{
    Vec3 eye = player.pos + Vec3(0, EYE_H, 0);

    for (int i = 0; i < BOT_COUNT; i++)
    {
        Bot* b = &bots[i];
        if (b.hitFlash > 0.0f) b.hitFlash -= dt;

        if (!b.alive)
        {
            b.respawnTimer -= dt;
            if (b.respawnTimer <= 0.0f) respawnBot(*b);
            continue;
        }

        Vec3 botEye = b.pos + Vec3(0, 1.55f, 0);
        float d = dist(b.pos, player.pos);
        bool los = hasLOS(botEye, eye);
        // 交战距离和期望站位跟着手里的枪走: 霰弹枪要贴脸, 栓动步枪喜欢远远地打
        float engageR = 40.0f, keepD = 12.0f;
        botWeaponProfile(b.weapon, engageR, keepD);
        bool engaged = (d < engageR && los && gstate == GState.playing);
        // 刚发现玩家时给一点反应时间, 别一转头就吃枪子
        bool justEngaged = engaged && (b.state == 0);
        b.state = engaged ? 1 : 0;
        if (justEngaged)
        {
            b.burstLeft = 0;
            b.fireTimer = max(b.fireTimer, uniform(0.25f, 0.60f));
        }

        // ---- 转向 ----
        float wantYaw = 0.0f;
        if (engaged)
        {
            Vec3 to = player.pos - b.pos;
            wantYaw = atan2(to.x, -to.z);
        }
        else
        {
            Vec3 to = b.wander - b.pos;
            if (len(to) < 1.4f)
            {
                auto rnd = Random(cast(uint) uniform(1, 1_000_000_000));
                b.wander = randomSpawn(rnd, 3.0f, b.pos);
                if (len(b.wander - b.pos) < 1.0f) b.wander = Vec3(uniform(-40.0f, 40.0f), 0, uniform(-40.0f, 40.0f));
            }
            wantYaw = atan2(to.x, -to.z);
        }
        float diff = wantYaw - b.yaw;
        while (diff >  PI_F) diff -= 2.0f * PI_F;
        while (diff < -PI_F) diff += 2.0f * PI_F;
        b.yaw += diff * clamp(dt * 6.0f, 0.0f, 1.0f);

        // ---- 移动 ----
        Vec3 mv = Vec3(0, 0, 0);
        if (engaged)
        {
            Vec3 fwd  = dirFrom(b.yaw, 0.0f);
            Vec3 side = Vec3(-fwd.z, 0, fwd.x);          // 侧向绕行, 避免直线卡墙
            float strafe = sin(gameTime * 0.7f + i) * 2.0f;
            if (d > keepD + 3.0f)
            {
                mv = fwd * 3.1f + side * strafe * 0.7f;   // 压上来
            }
            else if (d < keepD - 4.0f)
            {
                mv = fwd * (-2.2f) + side * strafe * 0.5f; // 太近了往后退
            }
            else
            {
                mv = side * strafe;                        // 保持距离横向游走
            }
        }
        else
        {
            Vec3 fwd = dirFrom(b.yaw, 0.0f);
            mv = fwd * 2.4f;
        }

        b.vy -= GRAVITY * dt;
        bool grounded = false, hitCeil = false;
        Vec3 delta = Vec3(mv.x * dt, b.vy * dt, mv.z * dt);
        moveEntity(b.pos, delta, 0.40f, 1.80f, grounded, hitCeil);
        if (grounded) { b.vy = 0.0f; }
        if (hitCeil)  { b.vy = 0.0f; }
        // 限制在地图内
        b.pos.x = clamp(b.pos.x, -MAP_HALF + 1.0f, MAP_HALF - 1.0f);
        b.pos.z = clamp(b.pos.z, -MAP_HALF + 1.0f, MAP_HALF - 1.0f);

        // ---- 卡住检测 ----
        if (dist(b.pos, b.lastPos) < 0.02f)
        {
            b.stuckTimer += dt;
            if (b.stuckTimer > 1.2f)
            {
                auto rnd = Random(cast(uint) uniform(1, 1_000_000_000));
                b.wander = randomSpawn(rnd, 3.0f, b.pos);
                b.yaw += uniform(-2.0f, 2.0f, rnd);
                b.stuckTimer = 0.0f;
            }
        }
        else b.stuckTimer = 0.0f;
        b.lastPos = b.pos;

        // ---- 开火 (用机器人手里那把枪的参数) ----
        const WeaponDef bw = WEAPONS[b.weapon];
        if (engaged && gstate == GState.playing)
        {
            if (b.reloadTimer > 0.0f)
            {
                b.reloadTimer -= dt;
                if (b.reloadTimer <= 0.0f)
                {
                    b.reloadTimer = 0.0f;
                    b.mag = bw.magSize;
                    b.burstLeft = 0;
                }
            }
            else if (b.mag <= 0)
            {
                b.reloadTimer = bw.reloadTime;
                b.burstLeft = 0;
            }
            else
            {
                b.fireTimer -= dt;
                if (b.fireTimer <= 0.0f)
                {
                    if (bw.fullAuto && b.burstLeft > 0)
                    {
                        // 点射进行中, 按武器射速连续出弹
                        b.burstLeft--;
                        b.fireTimer = bw.fireInterval;
                        if (b.burstLeft == 0)
                            b.fireTimer += uniform(0.35f, 0.95f);   // 一串打完歇一下
                    }
                    else if (bw.fullAuto)
                    {
                        // 起手一梭子点射
                        b.burstLeft = uniform(bw.botBurstMin, bw.botBurstMax + 1);
                        b.fireTimer = bw.fireInterval;
                    }
                    else
                    {
                        // 半自动: 一发一发点, 带随机的"扳机手速"延迟
                        b.burstLeft = 0;
                        b.fireTimer = max(bw.fireInterval, uniform(0.28f, 0.75f));
                    }
                    botShoot(i, eye);
                }
            }
        }
        else
        {
            // 脱战时把空弹匣补满, 免得下次遭遇时空枪
            b.burstLeft = 0;
            if (b.mag <= 0 && b.reloadTimer <= 0.0f) b.reloadTimer = bw.reloadTime;
            if (b.reloadTimer > 0.0f)
            {
                b.reloadTimer -= dt;
                if (b.reloadTimer <= 0.0f)
                {
                    b.reloadTimer = 0.0f;
                    b.mag = bw.magSize;
                }
            }
        }
    }
}

void update(float dt)
{
    gameTime += dt;

    // ---- 计时器 ----
    if (hitMarkTimer > 0.0f) hitMarkTimer -= dt;
    if (hurtTimer > 0.0f)    hurtTimer -= dt;
    if (muzzleTimer > 0.0f)  muzzleTimer -= dt;
    if (msgTimer > 0.0f)     msgTimer -= dt;
    if (player.fireTimer > 0.0f)   player.fireTimer -= dt;
    if (player.boltTimer > 0.0f)   player.boltTimer -= dt;
    if (player.viewKick > 0.0f)    player.viewKick = max(0.0f, player.viewKick - dt * 0.55f);

    for (int i = cast(int) feeds.length - 1; i >= 0; i--)
    {
        feeds[i].life -= dt;
        if (feeds[i].life <= 0.0f)
        {
            for (int j = i; j < cast(int) feeds.length - 1; j++) feeds[j] = feeds[j + 1];
            feeds.length = feeds.length - 1;
        }
    }

    // 曳光
    {
        int n = 0;
        for (int i = 0; i < cast(int) tracers.length; i++)
        {
            tracers[i].life -= dt;
            if (tracers[i].life > 0.0f) tracers[n++] = tracers[i];
        }
        tracers.length = n;
    }

    if (gstate != GState.playing)
    {
        // 结束时仍让世界稍微动一下
        updateBots(dt);
        if (keyHit[GLFW_KEY_R]) { resetGame(); }
        return;
    }

    // ---- 视角 ----
    if (shopOpen)
    {
        accDX = 0.0; accDY = 0.0;   // 菜单打开时不转视角
    }
    else
    {
        // 约定: yaw 增大 = 向右转(dirFrom 中 yaw 从 -Z 转向 +X, 即玩家的右手边)
        //       鼠标右移 accDX > 0  => yaw 增大 => 视角右转(标准 FPS 手感)
        //       鼠标上移 accDY < 0  => pitch 增大 => 视角上抬
        player.yaw   += accDX * sensX * (invertX ? -1.0f : 1.0f);
        player.pitch -= accDY * sensY * (invertY ? -1.0f : 1.0f);
    }
    accDX = 0.0; accDY = 0.0;
    player.pitch = clamp(player.pitch, -1.52f, 1.52f);
    if (player.yaw >  PI_F) player.yaw -= 2.0f * PI_F;
    if (player.yaw < -PI_F) player.yaw += 2.0f * PI_F;

    // ---- 菜单 / 购买 ----
    if (keyHit[GLFW_KEY_B])
    {
        shopOpen = !shopOpen;
        setCursorCaptured(!shopOpen);
    }
    // ---- 鼠标设置 ----
    if (keyHit[GLFW_KEY_I])
    {
        invertY = !invertY;
        shopMsg = invertY ? "INVERT Y: ON" : "INVERT Y: OFF";
        msgTimer = 1.5f;
    }
    if (keyHit[GLFW_KEY_O])
    {
        invertX = !invertX;
        shopMsg = invertX ? "INVERT X: ON" : "INVERT X: OFF";
        msgTimer = 1.5f;
    }
    if (keyHit[GLFW_KEY_LEFT_BRACKET])
    {
        sensX = max(0.0004f, sensX * 0.85f);
        sensY = max(0.0004f, sensY * 0.85f);
        shopMsg = format("SENSITIVITY %.5f", sensX);
        msgTimer = 1.2f;
    }
    if (keyHit[GLFW_KEY_RIGHT_BRACKET])
    {
        sensX = min(0.0100f, sensX * 1.18f);
        sensY = min(0.0100f, sensY * 1.18f);
        shopMsg = format("SENSITIVITY %.5f", sensX);
        msgTimer = 1.2f;
    }
    if (shopOpen)
    {
        // 商店里 1..(WPN_COUNT-1) 购买对应商品 (武器索引 1..WPN_COUNT-1, 0 号是初始枪不用买)
        for (int i = 1; i < WPN_COUNT; i++)
            if (keyHit[GLFW_KEY_1 + i - 1]) buyWeapon(i);
    }
    else
    {
        // 1..WPN_COUNT 切换已拥有的武器
        for (int i = 0; i < WPN_COUNT; i++)
            if (keyHit[GLFW_KEY_1 + i] && player.owned[i])
            {
                player.weapon = i;
                player.reloadTimer = 0.0f;
                player.boltTimer = 0.0f;
            }
    }
    if (keyHit[GLFW_KEY_R]) startReload();

    // ---- 换弹 ----
    if (player.reloadTimer > 0.0f)
    {
        player.reloadTimer -= dt;
        if (player.reloadTimer <= 0.0f)
        {
            player.reloadTimer = 0.0f;
            player.mag[player.weapon] = WEAPONS[player.weapon].magSize;
        }
    }

    // ---- 移动 ----
    Vec3 fwd   = dirFrom(player.yaw, 0.0f);
    Vec3 right = Vec3(cos(player.yaw), 0.0f, sin(player.yaw));
    float mf = 0.0f, ms = 0.0f;
    if (keys[GLFW_KEY_W]) mf += 1.0f;
    if (keys[GLFW_KEY_S]) mf -= 1.0f;
    if (keys[GLFW_KEY_D]) ms += 1.0f;
    if (keys[GLFW_KEY_A]) ms -= 1.0f;

    Vec3 wish = fwd * mf + right * ms;
    float wl = len(wish);
    bool moving = wl > 0.001f;
    if (moving) wish = wish * (1.0f / wl);

    bool sprint = keys[GLFW_KEY_LEFT_SHIFT] && mf > 0.0f;
    float speed = sprint ? RUN_SPEED : WALK_SPEED;
    if (player.reloadTimer > 0.0f) speed *= 0.86f;

    // 跳跃
    if (keys[GLFW_KEY_SPACE] && player.onGround)
    {
        player.vy = JUMP_SPEED;
        player.onGround = false;
    }

    player.vy -= GRAVITY * dt;
    Vec3 delta = Vec3(wish.x * speed * dt, player.vy * dt, wish.z * speed * dt);

    bool grounded = false, hitCeil = false;
    moveEntity(player.pos, delta, P_RADIUS, P_HEIGHT, grounded, hitCeil);
    if (grounded)
    {
        if (player.vy < 0.0f) player.vy = 0.0f;
        player.onGround = true;
    }
    else player.onGround = false;
    if (hitCeil && player.vy > 0.0f) player.vy = 0.0f;
    player.pos.x = clamp(player.pos.x, -MAP_HALF + 0.6f, MAP_HALF - 0.6f);
    player.pos.z = clamp(player.pos.z, -MAP_HALF + 0.6f, MAP_HALF - 0.6f);

    // 走路摇晃
    if (moving && player.onGround)
    {
        player.bobT += dt * (sprint ? 12.0f : 9.0f);
        player.bobAmt = sin(player.bobT) * (sprint ? 0.055f : 0.035f);
    }
    else player.bobAmt = lerp(player.bobAmt, 0.0f, clamp(dt * 8.0f, 0.0f, 1.0f));

    // ---- 射击 ----
    const WeaponDef def = WEAPONS[player.weapon];
    if (!shopOpen)
    {
        if (def.fullAuto)
        {
            if (mouseDown) playerFire();
        }
        else
        {
            if (mousePressed) playerFire();
        }
    }

    updateBots(dt);
}

//==============================================================================
// 渲染
//==============================================================================
void renderScene(float dt)
{
    glViewport(0, 0, fbW, fbH);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    glDisable(GL_BLEND);
    glClearColor(0.62f, 0.72f, 0.82f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    float aspect = (fbH > 0) ? (cast(float) fbW / cast(float) fbH) : 1.0f;
    Mat4 proj = perspective(radians(VIEW_FOV), aspect, 0.05f, 400.0f);
    Vec3 eye = player.pos + Vec3(0, EYE_H + player.bobAmt, 0);
    Vec3 look = eye + dirFrom(player.yaw, player.pitch + player.viewKick * 0.4f);
    Mat4 view = lookAt(eye, look, Vec3(0, 1, 0));
    gVP = mul(proj, view);

    glUseProgram(progMain);
    glUniform3f(m_locLight, 0.45f, 0.82f, 0.35f);
    glUniform3f(m_locCam, eye.x, eye.y, eye.z);
    glUniform1f(m_locAmb, 0.42f);

    // 地面
    drawBox(Vec3(0, -0.5f, 0), Vec3(MAP_HALF * 2.0f, 1.0f, MAP_HALF * 2.0f),
            Vec3(0.36f, 0.44f, 0.33f), 1.0f);

    // 掩体
    for (int i = 4; i < cast(int) covers.length; i++)
    {
        Box b = covers[i];
        // 用位置做点色彩变化
        float tint = 0.5f + 0.5f * sin(b.c.x * 0.31f + b.c.z * 0.17f);
        Vec3 col = Vec3(0.44f + 0.14f * tint, 0.40f + 0.10f * tint, 0.36f + 0.06f * tint);
        if (b.h.y > 2.6f) col = Vec3(0.40f, 0.40f, 0.46f);   // 高塔
        drawBox(b.c, Vec3(b.h.x * 2.0f, b.h.y * 2.0f, b.h.z * 2.0f), col);
    }
    // 边界墙
    for (int i = 0; i < 4; i++)
    {
        Box b = covers[i];
        drawBox(b.c, Vec3(b.h.x * 2.0f, b.h.y * 2.0f, b.h.z * 2.0f), Vec3(0.30f, 0.32f, 0.36f));
    }

    // 机器人
    for (int i = 0; i < BOT_COUNT; i++)
    {
        Bot b = bots[i];
        if (!b.alive) continue;
        const WeaponDef bw = WEAPONS[b.weapon];
        Vec3 col = (b.hitFlash > 0.0f) ? Vec3(1.0f, 0.95f, 0.9f)
                                       : Vec3(0.72f, 0.22f, 0.20f);
        if (b.state == 1) col = Vec3(0.85f, 0.35f, 0.12f);
        drawBox(b.pos + Vec3(0, 0.92f, 0), Vec3(0.74f, 1.24f, 0.56f), col);
        drawBox(b.pos + Vec3(0, 1.74f, 0), Vec3(0.44f, 0.42f, 0.44f), Vec3(0.86f, 0.72f, 0.58f));
        // 手中的枪: 形状/长度/颜色都跟着它拿的那把武器走
        Vec3 f = dirFrom(b.yaw, 0.0f);
        float glen = min(bw.vmSize.z, 0.95f);
        drawBoxRot(b.pos + Vec3(0, 1.22f, 0) + f * (glen * 0.5f + 0.12f),
                   Vec3(0.11f, 0.11f, glen), b.yaw, bw.vmColor);
        // 面向指示(鼻子)
        drawBox(b.pos + Vec3(0, 1.72f, 0) + f * 0.24f, Vec3(0.14f, 0.12f, 0.12f), Vec3(0.2f, 0.2f, 0.2f));
    }

    // 曳光线
    if (tracers.length > 0)
    {
        lineVerts.length = 0;
        for (int i = 0; i < cast(int) tracers.length; i++)
        {
            Tracer t = tracers[i];
            float a = clamp(t.life / 0.07f, 0.0f, 1.0f);
            pushVert(lineVerts, t.a.x, t.a.y, t.a.z, 1.0f, 0.9f, 0.4f, a);
            pushVert(lineVerts, t.b.x, t.b.y, t.b.z, 1.0f, 0.6f, 0.2f, a * 0.2f);
        }
        glUseProgram(progFlat);
        glUniformMatrix4fv(f_locMVP, 1, GL_FALSE, gVP.m.ptr);
        glUniform4f(f_locColor, 1.0f, 1.0f, 1.0f, 1.0f);
        glBindVertexArray(flatVAO);
        glBindBuffer(GL_ARRAY_BUFFER, flatVBO);
        glBufferData(GL_ARRAY_BUFFER, cast(GLsizeiptr)(lineVerts.length * float.sizeof), lineVerts.ptr, GL_DYNAMIC_DRAW);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        glDrawArrays(GL_LINES, 0, cast(int)(lineVerts.length / 7));
        glDisable(GL_BLEND);
        glEnable(GL_DEPTH_TEST);
    }

    // ---- 手中的武器(视图模型): 清深度, 保证永远画在最前 ----
    glClear(GL_DEPTH_BUFFER_BIT);
    glUseProgram(progMain);
    glUniform1f(m_locAmb, 0.55f);
    {
        const WeaponDef def = WEAPONS[player.weapon];
        Vec3 fwd   = dirFrom(player.yaw, player.pitch + player.viewKick * 0.6f);
        Vec3 right = norm(cross(fwd, Vec3(0, 1, 0)));
        if (len(right) < 0.001f) right = Vec3(1, 0, 0);
        Vec3 up = cross(right, fwd);

        float kick = (player.fireTimer > 0.0f)
                   ? clamp(player.fireTimer / def.fireInterval, 0.0f, 1.0f) : 0.0f;
        float rel  = (player.reloadTimer > 0.0f)
                   ? clamp(player.reloadTimer / def.reloadTime, 0.0f, 1.0f) : 0.0f;
        float bolt = (player.boltTimer > 0.0f)
                   ? clamp(player.boltTimer / (def.fireInterval * 0.85f), 0.0f, 1.0f) : 0.0f;

        float reloadDrop = sin(rel * PI_F) * 0.35f;
        float sway = player.bobAmt * 0.8f;

        Vec3 base = eye
                  + fwd   * (0.62f - kick * 0.16f)
                  + right * (0.26f + bolt * 0.06f)
                  + up    * (-0.24f - reloadDrop + sway + kick * 0.05f);

        Mat4 model = basis(right, up, fwd, base);
        // 局部: x 右, y 上, z 前
        Mat4 local = translate(Vec3(0.0f, 0.0f, def.vmSize.z * 0.5f - 0.1f - bolt * 0.12f));
        Mat4 m = mul(mul(model, local), scale(def.vmSize));
        drawBoxModel(m, def.vmColor);

        // 枪管
        Mat4 barrel = mul(mul(model, translate(Vec3(0.0f, 0.055f, def.vmSize.z * 0.95f - bolt * 0.12f))),
                          scale(Vec3(0.045f, 0.045f, 0.30f)));
        drawBoxModel(barrel, Vec3(0.12f, 0.12f, 0.13f));

        // 枪口火焰
        if (muzzleTimer > 0.0f)
        {
            float s = 0.10f + muzzleTimer * 1.6f;
            Mat4 fl = mul(mul(model, translate(Vec3(0.0f, 0.055f, def.vmSize.z * 1.12f))),
                          scale(Vec3(s, s, s)));
            drawBoxModel(fl, Vec3(1.0f, 0.85f, 0.30f));
        }
    }
    glUniform1f(m_locAmb, 0.42f);
}

void renderHUD()
{
    float W = cast(float) fbW, H = cast(float) fbH;
    Mat4 ortho = ortho2D(W, H);

    hudVerts.length = 0;

    // ---------- 准心 ----------
    if (gstate == GState.playing && !shopOpen)
    {
        float cx = W * 0.5f, cy = H * 0.5f;
        float gap = 4.0f + (player.onGround ? 0.0f : 5.0f);
        float arm = 9.0f;
        float th = 2.0f;
        // 黑描边 + 白线
        rect2D(hudVerts, cx - th, cy - gap - arm, th * 2.0f, arm, 0, 0, 0, 0.55f);
        rect2D(hudVerts, cx - th, cy + gap,       th * 2.0f, arm, 0, 0, 0, 0.55f);
        rect2D(hudVerts, cx - gap - arm, cy - th, arm, th * 2.0f, 0, 0, 0, 0.55f);
        rect2D(hudVerts, cx + gap,       cy - th, arm, th * 2.0f, 0, 0, 0, 0.55f);
        rect2D(hudVerts, cx - 1.0f, cy - gap - arm, 2.0f, arm, 1, 1, 1, 0.95f);
        rect2D(hudVerts, cx - 1.0f, cy + gap,       2.0f, arm, 1, 1, 1, 0.95f);
        rect2D(hudVerts, cx - gap - arm, cy - 1.0f, arm, 2.0f, 1, 1, 1, 0.95f);
        rect2D(hudVerts, cx + gap,       cy - 1.0f, arm, 2.0f, 1, 1, 1, 0.95f);
        rect2D(hudVerts, cx - 1.0f, cy - 1.0f, 2.0f, 2.0f, 1, 0, 0, 0.8f);

        // 命中标记
        if (hitMarkTimer > 0.0f)
        {
            float r = 1.0f, g = 1.0f, b = 1.0f;
            if (hitMarkKill) { g = 0.3f; b = 0.3f; }
            float d = 5.0f, l = 6.0f;
            for (int k = 0; k < 4; k++)
            {
                float sx = (k == 0 || k == 3) ? -1.0f : 1.0f;
                float sy = (k < 2) ? -1.0f : 1.0f;
                float x0 = cx + sx * d, y0 = cy + sy * d;
                float x1 = cx + sx * (d + l), y1 = cy + sy * (d + l);
                // 用细长矩形近似斜线: 分 6 段
                for (int s2 = 0; s2 < 6; s2++)
                {
                    float t0 = cast(float) s2 / 6.0f, t1 = (s2 + 1.0f) / 6.0f;
                    float ax = lerp(x0, x1, t0), ay = lerp(y0, y1, t0);
                    float bx = lerp(x0, x1, t1), by = lerp(y0, y1, t1);
                    rect2D(hudVerts, min(ax, bx) - 1.0f, min(ay, by) - 1.0f,
                           fabs(bx - ax) + 2.0f, fabs(by - ay) + 2.0f, r, g, b, 1.0f);
                }
            }
        }
    }

    // ---------- 受伤/低血量红晕 ----------
    float hurtA = 0.0f;
    if (hurtTimer > 0.0f) hurtA = clamp(hurtTimer / 0.35f, 0.0f, 1.0f) * 0.35f;
    float lowA = (player.hp < 35.0f) ? (1.0f - player.hp / 35.0f) * 0.22f : 0.0f;
    float redA = max(hurtA, lowA);
    if (redA > 0.002f)
    {
        float th = 40.0f;
        rect2D(hudVerts, 0, 0, W, th, 1, 0.1f, 0.1f, redA);
        rect2D(hudVerts, 0, H - th, W, th, 1, 0.1f, 0.1f, redA);
        rect2D(hudVerts, 0, 0, th, H, 1, 0.1f, 0.1f, redA);
        rect2D(hudVerts, W - th, 0, th, H, 1, 0.1f, 0.1f, redA);
    }

    // ---------- 左下: 血量 ----------
    float bx = 28.0f, by = H - 78.0f;
    rect2D(hudVerts, bx - 2, by - 2, 224, 28, 0, 0, 0, 0.45f);
    float hpFrac = clamp(player.hp / 10000.0f, 0.0f, 1.0f);
    rect2D(hudVerts, bx, by, 220.0f * hpFrac, 24.0f,
           hpFrac > 0.5f ? 0.25f : 1.0f, hpFrac > 0.5f ? 0.85f : 0.25f, 0.3f, 0.95f);
    rectBorder(hudVerts, bx - 2, by - 2, 224, 28, 2, 1, 1, 1, 0.5f);
    drawText(hudVerts, bx + 4, by + 5, format("HP %d", cast(int) player.hp), 2.0f, 1, 1, 1, 1);

    // ---------- 右下: 弹药 / 武器 ----------
    const WeaponDef def = WEAPONS[player.weapon];
    string ammoTxt = (player.reloadTimer > 0.0f)
        ? "RELOADING..."
        : format("%d / %d", player.mag[player.weapon], def.magSize);
    drawText(hudVerts, W - 320.0f, H - 108.0f, def.name, 2.0f, 1, 0.95f, 0.4f, 1);
    drawText(hudVerts, W - 320.0f, H - 130.0f,
             def.fullAuto ? "FULL-AUTO" : "SEMI-AUTO", 1.5f, 0.6f, 0.95f, 1.0f, 1);
    drawText(hudVerts, W - 320.0f, H - 74.0f, ammoTxt, 3.0f, 1, 1, 1, 1);
    // 弹匣格
    for (int i = 0; i < def.magSize; i++)
    {
        float cw = 6.0f;
        rect2D(hudVerts, W - 320.0f + i * (cw + 2.0f), H - 44.0f, cw, 10.0f,
               i < player.mag[player.weapon] ? 1.0f : 0.35f,
               i < player.mag[player.weapon] ? 0.85f : 0.35f, 0.2f, 0.9f);
    }
    // 已拥有武器指示 (6 把, 排两行)
    for (int i = 0; i < WPN_COUNT; i++)
    {
        float x = W - 320.0f + (i % 3) * 96.0f;
        float y = H - 178.0f + (i / 3) * 22.0f;
        float r = player.owned[i] ? 1.0f : 0.3f;
        float g = player.owned[i] ? 1.0f : 0.3f;
        drawText(hudVerts, x, y, format("%d:%s", i + 1, WEAPONS[i].tag), 1.5f, r, g, 0.5f, 1);
        if (i == player.weapon)
            rect2D(hudVerts, x - 4, y - 4, 92.0f, 18.0f, 1, 1, 1, 0.18f);
    }

    // ---------- 右上: 击杀 / 金钱 ----------
    string killTxt = format("KILLS %d / %d", player.kills, KILL_TARGET);
    drawText(hudVerts, W - textWidth(killTxt, 2.2f) - 28.0f, 28.0f, killTxt, 2.2f, 1, 1, 1, 1);
    string moneyTxt = format("CASH $%d", player.money);
    drawText(hudVerts, W - textWidth(moneyTxt, 2.2f) - 28.0f, 58.0f, moneyTxt, 2.2f, 1, 0.85f, 0.25f, 1);
    string botTxt = format("HOSTILES %d", BOT_COUNT);
    drawText(hudVerts, W - textWidth(botTxt, 1.5f) - 28.0f, 88.0f, botTxt, 1.5f, 0.8f, 0.85f, 0.95f, 1);
    drawText(hudVerts, 28.0f, 24.0f, format("FPS %d", cast(int) fps), 1.4f, 0.7f, 0.8f, 0.9f, 1);

    // 击杀进度条
    rect2D(hudVerts, W - 228.0f, 114.0f, 200.0f, 8.0f, 0, 0, 0, 0.45f);
    rect2D(hudVerts, W - 228.0f, 114.0f,
           200.0f * clamp(cast(float) player.kills / cast(float) KILL_TARGET, 0.0f, 1.0f),
           8.0f, 0.95f, 0.6f, 0.15f, 1.0f);

    // ---------- killfeed ----------
    for (int i = 0; i < cast(int) feeds.length; i++)
    {
        float a = clamp(feeds[i].life / 3.0f, 0.0f, 1.0f);
        float y = 150.0f + i * 22.0f;
        string s = feeds[i].text;
        drawText(hudVerts, W - textWidth(s, 1.7f) - 28.0f, y, s, 1.7f, 1, 0.9f, 0.5f, a);
    }

    // ---------- 提示 ----------
    drawTextC(hudVerts, W * 0.5f, H - 34.0f,
              "B: SHOP  R: RELOAD  1-6: SWITCH  SHIFT: SPRINT  I/O: INVERT Y/X  [ ]: SENS",
              1.4f, 0.85f, 0.9f, 1.0f, 0.75f);

    if (msgTimer > 0.0f)
    {
        float a = clamp(msgTimer, 0.0f, 1.0f);
        drawTextC(hudVerts, W * 0.5f, H * 0.62f, shopMsg, 2.4f, 1, 0.9f, 0.3f, a);
    }

    // ---------- 购买菜单 ----------
    if (shopOpen)
    {
        int   n   = WPN_COUNT - 1;            // 0 号是初始枪, 不卖
        float pw  = 600.0f;
        float ph  = 96.0f + n * 64.0f + 56.0f;
        float px  = (W - pw) * 0.5f, py = (H - ph) * 0.5f;
        rect2D(hudVerts, px, py, pw, ph, 0.05f, 0.07f, 0.10f, 0.92f);
        rectBorder(hudVerts, px, py, pw, ph, 3, 1, 0.8f, 0.2f, 1.0f);
        drawTextC(hudVerts, px + pw * 0.5f, py + 16.0f, "WEAPON SHOP", 2.8f, 1, 0.85f, 0.25f, 1);
        drawTextC(hudVerts, px + pw * 0.5f, py + 52.0f, format("CASH $%d", player.money), 2.0f, 1, 1, 1, 1);

        for (int i = 0; i < n; i++)
        {
            int   wi = i + 1;                 // 商品 1..n 对应武器索引 1..n
            float ry = py + 96.0f + i * 64.0f;
            bool  owned = player.owned[wi];
            const WeaponDef wd = WEAPONS[wi];

            rect2D(hudVerts, px + 24.0f, ry, pw - 48.0f, 56.0f, 1, 1, 1, owned ? 0.10f : 0.06f);
            if (i + 1 == player.weapon)
                rect2D(hudVerts, px + 24.0f, ry, pw - 48.0f, 56.0f, 1, 0.85f, 0.2f, 0.10f);

            string mode  = wd.fullAuto ? "AUTO" : "SEMI";
            string line1 = format("[%d] %s", i + 1, wd.name);
            string line2 = owned ? "OWNED - PRESS TO EQUIP"
                                 : format("$%d  DMG %d  %s  MAG %d%s", wd.price,
                                          cast(int) wd.damage, mode, wd.magSize,
                                          wd.pellets > 1 ? format(" x%d", wd.pellets) : "");
            drawText(hudVerts, px + 40.0f, ry + 6.0f, line1, 2.0f, 1, 1, 1, 1);
            drawText(hudVerts, px + 40.0f, ry + 32.0f, line2, 1.6f,
                     owned ? 0.4f : 1.0f, owned ? 1.0f : 0.85f, owned ? 0.4f : 0.3f, 1);
        }
        drawTextC(hudVerts, px + pw * 0.5f, py + ph - 34.0f,
                  "PRESS 1-5 TO BUY   B: CLOSE", 1.7f, 0.8f, 0.85f, 0.95f, 1);
    }

    // ---------- 结束 / 死亡画面 ----------
    if (gstate != GState.playing)
    {
        rect2D(hudVerts, 0, 0, W, H, 0, 0, 0, 0.62f);
        if (gstate == GState.won)
        {
            drawTextC(hudVerts, W * 0.5f, H * 0.36f, "MISSION COMPLETE", 6.0f, 0.4f, 1.0f, 0.5f, 1);
            drawTextC(hudVerts, W * 0.5f, H * 0.50f,
                      format("%d ELIMINATIONS   TIME %.1f S", player.kills, gameTime),
                      2.4f, 1, 1, 1, 1);
        }
        else if (gstate == GState.dead)
        {
            drawTextC(hudVerts, W * 0.5f, H * 0.36f, "YOU WERE ELIMINATED", 5.0f, 1.0f, 0.3f, 0.3f, 1);
            drawTextC(hudVerts, W * 0.5f, H * 0.50f,
                      format("%d / %d ELIMINATIONS", player.kills, KILL_TARGET),
                      2.4f, 1, 1, 1, 1);
        }
        drawTextC(hudVerts, W * 0.5f, H * 0.62f, "PRESS R TO RESTART", 2.6f, 1, 0.9f, 0.3f, 1);
    }

    // ---------- 提交 ----------
    if (hudVerts.length > 0)
    {
        glUseProgram(progFlat);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUniformMatrix4fv(f_locMVP, 1, GL_FALSE, ortho.m.ptr);
        glUniform4f(f_locColor, 1.0f, 1.0f, 1.0f, 1.0f);
        glBindVertexArray(flatVAO);
        glBindBuffer(GL_ARRAY_BUFFER, flatVBO);
        glBufferData(GL_ARRAY_BUFFER, cast(GLsizeiptr)(hudVerts.length * float.sizeof), hudVerts.ptr, GL_DYNAMIC_DRAW);
        glDrawArrays(GL_TRIANGLES, 0, cast(int)(hudVerts.length / 7));
        glDisable(GL_BLEND);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_CULL_FACE);
    }
}

//==============================================================================
// 主程序
//==============================================================================

/// 多路径尝试加载 GLFW (macOS 的 brew 装在 /opt/homebrew, FreeBSD 在 /usr/local/lib)
GLFWSupport loadGLFWAnywhere()
{
    GLFWSupport s = loadGLFW();
    if (s >= GLFWSupport.glfw32) return s;

    string[] candidates;
    version (OSX)
    {
        candidates = [
            "/opt/homebrew/lib/libglfw.3.dylib",
            "/usr/local/lib/libglfw.3.dylib",
            "/opt/local/lib/libglfw.3.dylib",
            "libglfw.3.dylib",
        ];
    }
    else version (FreeBSD)
    {
        candidates = [
            "/usr/local/lib/libglfw.so.3",
            "/usr/local/lib/libglfw.so",
            "libglfw.so.3",
        ];
    }
    else
    {
        candidates = [
            "libglfw.so.3",
            "/usr/lib/x86_64-linux-gnu/libglfw.so.3",
            "/usr/local/lib/libglfw.so.3",
        ];
    }

    foreach (p; candidates)
    {
        s = loadGLFW(p.toStringz);
        if (s >= GLFWSupport.glfw32) return s;
    }
    return s;
}

void main(string[] args)
{
    // ---- 命令行参数: 鼠标手感可以直接在启动时定好 ----
    foreach (a; args[1 .. $])
    {
        if (a == "--invert-y")      invertY = true;
        else if (a == "--invert-x") invertX = true;
        else if (a.length > 7 && a[0 .. 7] == "--sens=")
        {
            import std.conv : to;
            try
            {
                float v = to!float(a[7 .. $]);
                if (v > 0.0f) { sensX = v; sensY = v; }
            }
            catch (Exception) {}
        }
        else if (a == "--help" || a == "-h")
        {
            writeln("mini3dfps [--invert-x] [--invert-y] [--sens=0.0022]");
            writeln("In game : I = toggle invert Y | O = toggle invert X | [ ] = sensitivity");
            return;
        }
    }

    // ---- 加载 GLFW ----
    GLFWSupport glfwSup = loadGLFWAnywhere();
    if (glfwSup < GLFWSupport.glfw32)
    {
        writeln("GLFW 3.2+ not found. Install it first:");
        writeln("  Ubuntu/Debian : sudo apt install libglfw3-dev");
        writeln("  Fedora        : sudo dnf install glfw-devel");
        writeln("  Arch          : sudo pacman -S glfw");
        writeln("  FreeBSD       : pkg install glfw");
        writeln("  macOS         : brew install glfw");
        return;
    }

    if (!glfwInit()) { writeln("glfwInit failed"); return; }

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    version (OSX) glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);

    window = glfwCreateWindow(1280, 720, "mini3dfps - offline", null, null);
    if (window is null)
    {
        writeln("Failed to create window (need OpenGL 3.3 capable driver)");
        glfwTerminate();
        return;
    }
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    GLSupport glSup = loadOpenGL();
    if (glSup < GLSupport.gl33)
    {
        writeln("OpenGL 3.3+ not available, support = ", glSup);
        return;
    }
    writefln("GLFW %s / OpenGL loaded (support level %s)", glfwSup, glSup);

    glfwSetKeyCallback(window, &keyCB);
    glfwSetMouseButtonCallback(window, &mouseBtnCB);
    glfwSetCursorPosCallback(window, &cursorCB);
    glfwSetFramebufferSizeCallback(window, &fbSizeCB);
    setCursorCaptured(true);
    glfwSetInputMode(window, GLFW_STICKY_KEYS, GLFW_TRUE);
    glfwGetFramebufferSize(window, &fbW, &fbH);

    // ---- 着色器 / 缓冲 ----
    progMain = makeProgram(VS_MAIN, FS_MAIN);
    progFlat = makeProgram(VS_FLAT, FS_FLAT);
    m_locMVP   = glGetUniformLocation(progMain, "uMVP".toStringz);
    m_locModel = glGetUniformLocation(progMain, "uModel".toStringz);
    m_locColor = glGetUniformLocation(progMain, "uColor".toStringz);
    m_locLight = glGetUniformLocation(progMain, "uLightDir".toStringz);
    m_locCam   = glGetUniformLocation(progMain, "uCamPos".toStringz);
    m_locAmb   = glGetUniformLocation(progMain, "uAmbient".toStringz);
    m_locGrid  = glGetUniformLocation(progMain, "uGrid".toStringz);
    f_locMVP   = glGetUniformLocation(progFlat, "uMVP".toStringz);
    f_locColor = glGetUniformLocation(progFlat, "uColor".toStringz);

    buildBoxMesh();
    buildFlatBuffers();
    hudVerts.reserve(8192);
    lineVerts.reserve(1024);

    resetGame();

    writeln("Controls: WASD move | SPACE jump | SHIFT sprint | LMB fire | R reload");
    writeln("          1-6 switch weapon | B shop | ESC pause");
    writeln("Mouse   : I invert Y | O invert X | [ ] sensitivity");
    writefln("          invertX=%s invertY=%s sens=%.5f", invertX, invertY, sensX);

    double prev = glfwGetTime();
    double fpsAcc = 0.0; int fpsFrames = 0;

    while (!glfwWindowShouldClose(window))
    {
        double now = glfwGetTime();
        float dt = cast(float)(now - prev);
        prev = now;
        if (dt > 0.05f) dt = 0.05f;
        if (dt < 0.0f)  dt = 0.0f;

        fpsAcc += dt; fpsFrames++;
        if (fpsAcc > 0.5) { fps = cast(float)(fpsFrames / fpsAcc); fpsAcc = 0.0; fpsFrames = 0; }

        // ESC: 暂停 / 释放鼠标
        if (keyHit[GLFW_KEY_ESCAPE])
        {
            if (gstate == GState.playing)
            {
                gstate = GState.paused;
                setCursorCaptured(false);
            }
            else if (gstate == GState.paused)
            {
                gstate = GState.playing;
                setCursorCaptured(true);
            }
        }

        if (gstate != GState.paused) update(dt);

        renderScene(dt);
        renderHUD();

        // 清除边沿触发标记
        for (int i = 0; i < 512; i++) keyHit[i] = false;
        mousePressed = false;

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    glfwDestroyWindow(window);
    glfwTerminate();
}
