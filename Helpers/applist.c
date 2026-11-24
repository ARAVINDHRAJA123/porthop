// PortHop's small iPhone helper. Read-only unless asked to install or remove an app, or to change the Wi-Fi setting.
//   applist UDID                  apps that share their Documents folder (UIFileSharingEnabled): "bundle-id<TAB>name"
//   applist UDID --all            every app the user installed: "bundle-id<TAB>name<TAB>version<TAB>bytes"
//   applist UDID --install FILE   installs an .ipa that is signed for this device; prints "PROGRESS n" lines, then "OK"
//   applist UDID --uninstall ID   removes one app with its data; prints "OK"
//   applist UDID --wifi [on|off]  shows or sets "Show this iPhone when on Wi-Fi" (needed for Wi-Fi backups); prints "on" or "off"
// Add -n after the UDID to reach the device over Wi-Fi. Errors go to stderr as "ERROR: ...", with exit code 1.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <plist/plist.h>
#ifdef _WIN32
#include <windows.h>
static void nap(void) { Sleep(100); }
#else
#include <unistd.h>
static void nap(void) { usleep(100000); }
#endif

static char *str(plist_t dict, const char *key) {
    plist_t n = plist_dict_get_item(dict, key);
    char *s = NULL;
    if (n && plist_get_node_type(n) == PLIST_STRING) plist_get_string_val(n, &s);
    return s;
}

static uint64_t num(plist_t dict, const char *key) {
    plist_t n = plist_dict_get_item(dict, key);
    uint64_t v = 0;
    if (n && plist_get_node_type(n) == PLIST_UINT) plist_get_uint_val(n, &v);
    return v;
}

// Names are printed between tabs, one app per line: tabs and line breaks inside a name become spaces.
static void clean(char *s) { for (; s && *s; s++) if (*s == '\t' || *s == '\n' || *s == '\r') *s = ' '; }

static int fail(const char *what) { fprintf(stderr, "ERROR: %s\n", what); return 1; }

static int list(instproxy_client_t ip, int all) {
    plist_t opts = instproxy_client_options_new();
    instproxy_client_options_add(opts, "ApplicationType", "User", NULL);
    instproxy_client_options_set_return_attributes(opts, "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled",
                                                   "CFBundleShortVersionString", "CFBundleVersion", "StaticDiskUsage", "DynamicDiskUsage", NULL);
    plist_t apps = NULL;
    int rc = 1;
    if (instproxy_browse(ip, opts, &apps) == INSTPROXY_E_SUCCESS && apps && plist_get_node_type(apps) == PLIST_ARRAY) {
        rc = 0;
        uint32_t n = plist_array_get_size(apps);
        for (uint32_t i = 0; i < n; i++) {
            plist_t app = plist_array_get_item(apps, i);
            plist_t share = plist_dict_get_item(app, "UIFileSharingEnabled");
            uint8_t on = 0;
            if (share && plist_get_node_type(share) == PLIST_BOOLEAN) plist_get_bool_val(share, &on);
            if (!all && !on) continue;
            char *id = str(app, "CFBundleIdentifier");
            char *name = str(app, "CFBundleDisplayName");
            if (!name) name = str(app, "CFBundleName");
            clean(name);
            if (id && all) {
                char *version = str(app, "CFBundleShortVersionString");
                if (!version) version = str(app, "CFBundleVersion");
                clean(version);
                printf("%s\t%s\t%s\t%llu\n", id, name ? name : id, version ? version : "",
                       (unsigned long long)(num(app, "StaticDiskUsage") + num(app, "DynamicDiskUsage")));
                free(version);
            } else if (id) {
                printf("%s\t%s\n", id, name ? name : id);
            }
            free(id); free(name);
        }
    }
    if (apps) plist_free(apps);
    instproxy_client_options_free(opts);
    return rc;
}

// Install and remove report back on another thread; the main thread waits for "Complete" or an error.
static volatile int finished = 0;
static char problem[512];

static void status_cb(plist_t command, plist_t status, void *unused) {
    (void)command; (void)unused;
    char *name = NULL, *description = NULL;
    uint64_t code = 0;
    if (instproxy_status_get_error(status, &name, &description, &code) != INSTPROXY_E_SUCCESS) {
        snprintf(problem, sizeof problem, "%s%s%s", name ? name : "Failed", description ? ": " : "", description ? description : "");
        finished = 1;
    } else {
        int percent = -1;
        instproxy_status_get_percent_complete(status, &percent);
        char *state = str(status, "Status");
        if (percent >= 0) { printf("PROGRESS %d\n", percent); fflush(stdout); }
        if (state && strcmp(state, "Complete") == 0) finished = 1;
        free(state);
    }
    free(name); free(description);
}

