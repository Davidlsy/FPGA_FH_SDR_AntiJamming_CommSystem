## 工程结构

FPGA_FH_SDR_AntiJamming_CommSystem/
│
├── .gitattributes              # Git 属性
├── .gitignore                  # 忽略规则
├── LICENSE                     # MIT
├── README.md                   # 工程说明
│
├── src/                        # 【RTL 源码】
│   ├── fhss_top.v              #   冒烟顶层：50MHz 计数器 + LED 心跳
│   └── constraints/
│       └── fhss_zynq_timing.xdc  # 时序约束（跨板复用，唯一副本）
│
├── board/                      # 【板级约束】
│   └── fhss_zynq_pins.xdc      #   引脚 + IOSTANDARD（每板一份，唯一副本）
│
├── sim/                        # 【仿真】
│   └── tb_fhss_top.v           #   冒烟 testbench → [SMOKE] PASS/FAIL
│
├── build/                      # 【一键重建脚本】
│   ├── create_smoke_project.tcl  # Vivado batch：建工程→综合→实现→bit
│   └── vivado_smoke/           #   
│
├── sw/                         # 【上位机 / 软件】software
│   └── （Python 上位机等，产物 sw/build、sw/dist 已 ignore）
│
├── data/                       # 【数据 / 激励 / 参考结果】
├── skill/                      # 【技能 / 脚本 / 工具说明】
│
└── docs/                       # 【文档】
    ├── amd-board-requirements.html
    ├── amd-fhss-sim-only-plan.html          # 纯仿真路线 S0–S10
    ├── fpga-fhss-amd-implementation-plan.html
    ├── pins.md                 # 引脚映射表（与 board/fhss_zynq_pins.xdc 1:1）
    └── report/
        └── env.md              # 开发环境记录

## License

This project is licensed under the [MIT License](LICENSE).