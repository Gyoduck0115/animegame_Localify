#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

extern "C" const uint8_t hso_translation_blob[];
extern "C" const uint8_t hso_translation_blob_end[];

namespace {

constexpr char kLogPrefix[] = "[HSO_NATIVE]";
constexpr uint8_t kBlobMagic[8] = {'H', 'S', 'O', 'N', 'T', 'R', '1', 0};

pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;
int log_fd = -2;

int open_log_file_locked() {
  if (log_fd != -2)
    return log_fd;

  log_fd = -1;

  char path[1024];
  const char *home = getenv("HOME");
  if (home != nullptr && home[0] != '\0') {
    snprintf(path, sizeof(path), "%s/Documents/hso_native_localify.log", home);
    log_fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
  }

  if (log_fd < 0)
    log_fd = open("/tmp/hso_native_localify.log", O_CREAT | O_WRONLY | O_APPEND, 0644);

  return log_fd;
}

int hso_fprintf(FILE *stream, const char *format, ...) {
  char buffer[4096];

  va_list args;
  va_start(args, format);
  int result = vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);

  if (stream != nullptr) {
    fputs(buffer, stream);
    fflush(stream);
  }

  pthread_mutex_lock(&log_mutex);
  int fd = open_log_file_locked();
  if (fd >= 0) {
    size_t length = strnlen(buffer, sizeof(buffer));
    if (length > 0)
      write(fd, buffer, length);
    fsync(fd);
  }
  pthread_mutex_unlock(&log_mutex);

  return result;
}

#define fprintf hso_fprintf

struct Il2CppString {
  void *klass;
  void *monitor;
  int32_t length;
  uint16_t chars[0];
};

using Il2CppDomainGet = void *(*)();
using Il2CppThreadAttach = void *(*)(void *);
using Il2CppDomainAssemblyOpen = void *(*)(void *, const char *);
using Il2CppAssemblyGetImage = void *(*)(void *);
using Il2CppClassFromName = void *(*)(void *, const char *, const char *);
using Il2CppClassGetMethodFromName = void *(*)(void *, const char *, int);
using Il2CppStringNew = Il2CppString *(*)(const char *);
using Il2CppResolveIcall = void *(*)(const char *);
using GetTextFn = Il2CppString *(*)(void *, void *);
using ICallGetTextFn = Il2CppString *(*)(void *);

Il2CppDomainGet il2cpp_domain_get_fn = nullptr;
Il2CppThreadAttach il2cpp_thread_attach_fn = nullptr;
Il2CppDomainAssemblyOpen il2cpp_domain_assembly_open_fn = nullptr;
Il2CppAssemblyGetImage il2cpp_assembly_get_image_fn = nullptr;
Il2CppClassFromName il2cpp_class_from_name_fn = nullptr;
Il2CppClassGetMethodFromName il2cpp_class_get_method_from_name_fn = nullptr;
Il2CppStringNew il2cpp_string_new_fn = nullptr;
Il2CppResolveIcall il2cpp_resolve_icall_fn = nullptr;

GetTextFn original_get_text = nullptr;
ICallGetTextFn original_get_text_icall = nullptr;
std::once_flag translation_once;
std::once_flag executable_ranges_once;
std::once_flag data_ranges_once;
std::unordered_map<std::string, std::string> translations;
std::mutex cache_mutex;
std::unordered_map<std::string, std::string> replacement_cache;
std::atomic<int> text_asset_log_count{0};
std::atomic<int> replacement_log_count{0};
std::atomic<int> hook_entry_log_count{0};
std::atomic<int> icall_scan_log_count{0};
std::atomic<int> icall_miss_log_count{0};

struct ExecutableRange {
  uintptr_t start;
  uintptr_t end;
  const char *image_name;
};

std::vector<ExecutableRange> executable_ranges;
std::vector<ExecutableRange> data_ranges;

Il2CppString *hook_get_text(void *self, void *method_info);
Il2CppString *hook_get_text_icall(void *self);

