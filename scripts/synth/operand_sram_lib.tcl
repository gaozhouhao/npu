source [file join [file dirname [info script]] .. technology.tcl]

# 将真实 SRAM 的 Liberty 文本库转换为 DC 使用的 .db 库。
# 请从工程的 build/lc/operand_sram 目录启动 Library Compiler。

read_lib $sram_lib
write_lib ts5n28hpcpsvta32x64m2f_tt0p9v25c -format db -output $sram_db

exit
