// Offline Steam layer for Steamworks SDK 1.34/1.35 interfaces (SteamUser018, SteamFriends015,
// SteamUtils007, STEAMAPPS007, STEAMUSERSTATS011, STEAMREMOTESTORAGE013, ...).
// Interfaces are host objects whose vtables hold guest-callable host functions. Unknown
// methods return 0 and are logged once, by interface and vtable slot.
#include "rt.h"
#include "image.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

#define RET() (C.rsp += 8)
#define NSLOTS 128

enum { USER, FRIENDS, UTILS, APPS, USERSTATS, REMOTESTORAGE, MATCHMAKING, MATCHMAKINGSERVERS, NETWORKING, NIFACES };
static const char *iface_names[NIFACES] = {"ISteamUser", "ISteamFriends", "ISteamUtils", "ISteamApps", "ISteamUserStats",
                                           "ISteamRemoteStorage", "ISteamMatchmaking", "ISteamMatchmakingServers", "ISteamNetworking"};

typedef void (*SteamFn)(CPU *c);
typedef struct { uint64_t vtbl; int iface; } SteamObj;
static SteamObj objs[NIFACES];
static uint64_t vtbls[NIFACES][NSLOTS];
static SteamFn handlers[NIFACES][NSLOTS];
static uint8_t logged[NIFACES][NSLOTS];

// the logged-in Steam user (so saves land in the same My Games/<SteamID> folder as the original game)
static uint64_t steam_id = 76561197960265729ull;    // placeholder when no Steam login is found
#define STEAM_ID steam_id

#define TEST_STEAM_ID 76561197960265999ull       // RT_TEST_PROFILE=1: test runs never touch real saves

static void load_steam_id(void) {
    if (getenv("RT_TEST_PROFILE")) { steam_id = TEST_STEAM_ID; fprintf(stderr, "steam: test profile, saves isolated\n"); return; }
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Application Support/Steam/config/loginusers.vdf", getenv("HOME"));
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    uint64_t current = 0, first = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned long long id;
        if (sscanf(line, " \"%llu\"", &id) == 1 && id > 76561197960265728ull) { current = id; if (!first) first = id; }
        else if (current && strstr(line, "\"MostRecent\"") && strstr(line, "\"1\"")) { steam_id = current; fclose(f); return; }
    }
    if (first) steam_id = first;
    fclose(f);
}
static uint32_t app_id;

static void dispatch(CPU *c, int slot) {
    const SteamObj *o = (const SteamObj *)C.rdi;
    int i = o->iface;
    if (handlers[i][slot]) handlers[i][slot](c);
    else {
        if (!logged[i][slot]++) fprintf(stderr, "steam: %s vtable slot %d not implemented, returning 0\n", iface_names[i], slot);
        C.rax = 0;
    }
    RET();
}

