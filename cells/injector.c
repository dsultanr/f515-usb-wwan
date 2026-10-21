/* ARM64 Android-only feasibility loader. No Frida, no executable shellcode.
 * Calls the target's existing mmap/dlopen/dlsym through ptrace, then restores
 * the interrupted thread's general and SIMD registers. Test on probe-host first.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <asm/ptrace.h>

#if !defined(__aarch64__)
#error This loader supports only AArch64 Android processes
#endif

static pid_t target;
static bool attached, stopped, saved_ok, fp_ok, mask_ok;
static uint64_t original_mask;
/* A remote call was started and has not reached its return marker yet. */
static bool call_in_flight;
/* The target may be left inconsistent; the supervisor must restart it.
 * Signaled to the outside as exit code 3. */
static bool doubtful;
static struct user_pt_regs original;
static struct user_fpsimd_state original_fp;
static volatile sig_atomic_t interrupted;
static unsigned stop_event;
static int64_t monotonic_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void on_signal(int signo) { (void)signo; interrupted = 1; }
static int regset(int request, int note, void *data, size_t size) {
    struct iovec io = { .iov_base = data, .iov_len = size };
    return ptrace(request, target, (void *)(uintptr_t)note, &io);
}
static int wait_stop(int milliseconds) {
    int64_t deadline = monotonic_ms() + milliseconds;
    while (monotonic_ms() < deadline) {
        int status;
        pid_t r = waitpid(target, &status, __WALL | WNOHANG);
        if (r == target) {
            if (WIFSTOPPED(status)) { stopped = true; stop_event = (unsigned)status >> 16; return WSTOPSIG(status); }
            fprintf(stderr, "target exited during remote call (status=%d)\n", status);
            if (call_in_flight) doubtful = true;
            attached = false;
            return -1;
        }
        if (r == -1 && errno != EINTR) return -1;
        if (interrupted) { errno = EINTR; return -1; }
        usleep(10000);
    }
    errno = ETIMEDOUT;
    return -1;
}
static int memory_read(uintptr_t address, void *out, size_t size) {
    unsigned char *p = out;
    for (size_t i = 0; i < size; i += sizeof(long)) {
        errno = 0;
        long word = ptrace(PTRACE_PEEKDATA, target, (void *)(address + i), NULL);
        if (errno) return -1;
        size_t n = size - i < sizeof(word) ? size - i : sizeof(word);
        memcpy(p + i, &word, n);
    }
    return 0;
}
static int memory_write(uintptr_t address, const void *data, size_t size) {
    const unsigned char *p = data;
    for (size_t i = 0; i < size; i += sizeof(long)) {
        long word = 0;
        size_t n = size - i < sizeof(word) ? size - i : sizeof(word);
        if (n != sizeof(word) && memory_read(address + i, &word, sizeof(word))) return -1;
        memcpy(&word, p + i, n);
        if (ptrace(PTRACE_POKEDATA, target, (void *)(address + i), (void *)word)) return -1;
    }
    return 0;
}

/* Match the same mapped system DSO and translate its load bias. Never assume
 * that ASLR addresses or offsets from a different Android build are usable. */
static uintptr_t remote_symbol(const char *name) {
    void *local = dlsym(RTLD_DEFAULT, name);
    Dl_info info;
    if (!local || !dladdr(local, &info)) return 0;
    char actual[PATH_MAX];
    const char *library = realpath(info.dli_fname, actual) ? actual : info.dli_fname;
    const char *base = strrchr(library, '/');
    base = base ? base + 1 : library;
    char maps[64]; snprintf(maps, sizeof(maps), "/proc/%d/maps", target);
    FILE *f = fopen(maps, "r");
    if (!f) return 0;
    char line[4096], path[PATH_MAX], perms[8];
    unsigned long start, end, offset;
    uintptr_t result = 0;
    while (fgets(line, sizeof(line), f)) {
        path[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %4095s", &start, &end,
                   perms, &offset, path) != 5 || offset != 0) continue;
        const char *remote_base = strrchr(path, '/');
        if (!remote_base || strcmp(remote_base + 1, base)) continue;
        /* Both paths refer to shared system/apex libraries on this device. */
        if (strncmp(path, "/apex/", 6) && strncmp(path, "/system/", 8)) continue;
        result = start + ((uintptr_t)local - (uintptr_t)info.dli_fbase);
        break;
    }
    fclose(f);
    fprintf(stderr, "%s: remote=0x%" PRIxPTR " (%s)\n", name, result, base);
    return result;
}

/* Wait until the in-flight remote call reaches its LR=0 return marker.
 * Stray signal stops are delivered back and waiting continues, so signals
 * meant for the app (ART SIGQUIT dumps, etc.) are never swallowed.
 * Returns 0 with the call's x0 in *result on the marker stop;
 * 1 when the remote function faulted (thread stopped mid-call, the call
 * will never complete); -1 on timeout or interrupt (thread still running
 * the call). */