static int wait_done(instproxy_error_t started) {
    if (started != INSTPROXY_E_SUCCESS) return fail("the iPhone did not accept the request");
    for (int waited = 0; !finished && waited < 6000; waited++) nap();   // up to 10 minutes
    if (!finished) return fail("the iPhone did not finish in time");
    if (problem[0]) return fail(problem);
    printf("OK\n");
    return 0;
}

// Copies the .ipa into the iPhone's staging folder, where the installer picks it up.
static int upload(idevice_t dev, const char *local, const char *remote) {
    FILE *f = fopen(local, "rb");
    if (!f) return fail("could not open the file");
    afc_client_t afc = NULL;
    if (afc_client_start_service(dev, &afc, "applist") != AFC_E_SUCCESS) { fclose(f); return fail("could not reach the iPhone's file service"); }
    afc_make_directory(afc, "PublicStaging");
    uint64_t handle = 0;
    int rc = 0;
    if (afc_file_open(afc, remote, AFC_FOPEN_WRONLY, &handle) != AFC_E_SUCCESS) rc = fail("could not write to the iPhone");
    static char buf[1 << 20];
    size_t got;
    while (!rc && (got = fread(buf, 1, sizeof buf, f)) > 0) {
        uint32_t off = 0;
        while (off < got) {
            uint32_t wrote = 0;
            if (afc_file_write(afc, handle, buf + off, (uint32_t)(got - off), &wrote) != AFC_E_SUCCESS || wrote == 0) { rc = fail("copying to the iPhone stopped"); break; }
            off += wrote;
        }
    }
    if (handle) afc_file_close(afc, handle);
    afc_client_free(afc);
    fclose(f);
    return rc;
}

static int wifi(idevice_t dev, const char *want) {
    lockdownd_client_t lc = NULL;
    if (lockdownd_client_new_with_handshake(dev, &lc, "applist") != LOCKDOWN_E_SUCCESS) return fail("the iPhone did not answer; unlock it and tap Trust");
    const char *domain = "com.apple.mobile.wireless_lockdown", *key = "EnableWifiConnections";
    int rc = 0;
    if (want) {
        if (lockdownd_set_value(lc, domain, key, plist_new_bool(strcmp(want, "on") == 0)) != LOCKDOWN_E_SUCCESS) rc = fail("the iPhone refused the change");
    }
    plist_t node = NULL;
    uint8_t on = 0;
    if (!rc && lockdownd_get_value(lc, domain, key, &node) == LOCKDOWN_E_SUCCESS && node && plist_get_node_type(node) == PLIST_BOOLEAN) plist_get_bool_val(node, &on);
    if (node) plist_free(node);
    if (!rc) printf("%s\n", on ? "on" : "off");
    lockdownd_client_free(lc);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: applist UDID [-n] [--all | --install FILE.ipa | --uninstall BUNDLE-ID | --wifi [on|off]]\n"); return 2; }
    int a = 2, network = 0;
    if (a < argc && strcmp(argv[a], "-n") == 0) { network = 1; a++; }
    const char *cmd = a < argc ? argv[a] : "";
    const char *arg = a + 1 < argc ? argv[a + 1] : NULL;
    if ((!strcmp(cmd, "--install") || !strcmp(cmd, "--uninstall")) && !arg) { fprintf(stderr, "usage: %s needs a value\n", cmd); return 2; }
    if (!strcmp(cmd, "--wifi") && arg && strcmp(arg, "on") && strcmp(arg, "off")) { fprintf(stderr, "usage: --wifi on or off\n"); return 2; }

    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, argv[1], network ? IDEVICE_LOOKUP_NETWORK : (IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK)) != IDEVICE_E_SUCCESS)
        return fail("device not found");
    int rc;
    if (!strcmp(cmd, "--wifi")) { rc = wifi(dev, arg); idevice_free(dev); return rc; }

    instproxy_client_t ip = NULL;
    if (instproxy_client_start_service(dev, &ip, "applist") != INSTPROXY_E_SUCCESS) { idevice_free(dev); return fail("could not start installation proxy"); }
    if (!strcmp(cmd, "--uninstall")) {
        rc = wait_done(instproxy_uninstall(ip, arg, NULL, status_cb, NULL));
    } else if (!strcmp(cmd, "--install")) {
        const char *base = strrchr(arg, '/');
        const char *back = strrchr(arg, '\\');
        if (back && (!base || back > base)) base = back;
        base = base ? base + 1 : arg;
        char remote[1024];
        snprintf(remote, sizeof remote, "PublicStaging/%s", base);
        rc = upload(dev, arg, remote);
        if (!rc) {
            plist_t opts = instproxy_client_options_new();
            rc = wait_done(instproxy_install(ip, remote, opts, status_cb, NULL));
            instproxy_client_options_free(opts);
        }
    } else {
        rc = list(ip, !strcmp(cmd, "--all"));
    }
    instproxy_client_free(ip);
    idevice_free(dev);
    return rc;
}
