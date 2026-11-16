// A small file-copy tool for iPhone and iPad, used by the Windows app where the standard "afcclient"
// program is not available. It accepts the same commands this app sends to afcclient:
//
//   afcclient -u UDID [-n] [--documents BUNDLE] -- ls -l PATH
//   afcclient -u UDID [-n] [--documents BUNDLE] -- info PATH
//   afcclient -u UDID [-n] [--documents BUNDLE] -- get [-r] REMOTE LOCAL
//   afcclient -u UDID [-n] [--documents BUNDLE] -- put [-r] LOCAL REMOTE
//   afcclient -u UDID [-n] [--documents BUNDLE] -- mkdir PATH
//   afcclient -u UDID [-n]            (then lines on standard input: get "REMOTE" "LOCAL" ... quit)
//
// It never overwrites an existing file on either side and never deletes anything.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/house_arrest.h>
#include <plist/plist.h>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <direct.h>
#include <io.h>
#include <fcntl.h>
static wchar_t *wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = malloc(sizeof(wchar_t) * (n > 0 ? n : 1));
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n); else w[0] = 0;
    return w;
}
static FILE *open_local(const char *path, const char *mode) {
    wchar_t *w = wide(path), *m = wide(mode);
    FILE *f = _wfopen(w, m);
    free(w); free(m);
    return f;
}
static int local_exists(const char *path) { wchar_t *w = wide(path); DWORD a = GetFileAttributesW(w); free(w); return a != INVALID_FILE_ATTRIBUTES; }
static int local_is_dir(const char *path) { wchar_t *w = wide(path); DWORD a = GetFileAttributesW(w); free(w); return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY); }
static int local_mkdir(const char *path) { wchar_t *w = wide(path); int r = _wmkdir(w); free(w); return r; }
#define SEP '\\'
#else
#include <dirent.h>
static FILE *open_local(const char *path, const char *mode) { return fopen(path, mode); }
static int local_exists(const char *path) { struct stat st; return lstat(path, &st) == 0; }
static int local_is_dir(const char *path) { struct stat st; return stat(path, &st) == 0 && S_ISDIR(st.st_mode); }
static int local_mkdir(const char *path) { return mkdir(path, 0755); }
#define SEP '/'
#endif

#define CHUNK (1 << 20)
static afc_client_t afc = NULL;

static char *join(const char *a, char sep, const char *b) {
    size_t n = strlen(a);
    char *out = malloc(n + strlen(b) + 2);
    if (n == 0 || (n == 1 && a[0] == '.' && sep == '/')) { strcpy(out, b); return out; }
    strcpy(out, a);
    if (a[n - 1] != sep && a[n - 1] != '/') { out[n] = sep; out[n + 1] = 0; }
    strcat(out, b);
    return out;
}

// Reads one fact about a device file. Returns 0 when the file does not exist.
static int remote_info(const char *path, uint64_t *size, int *is_dir, int *is_link, time_t *mtime) {
    char **info = NULL;
    if (afc_get_file_info(afc, path, &info) != AFC_E_SUCCESS || !info) return 0;
    *size = 0; *is_dir = 0; *is_link = 0; *mtime = 0;
    for (int i = 0; info[i] && info[i + 1]; i += 2) {
        if (!strcmp(info[i], "st_size")) *size = strtoull(info[i + 1], NULL, 10);
        else if (!strcmp(info[i], "st_ifmt")) { *is_dir = !strcmp(info[i + 1], "S_IFDIR"); *is_link = !strcmp(info[i + 1], "S_IFLNK"); }
        else if (!strcmp(info[i], "st_mtime")) *mtime = (time_t)(strtoull(info[i + 1], NULL, 10) / 1000000000ULL);
    }
    afc_dictionary_free(info);
    return 1;
}