#define SLOT(n) static void slot_##n(CPU *c) { dispatch(c, n); }
SLOT(0) SLOT(1) SLOT(2) SLOT(3) SLOT(4) SLOT(5) SLOT(6) SLOT(7) SLOT(8) SLOT(9) SLOT(10) SLOT(11) SLOT(12) SLOT(13) SLOT(14) SLOT(15)
SLOT(16) SLOT(17) SLOT(18) SLOT(19) SLOT(20) SLOT(21) SLOT(22) SLOT(23) SLOT(24) SLOT(25) SLOT(26) SLOT(27) SLOT(28) SLOT(29) SLOT(30) SLOT(31)
SLOT(32) SLOT(33) SLOT(34) SLOT(35) SLOT(36) SLOT(37) SLOT(38) SLOT(39) SLOT(40) SLOT(41) SLOT(42) SLOT(43) SLOT(44) SLOT(45) SLOT(46) SLOT(47)
SLOT(48) SLOT(49) SLOT(50) SLOT(51) SLOT(52) SLOT(53) SLOT(54) SLOT(55) SLOT(56) SLOT(57) SLOT(58) SLOT(59) SLOT(60) SLOT(61) SLOT(62) SLOT(63)
SLOT(64) SLOT(65) SLOT(66) SLOT(67) SLOT(68) SLOT(69) SLOT(70) SLOT(71) SLOT(72) SLOT(73) SLOT(74) SLOT(75) SLOT(76) SLOT(77) SLOT(78) SLOT(79)
SLOT(80) SLOT(81) SLOT(82) SLOT(83) SLOT(84) SLOT(85) SLOT(86) SLOT(87) SLOT(88) SLOT(89) SLOT(90) SLOT(91) SLOT(92) SLOT(93) SLOT(94) SLOT(95)
SLOT(96) SLOT(97) SLOT(98) SLOT(99) SLOT(100) SLOT(101) SLOT(102) SLOT(103) SLOT(104) SLOT(105) SLOT(106) SLOT(107) SLOT(108) SLOT(109) SLOT(110) SLOT(111)
SLOT(112) SLOT(113) SLOT(114) SLOT(115) SLOT(116) SLOT(117) SLOT(118) SLOT(119) SLOT(120) SLOT(121) SLOT(122) SLOT(123) SLOT(124) SLOT(125) SLOT(126) SLOT(127)
#undef SLOT
static gfn slot_fns[NSLOTS] = {
    slot_0, slot_1, slot_2, slot_3, slot_4, slot_5, slot_6, slot_7, slot_8, slot_9, slot_10, slot_11, slot_12, slot_13, slot_14, slot_15,
    slot_16, slot_17, slot_18, slot_19, slot_20, slot_21, slot_22, slot_23, slot_24, slot_25, slot_26, slot_27, slot_28, slot_29, slot_30, slot_31,
    slot_32, slot_33, slot_34, slot_35, slot_36, slot_37, slot_38, slot_39, slot_40, slot_41, slot_42, slot_43, slot_44, slot_45, slot_46, slot_47,
    slot_48, slot_49, slot_50, slot_51, slot_52, slot_53, slot_54, slot_55, slot_56, slot_57, slot_58, slot_59, slot_60, slot_61, slot_62, slot_63,
    slot_64, slot_65, slot_66, slot_67, slot_68, slot_69, slot_70, slot_71, slot_72, slot_73, slot_74, slot_75, slot_76, slot_77, slot_78, slot_79,
    slot_80, slot_81, slot_82, slot_83, slot_84, slot_85, slot_86, slot_87, slot_88, slot_89, slot_90, slot_91, slot_92, slot_93, slot_94, slot_95,
    slot_96, slot_97, slot_98, slot_99, slot_100, slot_101, slot_102, slot_103, slot_104, slot_105, slot_106, slot_107, slot_108, slot_109, slot_110, slot_111,
    slot_112, slot_113, slot_114, slot_115, slot_116, slot_117, slot_118, slot_119, slot_120, slot_121, slot_122, slot_123, slot_124, slot_125, slot_126, slot_127,
};

// ---------- achievements and stats, kept locally ----------
static char store_path[1024];
#define MAX_ACH 256
static struct { char name[64]; int unlocked; uint32_t time; } ach[MAX_ACH];
static int nach;
static pthread_mutex_t ach_lock = PTHREAD_MUTEX_INITIALIZER;

static void ach_save(void) {
    FILE *f = fopen(store_path, "w");
    if (!f) return;
    for (int k = 0; k < nach; k++) if (ach[k].unlocked) fprintf(f, "%s %u\n", ach[k].name, ach[k].time);
    fclose(f);
}
static void ach_load(void) {
    const char *home = getenv("HOME");
    snprintf(store_path, sizeof store_path, "%s/Library/Application Support/ShadowComplexRecomp", home ? home : ".");
    mkdir(store_path, 0755);
    strlcat(store_path, "/achievements.txt", sizeof store_path);
    FILE *f = fopen(store_path, "r");
    if (!f) return;
    char name[64]; unsigned t;
    while (nach < MAX_ACH && fscanf(f, "%63s %u", name, &t) == 2) {
        strlcpy(ach[nach].name, name, sizeof ach[nach].name);
        ach[nach].unlocked = 1; ach[nach].time = t; nach++;
    }
    fclose(f);
}
static int ach_find(const char *name, int create) {
    for (int k = 0; k < nach; k++) if (!strcmp(ach[k].name, name)) return k;
    if (!create || nach == MAX_ACH) return -1;
    strlcpy(ach[nach].name, name, sizeof ach[nach].name);
    return nach++;
}

// ---------- callbacks ----------
// CCallbackBase: { vtable; uint8 m_nCallbackFlags; int m_iCallback; }  vtable: Run(void*), Run(void*, bool, SteamAPICall_t), GetCallbackSizeBytes()
#define MAX_CB 256
static struct { uint64_t obj; int id; } callbacks[MAX_CB];
static int ncallbacks;
typedef struct { int id; uint8_t data[64]; } Event;
static Event events[64];
static int nevents;
static pthread_mutex_t ev_lock = PTHREAD_MUTEX_INITIALIZER;

