#include "memory.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <vector>

namespace {

std::vector<std::uint8_t> memory;

void check_range(std::uint64_t addr, std::uint64_t width,
                 const char* operation) {
  const std::uint64_t size = memory.size();
  if (width > size || addr > size - width) {
    std::fprintf(stderr,
                 "[memory] %s out of bounds: addr=0x%llx width=%llu "
                 "memory_size=%llu\n",
                 operation, static_cast<unsigned long long>(addr),
                 static_cast<unsigned long long>(width),
                 static_cast<unsigned long long>(size));
    std::abort();
  }
}

}  // namespace

extern "C" int memory_init(std::uint64_t size) {
  if (size == 0 || size > std::numeric_limits<std::size_t>::max()) {
    std::fprintf(stderr, "[memory] invalid memory size: %llu\n",
                 static_cast<unsigned long long>(size));
    return 0;
  }

  memory.assign(static_cast<std::size_t>(size), 0);
  std::printf("[memory] initialized %llu bytes\n",
              static_cast<unsigned long long>(size));
  return 1;
}

extern "C" int memory_load_bin(const char* filename,
                               std::uint64_t base_addr) {
  if (filename == nullptr || memory.empty()) {
    std::fprintf(stderr,
                 "[memory] load failed: invalid filename or uninitialized "
                 "memory\n");
    return 0;
  }

  std::ifstream file(filename, std::ios::binary | std::ios::ate);
  if (!file) {
    std::fprintf(stderr, "[memory] cannot open binary: %s\n", filename);
    return 0;
  }

  const std::streamsize file_size = file.tellg();
  if (file_size < 0) {
    std::fprintf(stderr, "[memory] cannot determine binary size: %s\n",
                 filename);
    return 0;
  }

  const std::uint64_t load_size = static_cast<std::uint64_t>(file_size);
  if (load_size > memory.size() || base_addr > memory.size() - load_size) {
    std::fprintf(stderr,
                 "[memory] binary does not fit: base=0x%llx file_size=%llu "
                 "memory_size=%llu\n",
                 static_cast<unsigned long long>(base_addr),
                 static_cast<unsigned long long>(load_size),
                 static_cast<unsigned long long>(memory.size()));
    return 0;
  }

  file.seekg(0, std::ios::beg);
  if (file_size != 0 &&
      !file.read(reinterpret_cast<char*>(memory.data() + base_addr),
                 file_size)) {
    std::fprintf(stderr, "[memory] failed while reading binary: %s\n",
                 filename);
    return 0;
  }

  std::printf("[memory] loaded %llu bytes from %s at 0x%llx\n",
              static_cast<unsigned long long>(load_size), filename,
              static_cast<unsigned long long>(base_addr));
  return 1;
}

extern "C" std::uint8_t memory_read8(std::uint64_t addr) {
  check_range(addr, 1, "read8");
  return memory[addr];
}

extern "C" std::uint32_t memory_read32(std::uint64_t addr) {
  check_range(addr, 4, "read32");
  return static_cast<std::uint32_t>(memory[addr]) |
         (static_cast<std::uint32_t>(memory[addr + 1]) << 8) |
         (static_cast<std::uint32_t>(memory[addr + 2]) << 16) |
         (static_cast<std::uint32_t>(memory[addr + 3]) << 24);
}

extern "C" void memory_write8(std::uint64_t addr, std::uint8_t data) {
  check_range(addr, 1, "write8");
  memory[addr] = data;
}

extern "C" void memory_write32(std::uint64_t addr, std::uint32_t data,
                               std::uint8_t write_mask) {
  check_range(addr, 4, "write32");
  for (std::uint64_t byte = 0; byte < 4; ++byte) {
    if ((write_mask & (1U << byte)) != 0) {
      memory[addr + byte] =
          static_cast<std::uint8_t>(data >> (8 * byte));
    }
  }
}