static int cmd_ls(const char *path) {
    char **list = NULL;
    if (afc_read_directory(afc, path, &list) != AFC_E_SUCCESS || !list) { printf("Error: cannot read folder\n"); return 1; }
    static const char *months[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (int i = 0; list[i]; i++) {
        if (!strcmp(list[i], ".") || !strcmp(list[i], "..")) continue;
        char *full = join(path, '/', list[i]);
        uint64_t size; int dir, link; time_t mt;
        if (remote_info(full, &size, &dir, &link, &mt)) {
            struct tm *tm = localtime(&mt);
            printf("%s %4d mobile mobile %10llu %2d %s %d %02d:%02d:%02d %s\n", dir ? "drwxr-xr-x" : (link ? "lrwxr-xr-x" : "-rw-r--r--"), 1,
                   (unsigned long long)size, tm ? tm->tm_mday : 1, months[tm ? tm->tm_mon : 0], tm ? tm->tm_year + 1900 : 1970,
                   tm ? tm->tm_hour : 0, tm ? tm->tm_min : 0, tm ? tm->tm_sec : 0, list[i]);
        }
        free(full);
    }
    afc_dictionary_free(list);
    return 0;
}

static int cmd_info(const char *path) {
    uint64_t size; int dir, link; time_t mt;
    if (!remote_info(path, &size, &dir, &link, &mt)) { printf("Error: no such file\n"); return 1; }
    printf("st_size: %llu\nst_ifmt: %s\nst_mtime: %lld\n", (unsigned long long)size, dir ? "S_IFDIR" : (link ? "S_IFLNK" : "S_IFREG"), (long long)mt);
    return 0;
}

static int get_file(const char *remote, const char *local) {
    if (local_exists(local)) { printf("Error: %s already exists, not overwriting\n", local); return 1; }
    uint64_t handle = 0;
    if (afc_file_open(afc, remote, AFC_FOPEN_RDONLY, &handle) != AFC_E_SUCCESS) { printf("Error: cannot open %s on the device\n", remote); return 1; }
    FILE *f = open_local(local, "wb");
    if (!f) { afc_file_close(afc, handle); printf("Error: cannot create %s\n", local); return 1; }
    char *buf = malloc(CHUNK);
    int rc = 0;
    for (;;) {
        uint32_t got = 0;
        if (afc_file_read(afc, handle, buf, CHUNK, &got) != AFC_E_SUCCESS) { rc = 1; break; }
        if (got == 0) break;
        if (fwrite(buf, 1, got, f) != got) { rc = 1; break; }
    }
    free(buf);
    if (fclose(f) != 0) rc = 1;
    afc_file_close(afc, handle);
    if (rc) printf("Error: copy of %s did not complete\n", remote);
    return rc;
}

static int get_tree(const char *remote, const char *local) {
    uint64_t size; int dir, link; time_t mt;
    if (!remote_info(remote, &size, &dir, &link, &mt)) { printf("Error: no such file %s\n", remote); return 1; }
    if (!dir) return get_file(remote, local);
    if (local_exists(local)) { printf("Error: %s already exists, not overwriting\n", local); return 1; }
    if (local_mkdir(local) != 0) { printf("Error: cannot create folder %s\n", local); return 1; }
    char **list = NULL;
    if (afc_read_directory(afc, remote, &list) != AFC_E_SUCCESS || !list) return 1;
    int rc = 0;
    for (int i = 0; list[i]; i++) {
        if (!strcmp(list[i], ".") || !strcmp(list[i], "..")) continue;
        char *r = join(remote, '/', list[i]), *l = join(local, SEP, list[i]);
        rc |= get_tree(r, l);
        free(r); free(l);
    }
    afc_dictionary_free(list);
    return rc;
}

static int put_file(const char *local, const char *remote) {
    uint64_t size; int dir, link; time_t mt;
    if (remote_info(remote, &size, &dir, &link, &mt)) { printf("Error: %s already exists on the device, not overwriting\n", remote); return 1; }
    FILE *f = open_local(local, "rb");
    if (!f) { printf("Error: cannot read %s\n", local); return 1; }
    uint64_t handle = 0;
    if (afc_file_open(afc, remote, AFC_FOPEN_WRONLY, &handle) != AFC_E_SUCCESS) { fclose(f); printf("Error: cannot create %s on the device\n", remote); return 1; }
    char *buf = malloc(CHUNK);
    int rc = 0;
    size_t n;
    while ((n = fread(buf, 1, CHUNK, f)) > 0) {
        size_t off = 0;
        while (off < n) {
            uint32_t wrote = 0;
            if (afc_file_write(afc, handle, buf + off, (uint32_t)(n - off), &wrote) != AFC_E_SUCCESS || wrote == 0) { rc = 1; break; }
            off += wrote;
        }
        if (rc) break;
    }
    if (ferror(f)) rc = 1;
    free(buf);
    fclose(f);
    afc_file_close(afc, handle);
    if (rc) printf("Error: copy of %s did not complete\n", local);
    return rc;
}

static int put_tree(const char *local, const char *remote) {
    if (!local_is_dir(local)) return put_file(local, remote);
    uint64_t size; int dir, link; time_t mt;
    if (remote_info(remote, &size, &dir, &link, &mt)) { printf("Error: %s already exists on the device, not overwriting\n", remote); return 1; }
    if (afc_make_directory(afc, remote) != AFC_E_SUCCESS) { printf("Error: cannot create folder %s on the device\n", remote); return 1; }
    int rc = 0;
#ifdef _WIN32
    char *pattern = join(local, SEP, "*");
    wchar_t *wp = wide(pattern);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(wp, &fd);
    free(wp); free(pattern);
    if (h == INVALID_HANDLE_VALUE) return 1;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        char name[1024];
        if (!WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof(name), NULL, NULL)) continue;
        char *l = join(local, SEP, name), *r = join(remote, '/', name);
        rc |= put_tree(l, r);
        free(l); free(r);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
#else
    DIR *d = opendir(local);
    if (!d) return 1;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char *l = join(local, SEP, e->d_name), *r = join(remote, '/', e->d_name);
        rc |= put_tree(l, r);
        free(l); free(r);
    }
    closedir(d);
