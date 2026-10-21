/* Adapted from f515-maps-speedup-native-clean native/probe.c. */
static int span_ok(size_t size, uint64_t offset, uint64_t length) {
    return offset <= size && length <= size - offset;
}
static void *find_art_symbol(const char *wanted) {
    const char *file = "/apex/com.android.art/lib64/libart.so";
    int fd = open(file, O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return NULL;
    if (fstat(fd, &st) || st.st_size < (off_t)sizeof(Elf64_Ehdr) || st.st_size > 64*1024*1024) {
        close(fd); return NULL;
    }
    size_t size = st.st_size;
    const unsigned char *data = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (data == MAP_FAILED) return NULL;
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)data;
    uintptr_t value = 0, load_vaddr = 0;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) || eh->e_ident[EI_CLASS] != ELFCLASS64 ||
        eh->e_machine != EM_AARCH64 || eh->e_shentsize != sizeof(Elf64_Shdr) ||
        eh->e_phentsize != sizeof(Elf64_Phdr) ||
        !span_ok(size, eh->e_shoff, (uint64_t)eh->e_shnum * sizeof(Elf64_Shdr)) ||
        !span_ok(size, eh->e_phoff, (uint64_t)eh->e_phnum * sizeof(Elf64_Phdr))) goto out;
    const Elf64_Phdr *ph = (const Elf64_Phdr *)(data + eh->e_phoff);
    int has_base = 0;
    for (int i = 0; i < eh->e_phnum; i++) if (ph[i].p_type == PT_LOAD && ph[i].p_offset == 0) {
        load_vaddr = ph[i].p_vaddr; has_base = 1; break;
    }
    if (!has_base) goto out;
    const Elf64_Shdr *sh = (const Elf64_Shdr *)(data + eh->e_shoff);
    for (int i = 0; i < eh->e_shnum && !value; i++) {
        if (sh[i].sh_type != SHT_DYNSYM || sh[i].sh_entsize != sizeof(Elf64_Sym) ||
            sh[i].sh_link >= eh->e_shnum || !span_ok(size, sh[i].sh_offset, sh[i].sh_size)) continue;
        const Elf64_Shdr *strings = &sh[sh[i].sh_link];
        if (!span_ok(size, strings->sh_offset, strings->sh_size)) continue;
        const char *strtab = (const char *)(data + strings->sh_offset);
        const Elf64_Sym *symbols = (const Elf64_Sym *)(data + sh[i].sh_offset);
        for (size_t n = 0; n < sh[i].sh_size/sizeof(*symbols); n++) {
            size_t pos = symbols[n].st_name;
            if (pos >= strings->sh_size || !memchr(strtab + pos, 0, strings->sh_size-pos)) continue;
            if (symbols[n].st_shndx != SHN_UNDEF && !strcmp(strtab + pos, wanted)) {
                value = symbols[n].st_value; break;
            }
        }
    }
out:
    munmap((void *)data, size);
    if (!value) return NULL;
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return NULL;
    char line[4096], path[PATH_MAX], perms[8];
    unsigned long start, end, offset;
    void *result = NULL;
    while (fgets(line, sizeof(line), maps)) {
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %4095s", &start, &end, perms, &offset, path) != 5 ||
            offset || strcmp(path, file)) continue;
        uintptr_t address = start + value - load_vaddr;
        // Ignore whole-file data mmaps. A function must lie in an executable ART segment.
        FILE *check = fopen("/proc/self/maps", "r");
        if (!check) break;
        char row[4096], module[PATH_MAX], access[8];
        unsigned long lo, hi;
        while (fgets(row, sizeof(row), check)) {
            if (sscanf(row, "%lx-%lx %7s %*s %*s %*s %4095s", &lo, &hi, access, module) == 4 &&
                lo <= address && address < hi && strchr(access, 'x') && !strcmp(module, file)) {
                result = (void *)address; break;
            }
        }
        fclose(check);
        if (result) break;
    }
    fclose(maps);
    return result;
}
