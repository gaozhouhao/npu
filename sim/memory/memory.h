#ifndef NPU_SIM_MEMORY_MEMORY_H_
#define NPU_SIM_MEMORY_MEMORY_H_

#include <cstdint>

extern "C" {

int memory_init(std::uint64_t size);
int memory_load_bin(const char* filename, std::uint64_t base_addr);

std::uint8_t memory_read8(std::uint64_t addr);
std::uint32_t memory_read32(std::uint64_t addr);

void memory_write8(std::uint64_t addr, std::uint8_t data);
void memory_write32(std::uint64_t addr, std::uint32_t data,
                    std::uint8_t write_mask);

}

#endif  // NPU_SIM_MEMORY_MEMORY_H_