template <typename T>
bool resolve_symbol(T &slot, const char *name) {
  void *symbol = dlsym(RTLD_DEFAULT, name);
  if (symbol == nullptr)
    return false;
  slot = reinterpret_cast<T>(symbol);
  return true;
}

bool resolve_il2cpp() {
  bool ok = true;
  ok &= resolve_symbol(il2cpp_domain_get_fn, "il2cpp_domain_get");
  ok &= resolve_symbol(il2cpp_thread_attach_fn, "il2cpp_thread_attach");
  ok &= resolve_symbol(il2cpp_domain_assembly_open_fn, "il2cpp_domain_assembly_open");
  ok &= resolve_symbol(il2cpp_assembly_get_image_fn, "il2cpp_assembly_get_image");
  ok &= resolve_symbol(il2cpp_class_from_name_fn, "il2cpp_class_from_name");
  ok &= resolve_symbol(il2cpp_class_get_method_from_name_fn, "il2cpp_class_get_method_from_name");
  ok &= resolve_symbol(il2cpp_string_new_fn, "il2cpp_string_new");
  resolve_symbol(il2cpp_resolve_icall_fn, "il2cpp_resolve_icall");
  return ok;
}

bool read_u32(const uint8_t *&cursor, const uint8_t *end, uint32_t &value) {
  if (cursor + 4 > end)
    return false;
  value = static_cast<uint32_t>(cursor[0]) |
      (static_cast<uint32_t>(cursor[1]) << 8) |
      (static_cast<uint32_t>(cursor[2]) << 16) |
      (static_cast<uint32_t>(cursor[3]) << 24);
  cursor += 4;
  return true;
}

void load_translations_once() {
  const uint8_t *cursor = hso_translation_blob;
  const uint8_t *end = hso_translation_blob_end;

  if (end - cursor < 12 || memcmp(cursor, kBlobMagic, sizeof(kBlobMagic)) != 0) {
    fprintf(stderr, "%s invalid translation blob\n", kLogPrefix);
    return;
  }
  cursor += sizeof(kBlobMagic);

  uint32_t count = 0;
  if (!read_u32(cursor, end, count)) {
    fprintf(stderr, "%s truncated translation blob header\n", kLogPrefix);
    return;
  }

  translations.reserve(count);
  for (uint32_t i = 0; i != count; i++) {
    uint32_t key_len = 0;
    uint32_t value_len = 0;
    if (!read_u32(cursor, end, key_len) || !read_u32(cursor, end, value_len) ||
        cursor + key_len + value_len > end) {
      fprintf(stderr, "%s truncated translation blob at entry %u\n", kLogPrefix, i);
      translations.clear();
      return;
    }

    std::string key(reinterpret_cast<const char *>(cursor), key_len);
    cursor += key_len;
    std::string value(reinterpret_cast<const char *>(cursor), value_len);
    cursor += value_len;
    translations.emplace(std::move(key), std::move(value));
  }

  fprintf(stderr, "%s loaded %zu translations\n", kLogPrefix, translations.size());
}

void ensure_translations_loaded() {
  std::call_once(translation_once, load_translations_once);
}