#endif
    return rc;
}

// Splits one input line into words; double quotes group, backslash escapes the next character.
static int split(char *line, char **out, int max) {
    int n = 0;
    char *p = line;
    while (*p && n < max) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '\r' || *p == '\n') break;
        char *w = p, *dst = p;
        int quoted = 0;
        while (*p && *p != '\r' && *p != '\n' && (quoted || (*p != ' ' && *p != '\t'))) {
            if (*p == '"') { quoted = !quoted; p++; continue; }
            if (*p == '\\' && p[1]) p++;
            *dst++ = *p++;
        }
        if (*p) p++;
        *dst = 0;
        out[n++] = w;
    }
    return n;
}

static int run(int argc, char **argv) {
    if (argc < 1) return 2;
    const char *c = argv[0];
    int recursive = 0, a = 1;
    while (a < argc && argv[a][0] == '-' && argv[a][1]) { if (!strcmp(argv[a], "-r")) recursive = 1; a++; }
    if (!strcmp(c, "ls") && a < argc) return cmd_ls(argv[a]);
    if (!strcmp(c, "info") && a < argc) return cmd_info(argv[a]);
    if (!strcmp(c, "mkdir") && a < argc) {
        if (afc_make_directory(afc, argv[a]) != AFC_E_SUCCESS) { printf("Error: cannot create folder\n"); return 1; }
        return 0;
    }
    if (!strcmp(c, "get") && a + 1 < argc) return recursive ? get_tree(argv[a], argv[a + 1]) : get_file(argv[a], argv[a + 1]);
    if (!strcmp(c, "put") && a + 1 < argc) return recursive ? put_tree(argv[a], argv[a + 1]) : put_file(argv[a], argv[a + 1]);
    printf("Error: unknown command %s\n", c);
    return 2;
}

static int real_main(int argc, char **argv) {
    const char *udid = NULL, *bundle = NULL;
    int network = 0, i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { i++; break; }
        if (!strcmp(argv[i], "-u") && i + 1 < argc) udid = argv[++i];
        else if (!strcmp(argv[i], "-n")) network = 1;
        else if (!strcmp(argv[i], "--documents") && i + 1 < argc) bundle = argv[++i];
        else break;
    }
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, network ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
        printf("Error: device not found\n"); return 1;
    }
    lockdownd_client_t lockdown = NULL;
    if (lockdownd_client_new_with_handshake(dev, &lockdown, "afcmini") != LOCKDOWN_E_SUCCESS) {
        printf("Error: the device is locked or has not trusted this computer\n"); idevice_free(dev); return 1;
    }
    lockdownd_service_descriptor_t service = NULL;
    house_arrest_client_t arrest = NULL;
    int ok = 0;
    if (bundle) {
        if (lockdownd_start_service(lockdown, HOUSE_ARREST_SERVICE_NAME, &service) == LOCKDOWN_E_SUCCESS && service
            && house_arrest_client_new(dev, service, &arrest) == HOUSE_ARREST_E_SUCCESS
            && house_arrest_send_command(arrest, "VendDocuments", bundle) == HOUSE_ARREST_E_SUCCESS) {
            plist_t result = NULL;
            if (house_arrest_get_result(arrest, &result) == HOUSE_ARREST_E_SUCCESS && result) {
                ok = plist_dict_get_item(result, "Error") == NULL;
                plist_free(result);
            }
            if (ok) ok = afc_client_new_from_house_arrest_client(arrest, &afc) == AFC_E_SUCCESS;
        }
        if (!ok) printf("Error: this app does not share a folder\n");
    } else {
        ok = lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &service) == LOCKDOWN_E_SUCCESS && service
            && afc_client_new(dev, service, &afc) == AFC_E_SUCCESS;
        if (!ok) printf("Error: could not reach the device's file service\n");
    }
    lockdownd_client_free(lockdown);
    int rc = 1;
    if (ok) {
        if (i < argc) rc = run(argc - i, argv + i);
        else {
            rc = 0;
            char *line = malloc(1 << 16);
            while (fgets(line, 1 << 16, stdin)) {
                char *words[8];
                int n = split(line, words, 8);
                if (n == 0) continue;
                if (!strcmp(words[0], "quit") || !strcmp(words[0], "exit")) break;
                run(n, words);
                fflush(stdout);
            }
            free(line);
        }
    }
    if (afc) afc_client_free(afc);
    if (arrest) house_arrest_client_free(arrest);
    if (service) lockdownd_service_descriptor_free(service);
    idevice_free(dev);
    return rc;
}

#ifdef _WIN32
int main(void) {
    int argc = 0;
    wchar_t **wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
    char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        int n = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
        argv[i] = malloc(n > 0 ? n : 1);
        WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, argv[i], n, NULL, NULL);
    }
    _setmode(_fileno(stdin), _O_BINARY);
    SetConsoleOutputCP(CP_UTF8);
    return real_main(argc, argv);
}
#else
int main(int argc, char **argv) { return real_main(argc, argv); }
#endif
