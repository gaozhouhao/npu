#pragma once
#include <cstdint>
struct VerilatedContext { void commandArgs(int,char**) {} void timeInc(uint64_t) {} bool gotFinish() const {return false;} };
