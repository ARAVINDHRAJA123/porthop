// Lists user-installed apps that share their Documents folder (UIFileSharingEnabled).
// Output: one app per line, "bundle-id<TAB>display name". Read-only.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

static char *str(plist_t dict, const char *key) {
    plist_t n = plist_dict_get_item(dict, key);
    char *s = NULL;
    if (n && plist_get_node_type(n) == PLIST_STRING) plist_get_string_val(n, &s);
    return s;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: applist UDID\n"); return 2; }
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, argv[1], IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK) != IDEVICE_E_SUCCESS) {
        fprintf(stderr, "ERROR: device not found\n"); return 1;
    }
    instproxy_client_t ip = NULL;
    if (instproxy_client_start_service(dev, &ip, "applist") != INSTPROXY_E_SUCCESS) {
        fprintf(stderr, "ERROR: could not start installation proxy\n"); idevice_free(dev); return 1;
    }
    plist_t opts = instproxy_client_options_new();
    instproxy_client_options_add(opts, "ApplicationType", "User", NULL);
    instproxy_client_options_set_return_attributes(opts, "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled", NULL);
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
            if (!on) continue;
            char *id = str(app, "CFBundleIdentifier");
            char *name = str(app, "CFBundleDisplayName");
            if (!name) name = str(app, "CFBundleName");
            if (id) printf("%s\t%s\n", id, name ? name : id);
            free(id); free(name);
        }
    }
    if (apps) plist_free(apps);
    instproxy_client_options_free(opts);
    instproxy_client_free(ip);
    idevice_free(dev);
    return rc;
}
