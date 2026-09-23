# AD9363 SPI 行为模型

寄存器数组 + 读写状态机 + 回读校验 + 异常注入（超时 / 错误回读 / 复位中断）的
AD9363 SPI 从端仿真模型（SystemVerilog）。寄存器默认值取自 ADI UG-672
寄存器表（AD9363 与 AD9364 寄存器映射兼容）并对照 no-OS 驱动 `ad9361.c`
关键覆盖项，共 438 个寄存器带非零默认值/访问属性。

## 文件清单

| 文件 | 说明 |
|---|---|
| `ad9363_spi_model.sv` | SPI 从端行为模型（本模型，被测/被集成单元） |
| `ad9363_regs_def.vh` | 1024 项寄存器默认值 + 访问属性（RW/RO/保留），由 UG-672 生成 |
| `ad9363_defs.vh` | 寄存器地址 / 位域 / 访问属性宏（`REG_*`, `PRODUCT_ID_*` 等） |
| `tb_ad9363_spi_model.sv` | 测试平台：SPI 主机 BFM + 六项测试 |
| `run_xsim.sh` | Vivado xsim 编译运行脚本（支持 `gui` 参数开波形） |
| `run_xsim.bat` | 同上，Windows 批处理版（带 PASS/FAIL 闸门，日志写 `sim_run.log`） |
| `run_iv.sh` | Icarus Verilog 快速回归脚本（CI 用） |

## 模型特性

- **指令格式**：16 bit，`D15=W/R`，`D14:12=NB(字节数-1)`，`D11:10` 保留，`D9:0=地址`；
  多字节访问地址自增，10-bit 空间回绕（0x3FF→0x000）
- **SPI 时序**：模式 0，4 线（SDIO 入 / SDO 出），MSB-first，SDO 在上升沿后
  `TCO_NS`（默认 5 ns，手册 3~8 ns）更新
- **访问保护**：RO 写忽略、保留地址写忽略读 0x00，均有计数器
- **回读校验**：模型内置检查器，移出的读字节与寄存器堆比对，不一致计入
  `err_rdback_cnt`（可捕获注入错误，区分 injected/UNEXPECTED）
- **异常注入 API**（testbench 分层调用）：
  - `inject_readback_err(mask, n)`：后续 n 个读字节与 mask 异或
  - 超时看门狗：CSB 低期间 SCLK 停滞超过 `TIMEOUT_NS`（默认 1 µs）→ 中止事务、释放 SDO
  - 硬复位 `GP_RESETB` / 软复位（写 0x81 到 0x000）：事务中异步打断 + 寄存器恢复默认值
- **后门/统计接口**：`peek_reg`、`peek_reg_def`、`peek_acc`、`reset_stats`、`model_report`
- **CSB 上升沿**：模型靠 `posedge csb` 从 `ST_DONE` 回到 `IDLE`（与真机一致）。
  上层 SPI 主机 BFM 必须在两次事务之间给出真实的 CSB 高电平时间——若升高后
  在同一仿真时间步内立刻拉低，xsim 不向模型投递 `posedge csb`，整个模型会
  卡死在 `ST_DONE`（现象：SDO 恒为 `z`、`err_extra_clk_cnt` 等于全部时钟数）。

## 六项测试（通过时 1444~1446 项检查）

| 测试 | 内容 |
|---|---|
| T1 | 复位后默认值：24 个人工核对的金标准 + 0x000~0x3FF 全扫描（128×8 字节突发读）+ Product ID |
| T2 | 单/多字节读写回读、8 字节满突发、RO/保留写保护 |
| T3 | 超时注入：指令阶段 / 读数据阶段 SCLK 停滞 → 看门狗中止 + 恢复 |
| T4 | 错误回读注入：单字节取反、多字节高位翻转，校验捕获计数 |
| T5 | 复位中断：事务中硬复位（GP_RESETB 脉冲）/ 事务中软复位 / 常规软复位 |
| T6 | 随机压力：200 次随机写读 + 30 次随机长度突发 + 地址回绕边角 |

## 运行

```bash
# xsim (Vivado)
./run_xsim.sh          # 命令行
./run_xsim.sh gui      # GUI 波形

# 或 Icarus Verilog
./run_iv.sh
```

Windows / PowerShell（本仓库工具链 Vivado ML 2021.2）：

```powershell
# 先让 xvlog/xelab/xsim 进 PATH，例如
#   D:\software\vivado2021\Vivado\2021.2\settings64.bat

.\run_xsim.bat         # 编译+运行，末尾打印 PASS/FAIL，日志落 sim_run.log
.\run_xsim.bat gui     # 开波形 GUI
```

两个 `.vh` 必须与 `.sv` 同目录（xvlog 按当前目录解析 `include`），故脚本先 `cd` 到
自身所在目录。

期望结果：`RESULT : *** ALL TESTS PASSED ***`（已验证：checks=1444~1446, errors=0）。

> 检查总数不是定值：T6 用 `$urandom` 生成随机突发长度，总数随随机序列在
> 1444~1446 之间浮动。验收判据用 `errors=0` / `ALL TESTS PASSED`，不要写死检查数。

## 已知修复记录

| 日期 | 文件 | 问题 | 修复 |
|---|---|---|---|
| 2026-09-23 | `tb_ad9363_spi_model.sv` | `spi_txn` 升高 CSB 后下一次调用立刻拉低，两者同处一个仿真时间步。xsim 不投递 `posedge csb`，模型卡死在 `ST_DONE`，本机 xsim 下 1409 项检查里 1406 项失败（iverilog 下不复现） | 事务结尾补 `#(TCLK)` 的 CSB 高电平间隔，恢复 1444~1446 项全通过 |