static void post(int id, const void *data, size_t n) {
    pthread_mutex_lock(&ev_lock);
    if (nevents < 64) { events[nevents].id = id; memcpy(events[nevents].data, data, n); nevents++; }
    pthread_mutex_unlock(&ev_lock);
}

void I__SteamAPI_RegisterCallback(CPU *c) {
    if (ncallbacks < MAX_CB) callbacks[ncallbacks++] = (typeof(callbacks[0])){C.rdi, (int)C.rsi};
    wr8(C.rdi + 8, rd8(C.rdi + 8) | 1);        // k_ECallbackFlagsRegistered
    RET();
}
void I__SteamAPI_UnregisterCallback(CPU *c) {
    for (int k = 0; k < ncallbacks; k++) if (callbacks[k].obj == C.rdi) callbacks[k] = callbacks[--ncallbacks];
    RET();
}
void I__SteamAPI_RunCallbacks(CPU *c) {
    pthread_mutex_lock(&ev_lock);
    Event q[64]; int n = nevents; memcpy(q, events, sizeof(Event) * n); nevents = 0;
    pthread_mutex_unlock(&ev_lock);
    CPU saved = *c;
    for (int e = 0; e < n; e++)
        for (int k = 0; k < ncallbacks; k++)
            if (callbacks[k].id == q[e].id) {
                uint64_t obj = callbacks[k].obj;
                C.rdi = obj; C.rsi = (uint64_t)q[e].data;
                PUSH(0);
                call_ind(c, rd64(rd64(obj)));         // virtual void Run(void *pvParam)
            }
    uint64_t sp = saved.rsp; *c = saved; C.rsp = sp;
    RET();
}

// ---------- method handlers ----------
static void ret_true(CPU *c) { C.rax = 1; }
static void ret_str(CPU *c, const char *s) { C.rax = (uint64_t)s; }

static void user_GetSteamID(CPU *c) { C.rax = STEAM_ID; }          // CSteamID returned in rax
static void friends_GetPersonaName(CPU *c) { ret_str(c, "Player"); }
static void utils_GetIPCountry(CPU *c) { ret_str(c, "US"); }
static void utils_GetAppID(CPU *c) { C.rax = app_id; }
static void utils_GetSteamUILanguage(CPU *c) { ret_str(c, "english"); }
static void apps_GetCurrentGameLanguage(CPU *c) { ret_str(c, "english"); }
static void apps_GetAvailableGameLanguages(CPU *c) { ret_str(c, "english"); }

// UserStatsReceived_t (1101): { uint64 m_nGameID; EResult m_eResult; CSteamID m_steamIDUser; }
static void stats_RequestCurrentStats(CPU *c) {
    uint8_t ev[24] = {0};
    uint64_t game = app_id, user = STEAM_ID; int32_t ok = 1;
    memcpy(ev, &game, 8); memcpy(ev + 8, &ok, 4); memcpy(ev + 16, &user, 8);
    post(1101, ev, sizeof ev);
    C.rax = 1;
}
static void stats_GetStatInt(CPU *c) { wr32(C.rdx, 0); C.rax = 1; }
static void stats_GetStatFloat(CPU *c) { wrf(C.rdx, 0); C.rax = 1; }
static void stats_GetAchievement(CPU *c) {
    pthread_mutex_lock(&ach_lock);
    int k = ach_find((const char *)C.rsi, 0);
    wr8(C.rdx, k >= 0 && ach[k].unlocked);
    pthread_mutex_unlock(&ach_lock);
    C.rax = 1;
}
static void stats_SetAchievement(CPU *c) {
    pthread_mutex_lock(&ach_lock);
    int k = ach_find((const char *)C.rsi, 1);
    if (k >= 0 && !ach[k].unlocked) {
        ach[k].unlocked = 1; ach[k].time = (uint32_t)time(0); ach_save();
        fprintf(stderr, "steam: achievement unlocked: %s\n", ach[k].name);
    }
    pthread_mutex_unlock(&ach_lock);
    C.rax = 1;
}
static void stats_ClearAchievement(CPU *c) {
    pthread_mutex_lock(&ach_lock);
    int k = ach_find((const char *)C.rsi, 0);
    if (k >= 0) { ach[k].unlocked = 0; ach_save(); }
    pthread_mutex_unlock(&ach_lock);
    C.rax = 1;
}
// UserStatsStored_t (1102): { uint64 m_nGameID; EResult m_eResult; }
static void stats_StoreStats(CPU *c) {
    uint8_t ev[16] = {0};
    uint64_t game = app_id; int32_t ok = 1;
    memcpy(ev, &game, 8); memcpy(ev + 8, &ok, 4);
    post(1102, ev, sizeof ev);
    C.rax = 1;
}