static int await_call(int milliseconds, uintptr_t *result) {
    int64_t deadline = monotonic_ms() + milliseconds;
    for (;;) {
        int64_t remaining = deadline - monotonic_ms();
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int sig = wait_stop((int)remaining);
        if (sig < 0) return -1;
        struct user_pt_regs regs;
        if (regset(PTRACE_GETREGSET, NT_PRSTATUS, &regs, sizeof(regs))) return -1;
        if (!stop_event && sig == SIGSEGV && regs.pc == 0) { *result = regs.regs[0]; return 0; }
        if (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGABRT || sig == SIGFPE) {
            fprintf(stderr, "remote function faulted: signal=%d pc=0x%llx\n",
                    sig, (unsigned long long)regs.pc);
            return 1;
        }
        /* PTRACE_EVENT_STOP is tracer bookkeeping, not an app SIGTRAP. */
        int deliver = stop_event ? 0 : sig;
        if (deliver) fprintf(stderr, "delivering stray signal %d during remote call\n", deliver);
        if (ptrace(PTRACE_CONT, target, NULL, (void *)(uintptr_t)deliver)) return -1;
        stopped = false;
    }
}

static int remote_call(uintptr_t function, uintptr_t stack, const uintptr_t *args,
                       size_t argc, uintptr_t *result) {
    if (!function || argc > 8 || !stopped || call_in_flight || interrupted) return -1;
    struct user_pt_regs regs = original;
    for (size_t i = 0; i < argc; ++i) regs.regs[i] = args[i];
    regs.pc = function;
    regs.sp = stack & ~(uintptr_t)15;
    regs.regs[30] = 0; /* Expected SIGSEGV at PC=0 marks function return. */
    if (regset(PTRACE_SETREGSET, NT_PRSTATUS, &regs, sizeof(regs))) return -1;
    if (ptrace(PTRACE_CONT, target, NULL, NULL)) return -1;
    stopped = false;
    call_in_flight = true;
    int rc = await_call(5000, result);
    if (rc == 0) { call_in_flight = false; return 0; }
    if (rc > 0) { call_in_flight = false; doubtful = true; }
    else perror("remote call wait");
    return -1;
}

