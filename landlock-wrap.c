#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>

#define PATH_MAX_LEN 4096
#define MAX_PATHS 64

/* ---- Landlock ABI (kernel 5.13+) ---- */

#ifndef LANDLOCK_ACCESS_FS_EXECUTE
#define LANDLOCK_ACCESS_FS_EXECUTE         (1ULL << 0)
#define LANDLOCK_ACCESS_FS_WRITE_FILE      (1ULL << 1)
#define LANDLOCK_ACCESS_FS_READ_FILE       (1ULL << 2)
#define LANDLOCK_ACCESS_FS_READ_DIR        (1ULL << 3)
#define LANDLOCK_ACCESS_FS_REMOVE_DIR      (1ULL << 4)
#define LANDLOCK_ACCESS_FS_REMOVE_FILE     (1ULL << 5)
#define LANDLOCK_ACCESS_FS_MAKE_CHAR       (1ULL << 6)
#define LANDLOCK_ACCESS_FS_MAKE_DIR        (1ULL << 7)
#define LANDLOCK_ACCESS_FS_MAKE_REG        (1ULL << 8)
#define LANDLOCK_ACCESS_FS_MAKE_SOCK       (1ULL << 9)
#define LANDLOCK_ACCESS_FS_MAKE_FIFO       (1ULL << 10)
#define LANDLOCK_ACCESS_FS_MAKE_BLOCK      (1ULL << 11)
#define LANDLOCK_ACCESS_FS_MAKE_SYM        (1ULL << 12)
#define LANDLOCK_ACCESS_FS_REFER           (1ULL << 13)
#define LANDLOCK_ACCESS_FS_TRUNCATE        (1ULL << 14)
#endif

#ifndef LANDLOCK_RULE_PATH_BENEATH
#define LANDLOCK_RULE_PATH_BENEATH 1
#endif

#ifndef SYS_landlock_create_ruleset
#ifdef __x86_64__
#define SYS_landlock_create_ruleset  444
#define SYS_landlock_add_rule        445
#define SYS_landlock_restrict_self   446
#else
#define SYS_landlock_create_ruleset  444
#define SYS_landlock_add_rule        445
#define SYS_landlock_restrict_self   446
#endif
#endif

struct ll_ruleset_attr {
    unsigned long long handled_access_fs;
};

struct ll_path_beneath_attr {
    unsigned long long allowed_access;
    int parent_fd;
} __attribute__((packed));

/* ---- Filesystem access masks ---- */

/* Full access for write-allowed directories */
#define ACCESS_FS_RO (LANDLOCK_ACCESS_FS_EXECUTE | \
                      LANDLOCK_ACCESS_FS_READ_FILE | \
                      LANDLOCK_ACCESS_FS_READ_DIR)

#define ACCESS_FS_RW (ACCESS_FS_RO | \
                      LANDLOCK_ACCESS_FS_WRITE_FILE | \
                      LANDLOCK_ACCESS_FS_REMOVE_DIR | \
                      LANDLOCK_ACCESS_FS_REMOVE_FILE | \
                      LANDLOCK_ACCESS_FS_MAKE_DIR | \
                      LANDLOCK_ACCESS_FS_MAKE_REG | \
                      LANDLOCK_ACCESS_FS_MAKE_SOCK | \
                      LANDLOCK_ACCESS_FS_MAKE_FIFO | \
                      LANDLOCK_ACCESS_FS_MAKE_SYM | \
                      LANDLOCK_ACCESS_FS_REFER | \
                      LANDLOCK_ACCESS_FS_TRUNCATE)

/* Any access right not in the handled set is implicitly allowed by the
 * kernel regardless of ruleset entries.  MAKE_CHAR and MAKE_BLOCK
 * require CAP_MKNOD (dropped by NoNewPrivs) but are included for
 * defense-in-depth in case privileges change. */
#define ACCESS_FS_HANDLED (ACCESS_FS_RW | \
                           LANDLOCK_ACCESS_FS_MAKE_CHAR | \
                           LANDLOCK_ACCESS_FS_MAKE_BLOCK)

