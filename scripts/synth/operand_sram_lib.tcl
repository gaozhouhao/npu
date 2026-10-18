# 将真实 SRAM 的 Liberty 文本库转换为 DC 使用的 .db 库。
# 请从工程的 build/lc/operand_sram 目录启动 Library Compiler。
set sram_lib "/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/NLDM/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.lib"
set sram_db "/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/NLDM/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.db"

read_lib $sram_lib
write_lib ts5n28hpcpsvta32x64m2f_tt0p9v25c -format db -output $sram_db

exit