void append_utf8(uint32_t cp, std::string &out) {
  if (cp <= 0x7f) {
    out.push_back(static_cast<char>(cp));
  } else if (cp <= 0x7ff) {
    out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  } else if (cp <= 0xffff) {
    out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  } else {
    out.push_back(static_cast<char>(0xf0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  }
}

std::string il2cpp_string_to_utf8(Il2CppString *string) {
  std::string out;
  if (string == nullptr || string->length <= 0)
    return out;

  out.reserve(static_cast<size_t>(string->length) * 3);
  for (int32_t i = 0; i < string->length; i++) {
    uint32_t cp = string->chars[i];
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < string->length) {
      uint32_t low = string->chars[i + 1];
      if (low >= 0xdc00 && low <= 0xdfff) {
        cp = 0x10000 + (((cp - 0xd800) << 10) | (low - 0xdc00));
        i++;
      }
    }
    append_utf8(cp, out);
  }
  return out;
}

std::vector<std::string> split_crlf(const std::string &input) {
  std::vector<std::string> lines;
  size_t start = 0;
  while (true) {
    size_t pos = input.find("\r\n", start);
    if (pos == std::string::npos) {
      lines.emplace_back(input.substr(start));
      return lines;
    }
    lines.emplace_back(input.substr(start, pos - start));
    start = pos + 2;
  }
}

bool build_replacement(const std::string &raw, std::string &replacement) {
  if (raw.rfind("TEXT_ID", 0) != 0)
    return false;

  ensure_translations_loaded();
  if (translations.empty())
    return false;

  std::vector<std::string> lines = split_crlf(raw);
  if (lines.size() < 7)
    return false;

  const std::string &textmap_key = lines[6];
  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    auto cached = replacement_cache.find(textmap_key);
    if (cached != replacement_cache.end()) {
      replacement = cached->second;
      return true;
    }
  }

  replacement.clear();
  replacement.reserve(raw.size());
  replacement.append(lines[0]).append("\r\n")
      .append(lines[1]).append("\r\n")
      .append(lines[2]).append("\r\n")
      .append(lines[3]);

  size_t replaced_count = 0;
  for (size_t i = 4; i < lines.size(); i++) {
    const std::string &line = lines[i];
    size_t first_tab = line.find('\t');
    size_t second_tab = first_tab == std::string::npos ? std::string::npos : line.find('\t', first_tab + 1);
    if (first_tab != std::string::npos && second_tab != std::string::npos) {
      std::string id = line.substr(0, first_tab);
      auto translated = translations.find(id);
      if (translated != translations.end()) {
        size_t third_tab = line.find('\t', second_tab + 1);
        std::string third = third_tab == std::string::npos
            ? line.substr(second_tab + 1)
            : line.substr(second_tab + 1, third_tab - second_tab - 1);
        replacement.append("\r\n")
            .append(id).append("\t")
            .append(translated->second).append("\t")
            .append(third);
        replaced_count++;
        continue;
      }
    }

    replacement.append("\r\n").append(line);
  }

  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    replacement_cache[textmap_key] = replacement;
  }

  int log_index = replacement_log_count.fetch_add(1);
  if (log_index < 20) {
    fprintf(stderr, "%s TEXT_ID asset key='%s' lines=%zu replaced=%zu raw=%zu output=%zu\n",
        kLogPrefix, textmap_key.c_str(), lines.size(), replaced_count, raw.size(), replacement.size());
  }

  return true;
}

Il2CppString *process_text_result(Il2CppString *original, const char *source) {
  if (original == nullptr || il2cpp_string_new_fn == nullptr)
    return original;

  std::string raw = il2cpp_string_to_utf8(original);
  if (raw.rfind("TEXT_ID", 0) == 0) {
    int log_index = text_asset_log_count.fetch_add(1);
    if (log_index < 20)
      fprintf(stderr, "%s %s saw TEXT_ID asset raw=%zu\n", kLogPrefix, source, raw.size());
  }

  std::string replacement;
  if (!build_replacement(raw, replacement))
    return original;

  return il2cpp_string_new_fn(replacement.c_str());
}

Il2CppString *hook_get_text(void *self, void *method_info) {
  int entry_log_index = hook_entry_log_count.fetch_add(1);
  if (entry_log_index < 20)
    fprintf(stderr, "%s hook_get_text entered self=%p method=%p\n", kLogPrefix, self, method_info);

  Il2CppString *original = original_get_text != nullptr ? original_get_text(self, method_info) : nullptr;
  return process_text_result(original, "method-hook");
}