/* ---- Utilities ---- */

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int has_marker(const char *dir) {
    char path[8192];
    snprintf(path, sizeof(path), "%s/.git", dir);
    if (is_dir(path)) return 1;
    snprintf(path, sizeof(path), "%s/.sandbox-root", dir);
    if (is_dir(path)) return 1;
    return 0;
}

static char *find_project_root(void) {
    char cwd[PATH_MAX_LEN];
    if (!getcwd(cwd, sizeof(cwd))) return NULL;

    char *dir = cwd;
    while (1) {
        if (has_marker(dir)) return strdup(dir);
        char *slash = strrchr(dir, '/');
        if (!slash || slash == dir) break;
        *slash = '\0';
    }
    return NULL;
}

static char *expand_home(const char *path) {
    if (path[0] == '~') {
        const char *home = getenv("HOME");
        if (!home) return NULL;
        char *expanded = malloc(PATH_MAX_LEN);
        snprintf(expanded, PATH_MAX_LEN, "%s%s", home, path + 1);
        return expanded;
    }
    return strdup(path);
}

/* ---- Path list ---- */

typedef struct {
    char *paths[MAX_PATHS];
    int count;
} PathList;

static void pl_add(PathList *pl, const char *path) {
    if (pl->count >= MAX_PATHS) return;
    char *expanded = expand_home(path);
    if (expanded) pl->paths[pl->count++] = expanded;
}

static void pl_free(PathList *pl) {
    for (int i = 0; i < pl->count; i++) free(pl->paths[i]);
}

static void build_ruleset(PathList *writes, PathList *reads, char **extra_writes, int extra_write_count) {
    char *project_root = find_project_root();
    if (!project_root) {
        fprintf(stderr, "landlock-wrap: no project marker (.git or .sandbox-root) found\n");
        exit(1);
    }

    /* Built-in write-allowed paths */
    pl_add(writes, project_root);
    pl_add(writes, "/tmp");
    pl_add(writes, "~/.cache");
    pl_add(writes, "~/.local/share");
    pl_add(writes, "~/.local/state");
    pl_add(writes, "~/.config");
    pl_add(writes, "~/.claude");
    pl_add(writes, "~/.agents");
    pl_add(writes, "~/.npm");

    /* HOME kept read-only. ~/.claude.json writes are redirected to
     * ~/.claude/config.json via a symlink set up by claude-sandboxed. */
    pl_add(reads, "/usr");
    pl_add(reads, "/lib");
    pl_add(reads, "/lib64");
    pl_add(reads, "/proc");
    pl_add(reads, "/sys");
    pl_add(reads, "/etc");
    pl_add(reads, "/run");
    pl_add(reads, "~/.nvm");

    /* /dev needs write access (git writes to /dev/null) */
    pl_add(writes, "/dev");

    /* Extra --write paths */
    for (int i = 0; i < extra_write_count; i++)
        pl_add(writes, extra_writes[i]);

    free(project_root);
}

/* ---- GitHub PAT setup ---- */

static void setup_github_token(void) {
    const char *token = getenv("LANDLOCK_GITHUB_TOKEN");
    if (!token) return;

    setenv("GITHUB_TOKEN", token, 1);
    unsetenv("SSH_AUTH_SOCK");
    unsetenv("SSH_AGENT_PID");

    char url_key[PATH_MAX_LEN];
    snprintf(url_key, sizeof(url_key),
             "url.https://x-access-token:%s@github.com/.insteadOf", token);
    setenv("GIT_CONFIG_COUNT", "2", 1);
    setenv("GIT_CONFIG_KEY_0", url_key, 1);
    setenv("GIT_CONFIG_VALUE_0", "git@github.com:", 1);
    setenv("GIT_CONFIG_KEY_1", "credential.helper", 1);
    setenv("GIT_CONFIG_VALUE_1", "", 1);
}

/* ---- Landlock operations ---- */