static void restore(void) {
    if (!attached) { if (doubtful) _exit(3); return; }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN);
    if (!stopped && call_in_flight) {
        /* A completed dlopen is safer than an aborted one: aborting mid-call
         * can leave the dynamic linker's lock held forever. Give the call a
         * grace window to reach its return marker before interrupting it. */
        uintptr_t ignored = 0;
        interrupted = 0;
        int rc = await_call(10000, &ignored);
        if (rc == 0) call_in_flight = false;
        else if (rc > 0) { call_in_flight = false; doubtful = true; }
    }
    if (!stopped) {
        for (int attempt = 0; attempt < 5 && !stopped; ++attempt) {
            interrupted = 0;
            if (ptrace(PTRACE_INTERRUPT, target, NULL, NULL)) {
                perror("interrupt target");
                break;
            }
            wait_stop(2000); /* Sets stopped on success. */
        }
    }
    if (!stopped) {
        fprintf(stderr, "ERROR: target thread unstoppable; registers NOT restored\n");
        doubtful = true;
    } else {
        if (call_in_flight) {
            fprintf(stderr, "WARNING: rewinding a thread out of an unfinished remote call\n");
            doubtful = true;
        }
        if (saved_ok && regset(PTRACE_SETREGSET, NT_PRSTATUS, &original, sizeof(original))) {
            perror("restore general registers"); doubtful = true;
        }
        if (fp_ok && regset(PTRACE_SETREGSET, NT_FPREGSET, &original_fp, sizeof(original_fp))) {
            perror("restore SIMD registers"); doubtful = true;
        }
        if (mask_ok && ptrace(PTRACE_SETSIGMASK, target, (void *)sizeof(original_mask), &original_mask)) {
            perror("restore signal mask"); doubtful = true;
        }
        if (ptrace(PTRACE_DETACH, target, NULL, NULL)) { perror("detach"); doubtful = true; }
        else if (!doubtful) fprintf(stderr, "restored registers and detached\n");
    }
    attached = false;
    if (doubtful) {
        fprintf(stderr, "target pid %d left in a doubtful state: exit code 3, supervisor should restart it\n",
                target);
        fflush(NULL);
        _exit(3);
    }
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "Usage: %s PID /absolute/libmaps_native.so ENTRY_SYMBOL [EXPECTED_RESULT]\n"
                        "Exit codes: 0 ok, 1 failure (target restored), 2 usage, 3 target doubtful: restart it\n", argv[0]);
        return 2;
    }
    char *tail; long pid = strtol(argv[1], &tail, 10);
    if (*tail || pid <= 1 || pid > INT_MAX || argv[2][0] != '/' || strlen(argv[2]) > 2047
        || strlen(argv[3]) > 127) return 2;
    target = (pid_t)pid;
    uintptr_t expected = 0;
    if (argc == 5) {
        expected = strtoull(argv[4], &tail, 10);
        if (*tail) return 2;
    }
    if (target == getpid()) return 2;
    char path[80]; snprintf(path, sizeof(path), "/proc/%d/exe", target);
    FILE *elf = fopen(path, "rb");
    Elf64_Ehdr eh;
    if (!elf) { perror("target exe"); return 1; }
    size_t got = fread(&eh, 1, sizeof(eh), elf); fclose(elf);
    if (got != sizeof(eh) || memcmp(eh.e_ident, ELFMAG, SELFMAG)
        || eh.e_ident[EI_CLASS] != ELFCLASS64 || eh.e_machine != EM_AARCH64) {
        fprintf(stderr, "target must be an ARM64 ELF process\n"); return 1;
    }
    uintptr_t fn_mmap = remote_symbol("mmap");
    uintptr_t fn_dlopen = remote_symbol("dlopen");
    uintptr_t fn_dlsym = remote_symbol("dlsym");
    uintptr_t fn_dlerror = remote_symbol("dlerror");
    uintptr_t fn_munmap = remote_symbol("munmap");
    if (!fn_mmap || !fn_dlopen || !fn_dlsym || !fn_dlerror || !fn_munmap) return 1;
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal);
    if (ptrace(PTRACE_SEIZE, target, NULL, NULL)) { perror("PTRACE_SEIZE"); return 1; }
    attached = true; atexit(restore);
    if (ptrace(PTRACE_INTERRUPT, target, NULL, NULL) || wait_stop(2000) < 0) {
        perror("initial stop"); return 1;
    }
    if (regset(PTRACE_GETREGSET, NT_PRSTATUS, &original, sizeof(original))) return 1;
    saved_ok = true;
    if (regset(PTRACE_GETREGSET, NT_FPREGSET, &original_fp, sizeof(original_fp))) return 1;
    fp_ok = true;
    /* A forced synchronous fault while SIGSEGV is blocked resets its handler
     * process-wide, even when ptrace suppresses delivery. ART depends on this
     * handler in every thread. Unblock our return-marker signal temporarily. */
    if (ptrace(PTRACE_GETSIGMASK, target, (void *)sizeof(original_mask), &original_mask)) {
        perror("save signal mask"); return 1;
    }
    mask_ok = true;
    uint64_t call_mask = original_mask & ~(UINT64_C(1) << (SIGSEGV - 1));
    if (ptrace(PTRACE_SETSIGMASK, target, (void *)sizeof(call_mask), &call_mask)) {
        perror("set call signal mask"); return 1;
    }


    uintptr_t scratch, result, handle, entry;
    uintptr_t initial_stack = (original.sp - 4096) & ~(uintptr_t)15;
    uintptr_t args[6] = {0, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
                         (uintptr_t)-1, 0};
    if (remote_call(fn_mmap, initial_stack, args, 6, &scratch) || scratch == (uintptr_t)-1
        || scratch == 0) { fprintf(stderr, "remote mmap failed\n"); return 1; }
    uintptr_t stack = scratch + 65536 - 32;
    if (memory_write(scratch, argv[2], strlen(argv[2]) + 1)
        || memory_write(scratch + 4096, argv[3], strlen(argv[3]) + 1)) return 1;
    args[0] = scratch; args[1] = RTLD_NOW | RTLD_LOCAL;
    if (remote_call(fn_dlopen, stack, args, 2, &handle)) return 1;
    if (!handle) {
        uintptr_t err;
        if (!remote_call(fn_dlerror, stack, args, 0, &err) && err) {
            char message[256] = {0};
            if (!memory_read(err, message, sizeof(message)-1)) fprintf(stderr, "dlopen: %s\n", message);
        }
        fprintf(stderr, "library was not loaded\n");
        args[0] = scratch; args[1] = 65536;
        remote_call(fn_munmap, initial_stack, args, 2, &result);
        return 1;
    }
    args[0] = handle; args[1] = scratch + 4096;
    if (remote_call(fn_dlsym, stack, args, 2, &entry) || !entry) {
        fprintf(stderr, "entry symbol unavailable; library remains loaded\n"); return 1;
    }
    if (remote_call(entry, stack, args, 0, &result)) return 1;
    printf("loaded=%s entry=%s result=%" PRIuPTR " pid=%d\n", argv[2], argv[3], result, target);
    args[0] = scratch; args[1] = 65536;
    if (remote_call(fn_munmap, initial_stack, args, 2, &scratch)) return 1;
    return result == expected ? 0 : 1;
}