static uint64_t make_iface(int i) {
    for (int s = 0; s < NSLOTS; s++) vtbls[i][s] = rt_host_fn(slot_fns[s]);
    objs[i].vtbl = (uint64_t)vtbls[i];
    objs[i].iface = i;
    return (uint64_t)&objs[i];
}

static int inited;
static void steam_init(void) {
    if (inited++) return;
    FILE *f = fopen("steam_appid.txt", "r");
    if (f) { if (fscanf(f, "%u", &app_id) != 1) app_id = 0; fclose(f); }
    if (!app_id) app_id = 385560;            // Shadow Complex Remastered
    load_steam_id();
    ach_load();
    handlers[USER][1] = ret_true;            // BLoggedOn
    handlers[USER][2] = user_GetSteamID;
    handlers[FRIENDS][0] = friends_GetPersonaName;
    handlers[UTILS][4] = utils_GetIPCountry;
    handlers[UTILS][9] = utils_GetAppID;
    handlers[UTILS][23] = utils_GetSteamUILanguage;
    handlers[APPS][0] = ret_true;            // BIsSubscribed
    handlers[APPS][4] = apps_GetCurrentGameLanguage;
    handlers[APPS][5] = apps_GetAvailableGameLanguages;
    handlers[APPS][6] = ret_true;            // BIsSubscribedApp
    handlers[USERSTATS][0] = stats_RequestCurrentStats;
    handlers[USERSTATS][1] = stats_GetStatInt;
    handlers[USERSTATS][2] = stats_GetStatFloat;
    handlers[USERSTATS][3] = ret_true;       // SetStat(int)
    handlers[USERSTATS][4] = ret_true;       // SetStat(float)
    handlers[USERSTATS][5] = ret_true;       // UpdateAvgRateStat
    handlers[USERSTATS][6] = stats_GetAchievement;
    handlers[USERSTATS][7] = stats_SetAchievement;
    handlers[USERSTATS][8] = stats_ClearAchievement;
    handlers[USERSTATS][10] = stats_StoreStats;
    for (int i = 0; i < NIFACES; i++) make_iface(i);
}

void I__SteamAPI_Init(CPU *c) { steam_init(); C.rax = 1; RET(); }
void I__SteamAPI_RestartAppIfNecessary(CPU *c) { C.rax = 0; RET(); }
#define ACCESSOR(fn, i) void I__##fn(CPU *c) { steam_init(); C.rax = (uint64_t)&objs[i]; RET(); }
ACCESSOR(SteamUser, USER) ACCESSOR(SteamFriends, FRIENDS) ACCESSOR(SteamUtils, UTILS) ACCESSOR(SteamApps, APPS)
ACCESSOR(SteamUserStats, USERSTATS) ACCESSOR(SteamRemoteStorage, REMOTESTORAGE) ACCESSOR(SteamMatchmaking, MATCHMAKING)
ACCESSOR(SteamMatchmakingServers, MATCHMAKINGSERVERS) ACCESSOR(SteamNetworking, NETWORKING)
// no dedicated server support offline
void I__SteamGameServer_Init(CPU *c) { C.rax = 0; RET(); }
void I__SteamGameServer_Shutdown(CPU *c) { RET(); }
void I__SteamGameServer_RunCallbacks(CPU *c) { RET(); }
void I__SteamGameServer_GetSteamID(CPU *c) { C.rax = 0; RET(); }
void I__SteamGameServer(CPU *c) { C.rax = 0; RET(); }
void I__SteamGameServerStats(CPU *c) { C.rax = 0; RET(); }
void I__SteamGameServerNetworking(CPU *c) { C.rax = 0; RET(); }
void I__SteamGameServerUtils(CPU *c) { C.rax = 0; RET(); }