static int apply_landlock(PathList *writes, PathList *reads) {
    struct ll_ruleset_attr ruleset_attr = {
        .handled_access_fs = ACCESS_FS_HANDLED,
    };

    int ruleset_fd = syscall(SYS_landlock_create_ruleset, &ruleset_attr, sizeof(ruleset_attr), 0);
    if (ruleset_fd < 0) {
        perror("landlock-create-ruleset");
        return -1;
    }

    /* Add write-allowed paths */
    for (int i = 0; i < writes->count; i++) {
        int dir_fd = open(writes->paths[i], O_PATH | O_DIRECTORY);
        if (dir_fd < 0) continue; /* skip paths that don't exist */

        struct ll_path_beneath_attr path_attr = {
            .allowed_access = ACCESS_FS_RW,
            .parent_fd = dir_fd,
        };

        int ret = syscall(SYS_landlock_add_rule, ruleset_fd,
                          LANDLOCK_RULE_PATH_BENEATH, &path_attr, 0);
        close(dir_fd);
        if (ret < 0) {
            fprintf(stderr, "landlock-wrap: add_rule(write:%s): %s\n",
                    writes->paths[i], strerror(errno));
        }
    }

    /* Add read-only paths */
    for (int i = 0; i < reads->count; i++) {
        int dir_fd = open(reads->paths[i], O_PATH | O_DIRECTORY);
        if (dir_fd < 0) continue;

        struct ll_path_beneath_attr path_attr = {
            .allowed_access = ACCESS_FS_RO,
            .parent_fd = dir_fd,
        };

        int ret = syscall(SYS_landlock_add_rule, ruleset_fd,
                          LANDLOCK_RULE_PATH_BENEATH, &path_attr, 0);
        close(dir_fd);
        if (ret < 0) {
            fprintf(stderr, "landlock-wrap: add_rule(read:%s): %s\n",
                    reads->paths[i], strerror(errno));
        }
    }

    /* Required before applying Landlock */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
        perror("prctl(NO_NEW_PRIVS)");
        close(ruleset_fd);
        return -1;
    }

    /* Lock it in */
    if (syscall(SYS_landlock_restrict_self, ruleset_fd, 0) < 0) {
        perror("landlock-restrict-self");
        close(ruleset_fd);
        return -1;
    }
    close(ruleset_fd);
    return 0;
}

/* ---- Main ---- */

static void dump_ruleset(PathList *writes, PathList *reads) {
    for (int i = 0; i < writes->count; i++)
        printf("write:%s\n", writes->paths[i]);
    for (int i = 0; i < reads->count; i++)
        printf("read:%s\n", reads->paths[i]);
}

static void usage(void) {
    fprintf(stderr, "Usage: landlock-wrap [--print-project-root | --dump-ruleset [--write PATH]... | -- COMMAND...]\n");
}