Il2CppString *hook_get_text_icall(void *self) {
  int entry_log_index = hook_entry_log_count.fetch_add(1);
  if (entry_log_index < 20)
    fprintf(stderr, "%s hook_get_text_icall entered self=%p\n", kLogPrefix, self);

  Il2CppString *original = original_get_text_icall != nullptr ? original_get_text_icall(self) : nullptr;
  return process_text_result(original, "icall-hook");
}

bool make_writable(void *address) {
  const size_t page_size = static_cast<size_t>(getpagesize());
  uintptr_t page = reinterpret_cast<uintptr_t>(address) & ~(static_cast<uintptr_t>(page_size) - 1);
  if (mprotect(reinterpret_cast<void *>(page), page_size, PROT_READ | PROT_WRITE) == 0)
    return true;

  kern_return_t kr = vm_protect(mach_task_self(), static_cast<vm_address_t>(page), page_size, false,
      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  return kr == KERN_SUCCESS;
}

void collect_executable_ranges_once() {
  const uint32_t image_count = _dyld_image_count();
  for (uint32_t i = 0; i < image_count; i++) {
    const mach_header *header = _dyld_get_image_header(i);
    if (header == nullptr || header->magic != MH_MAGIC_64)
      continue;

    const char *image_name = _dyld_get_image_name(i);
    const intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const uint8_t *command = reinterpret_cast<const uint8_t *>(header) + sizeof(mach_header_64);
    const mach_header_64 *header64 = reinterpret_cast<const mach_header_64 *>(header);

    for (uint32_t command_index = 0; command_index < header64->ncmds; command_index++) {
      const load_command *load = reinterpret_cast<const load_command *>(command);
      if (load->cmd == LC_SEGMENT_64) {
        const segment_command_64 *segment = reinterpret_cast<const segment_command_64 *>(command);
        if ((segment->initprot & VM_PROT_EXECUTE) != 0 && segment->vmsize != 0) {
          ExecutableRange range{
              static_cast<uintptr_t>(segment->vmaddr + slide),
              static_cast<uintptr_t>(segment->vmaddr + slide + segment->vmsize),
              image_name,
          };
          executable_ranges.push_back(range);
        }
      }
      command += load->cmdsize;
    }
  }

  fprintf(stderr, "%s collected %zu executable ranges\n", kLogPrefix, executable_ranges.size());
}

void ensure_executable_ranges_loaded() {
  std::call_once(executable_ranges_once, collect_executable_ranges_once);
}

void collect_data_ranges_once() {
  const uint32_t image_count = _dyld_image_count();
  for (uint32_t i = 0; i < image_count; i++) {
    const mach_header *header = _dyld_get_image_header(i);
    if (header == nullptr || header->magic != MH_MAGIC_64)
      continue;

    const char *image_name = _dyld_get_image_name(i);
    if (image_name == nullptr)
      continue;

    const bool is_unity_framework = strstr(image_name, "/UnityFramework.framework/UnityFramework") != nullptr;
    const bool is_main_executable = strstr(image_name, "/HSoDv2JP.app/HSoDv2JP") != nullptr;
    if (!is_unity_framework && !is_main_executable)
      continue;

    if (strstr(image_name, "/Tweaks/") != nullptr ||
        strstr(image_name, "HSoDv2JP_Native_Localify") != nullptr ||
        strstr(image_name, ".dylib") != nullptr)
      continue;

    const intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const uint8_t *command = reinterpret_cast<const uint8_t *>(header) + sizeof(mach_header_64);
    const mach_header_64 *header64 = reinterpret_cast<const mach_header_64 *>(header);

    for (uint32_t command_index = 0; command_index < header64->ncmds; command_index++) {
      const load_command *load = reinterpret_cast<const load_command *>(command);
      if (load->cmd == LC_SEGMENT_64) {
        const segment_command_64 *segment = reinterpret_cast<const segment_command_64 *>(command);
        const bool readable = (segment->initprot & VM_PROT_READ) != 0;
        const bool executable = (segment->initprot & VM_PROT_EXECUTE) != 0;
        const bool likely_data = strncmp(segment->segname, "__DATA", 6) == 0 ||
            strncmp(segment->segname, "__AUTH", 6) == 0;
        if (readable && !executable && likely_data && segment->vmsize != 0) {
          data_ranges.push_back(ExecutableRange{
              static_cast<uintptr_t>(segment->vmaddr + slide),
              static_cast<uintptr_t>(segment->vmaddr + slide + segment->vmsize),
              image_name,
          });
        }
      }
      command += load->cmdsize;
    }
  }

  fprintf(stderr, "%s collected %zu data ranges\n", kLogPrefix, data_ranges.size());
}

void ensure_data_ranges_loaded() {
  std::call_once(data_ranges_once, collect_data_ranges_once);
}

bool image_name_contains(const char *image_name, const char *needle) {
  return image_name != nullptr && strstr(image_name, needle) != nullptr;
}

const ExecutableRange *find_executable_range(void *address, bool prefer_unity) {
  ensure_executable_ranges_loaded();
  const uintptr_t value = reinterpret_cast<uintptr_t>(address);
  const ExecutableRange *fallback = nullptr;

  for (const auto &range : executable_ranges) {
    if (value < range.start || value >= range.end)
      continue;
    if (!prefer_unity)
      return &range;
    if (image_name_contains(range.image_name, "UnityFramework") ||
        image_name_contains(range.image_name, "HSoDv2JP"))
      return &range;
    if (fallback == nullptr)
      fallback = &range;
  }

  return fallback;
}

void **find_method_pointer_slot(void *method) {
  void **fallback = nullptr;
  const size_t max_scan = 0x100;

  for (size_t offset = 0; offset < max_scan; offset += sizeof(void *)) {
    void **slot = reinterpret_cast<void **>(static_cast<uint8_t *>(method) + offset);
    void *candidate = *slot;
    if (candidate == nullptr)
      continue;

    const ExecutableRange *range = find_executable_range(candidate, true);
    if (range == nullptr)
      continue;

    fprintf(stderr, "%s MethodInfo executable pointer candidate offset=0x%zx value=%p image=%s\n",
        kLogPrefix, offset, candidate, range->image_name != nullptr ? range->image_name : "(unknown)");

    if (image_name_contains(range->image_name, "UnityFramework") ||
        image_name_contains(range->image_name, "HSoDv2JP"))
      return slot;

    if (fallback == nullptr)
      fallback = slot;
  }

  return fallback;
}

void *open_core_module(void *domain) {
  const char *names[] = {
      "UnityEngine.CoreModule",
      "UnityEngine.CoreModule.dll",
      "UnityEngine.CoreModule, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null",
  };

  for (const char *name : names) {
    void *assembly = il2cpp_domain_assembly_open_fn(domain, name);
    if (assembly != nullptr)
      return il2cpp_assembly_get_image_fn(assembly);
  }
  return nullptr;
}

bool install_icall_cache_hook() {
  if (il2cpp_resolve_icall_fn == nullptr)
    return false;

  void *resolved = il2cpp_resolve_icall_fn("UnityEngine.TextAsset::get_text()");
  if (resolved == nullptr)
    resolved = il2cpp_resolve_icall_fn("UnityEngine.TextAsset::get_text");
  if (resolved == nullptr)
    return false;

  if (original_get_text_icall == nullptr) {
    original_get_text_icall = reinterpret_cast<ICallGetTextFn>(resolved);
    fprintf(stderr, "%s resolved UnityEngine.TextAsset::get_text icall -> %p\n", kLogPrefix, resolved);
  }

  ensure_data_ranges_loaded();

  size_t patched_count = 0;
  size_t scanned_slots = 0;
  for (const auto &range : data_ranges) {
    for (uintptr_t address = range.start; address + sizeof(void *) <= range.end; address += sizeof(void *)) {
      void **slot = reinterpret_cast<void **>(address);
      void *value = *slot;
      scanned_slots++;
      if (value == reinterpret_cast<void *>(&hook_get_text_icall))
        patched_count++;
      if (value != resolved && value != reinterpret_cast<void *>(original_get_text_icall))
        continue;

      if (!make_writable(slot)) {
        int log_index = icall_scan_log_count.fetch_add(1);
        if (log_index < 20)
          fprintf(stderr, "%s failed to make icall cache slot writable: %p image=%s\n",
              kLogPrefix, slot, range.image_name != nullptr ? range.image_name : "(unknown)");
        continue;
      }

      *slot = reinterpret_cast<void *>(&hook_get_text_icall);
      patched_count++;

      int log_index = icall_scan_log_count.fetch_add(1);
      if (log_index < 40) {
        fprintf(stderr, "%s icall-cache-hooked TextAsset.get_text slot=%p old=%p replacement=%p image=%s\n",
            kLogPrefix, slot, value, reinterpret_cast<void *>(&hook_get_text_icall),
            range.image_name != nullptr ? range.image_name : "(unknown)");
      }
    }
  }

  if (patched_count == 0) {
    int log_index = icall_miss_log_count.fetch_add(1);
    if (log_index < 20 || (log_index % 20) == 0) {
      fprintf(stderr, "%s icall cache slot not found yet: resolved=%p ranges=%zu scanned_slots=%zu\n",
          kLogPrefix, resolved, data_ranges.size(), scanned_slots);
    }
  }

  return patched_count != 0;
}

bool install_hook() {
  if (!resolve_il2cpp())
    return false;

  void *domain = il2cpp_domain_get_fn();
  if (domain == nullptr)
    return false;

  il2cpp_thread_attach_fn(domain);

  void *image = open_core_module(domain);
  if (image == nullptr)
    return false;

  void *klass = il2cpp_class_from_name_fn(image, "UnityEngine", "TextAsset");
  if (klass == nullptr)
    return false;

  void *method = il2cpp_class_get_method_from_name_fn(klass, "get_text", 0);
  if (method == nullptr)
    return false;

  void **method_pointer_slot = find_method_pointer_slot(method);
  if (method_pointer_slot == nullptr) {
    fprintf(stderr, "%s could not find executable method pointer in MethodInfo %p\n", kLogPrefix, method);
    return false;
  }

  void *current = *method_pointer_slot;
  if (current == nullptr)
    return false;

  bool pointer_hooked = current == reinterpret_cast<void *>(&hook_get_text);
  if (!pointer_hooked && original_get_text == nullptr) {
    original_get_text = reinterpret_cast<GetTextFn>(current);

    if (!make_writable(method_pointer_slot)) {
      fprintf(stderr, "%s failed to make MethodInfo pointer slot writable: %p\n", kLogPrefix, method_pointer_slot);
    } else {
      *method_pointer_slot = reinterpret_cast<void *>(&hook_get_text);
      pointer_hooked = true;
      fprintf(stderr, "%s pointer-hooked UnityEngine.TextAsset.get_text: slot=%p original=%p replacement=%p\n",
          kLogPrefix, method_pointer_slot, current, reinterpret_cast<void *>(&hook_get_text));
    }
  }

  bool icall_hooked = install_icall_cache_hook();
  return icall_hooked;
}

void *installer_thread(void *) {
  fprintf(stderr, "%s installer thread started\n", kLogPrefix);

  for (int attempt = 0; attempt < 300; attempt++) {
    if (install_hook())
      return nullptr;
    usleep(500 * 1000);
  }

  fprintf(stderr, "%s failed to install hook before timeout\n", kLogPrefix);
  return nullptr;
}

__attribute__((constructor))
void hso_native_init() {
  fprintf(stderr, "%s dylib loaded\n", kLogPrefix);

  pthread_t thread{};
  if (pthread_create(&thread, nullptr, installer_thread, nullptr) == 0)
    pthread_detach(thread);
}

}  // namespace