int main(int argc, char **argv) {
    /* Diagnostic modes (no Landlock applied) */
    if (argc >= 2 && strcmp(argv[1], "--print-project-root") == 0) {
        char *root = find_project_root();
        if (root) {
            printf("%s\n", root);
            free(root);
            return 0;
        }
        return 1;
    }

    if (argc >= 2 && strcmp(argv[1], "--dump-ruleset") == 0) {
        PathList writes = {0};
        PathList reads = {0};
        char *extra_writes[MAX_PATHS];
        int extra_count = 0;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--write") == 0 && i + 1 < argc) {
                extra_writes[extra_count++] = argv[++i];
            }
        }
        build_ruleset(&writes, &reads, extra_writes, extra_count);
        dump_ruleset(&writes, &reads);
        pl_free(&writes);
        pl_free(&reads);
        return 0;
    }

    /* No arguments and no LANDLOCK_WRAP_CMD -> show usage */
    if (argc < 2 && !getenv("LANDLOCK_WRAP_CMD")) {
        usage();
        return 1;
    }

    /* Sandbox mode */
    int cmd_start = 0;
    char *extra_writes[MAX_PATHS];
    int extra_count = 0;

    if (argc >= 2 && strcmp(argv[1], "--") == 0) {
        cmd_start = 2;
    } else {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--") == 0) {
                cmd_start = i + 1;
                break;
            }
        }
    }

    /* Collect --write paths from before -- */
    int write_end = cmd_start ? cmd_start - 1 : argc;
    for (int i = 1; i < write_end; i++) {
        if (strcmp(argv[i], "--write") == 0 && i + 1 < write_end) {
            extra_writes[extra_count++] = argv[++i];
        }
    }

    /* Build the ruleset */
    PathList writes = {0};
    PathList reads = {0};
    build_ruleset(&writes, &reads, extra_writes, extra_count);

    /* Set up GitHub PAT for git auth inside sandbox */
    setup_github_token();

    if (apply_landlock(&writes, &reads) < 0) {
        pl_free(&writes);
        pl_free(&reads);
        return 1;
    }

    /* Determine what to exec */
    if (cmd_start && cmd_start < argc) {
        /* Wrapper mode: command after -- */
        execvp(argv[cmd_start], &argv[cmd_start]);
    } else {
        /* Direct replacement mode: discover and exec the real binary */
        const char *wrap_cmd = getenv("LANDLOCK_WRAP_CMD");

        if (!wrap_cmd) {
            /* Auto-discover from argv[0] basename */
            char *base = strrchr(argv[0], '/');
            base = base ? base + 1 : argv[0];

            if (strcmp(base, "landlock-wrap") == 0) {
                /* Fallback: try Claude versions directory */
                const char *home = getenv("HOME");
                if (home) {
                    char ver_dir[PATH_MAX_LEN];
                    snprintf(ver_dir, sizeof(ver_dir),
                             "%s/.local/share/claude/versions", home);
                    DIR *d = opendir(ver_dir);
                    if (d) {
                        struct dirent *ent;
                        char *latest = NULL;
                        while ((ent = readdir(d))) {
                            if (ent->d_name[0] == '.') continue;
                            if (!latest || strcmp(ent->d_name, latest) > 0)
                                latest = ent->d_name;
                        }
                        closedir(d);
                        if (latest) {
                            char *claude_path = malloc(PATH_MAX_LEN);
                            snprintf(claude_path, PATH_MAX_LEN,
                                     "%s/%s", ver_dir, latest);
                            wrap_cmd = claude_path;
                        }
                    }
                }
                if (!wrap_cmd) {
                    fprintf(stderr,
                        "landlock-wrap: no command specified. "
                        "Use -- COMMAND, set LANDLOCK_WRAP_CMD, "
                        "or invoke via symlink named after the agent\n");
                    pl_free(&writes);
                    pl_free(&reads);
                    return 1;
                }
            }

            /* Strip known suffixes to find the real binary name */
            char agent_name[PATH_MAX_LEN];
            strncpy(agent_name, base, sizeof(agent_name) - 1);
            agent_name[sizeof(agent_name) - 1] = '\0';

            char *suffix;
            const char *suffixes[] = {"-sandboxed", "-wrapper", "-wrapped", NULL};
            for (int s = 0; suffixes[s]; s++) {
                suffix = strstr(agent_name, suffixes[s]);
                if (suffix) {
                    *suffix = '\0';
                    break;
                }
            }

            /* Search PATH for the agent binary */
            char *found = NULL;
            char *path_env = strdup(getenv("PATH") ? getenv("PATH") : "");
            char *dir = strtok(path_env, ":");
            while (dir) {
                char candidate[PATH_MAX_LEN];
                snprintf(candidate, sizeof(candidate), "%s/%s", dir, agent_name);
                if (access(candidate, X_OK) == 0) {
                    found = strdup(candidate);
                    break;
                }
                dir = strtok(NULL, ":");
            }
            free(path_env);

            if (!found) {
                fprintf(stderr,
                    "landlock-wrap: could not find '%s' in PATH. "
                    "Set LANDLOCK_WRAP_CMD or create a symlink.\n",
                    agent_name);
                pl_free(&writes);
                pl_free(&reads);
                return 1;
            }
            wrap_cmd = found;
        }

        char *cmd_argv[MAX_PATHS];
        cmd_argv[0] = (char *)wrap_cmd;
        for (int i = 1; i < argc; i++)
            cmd_argv[i] = argv[i];
        cmd_argv[argc] = NULL;
        execvp(cmd_argv[0], cmd_argv);
        /* If wrap_cmd was allocated by auto-discovery, free it (unreachable after exec) */
        if (wrap_cmd != getenv("LANDLOCK_WRAP_CMD"))
            free((char *)wrap_cmd);
    }
    perror("execvp");
    pl_free(&writes);
    pl_free(&reads);
    return 1;
}
