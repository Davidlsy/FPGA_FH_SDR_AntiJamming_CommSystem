// =====================================================================
// ch_pkg.sv — S2 信道模型库 · 共用原语
//
// 三样东西，全部为 TB 侧行为模型服务（不可综合，也不需要综合）：
//   1. 定点量化 quant_rne_sat()：round-half-even + saturate，
//      与 golden_ref.fixed_point.quantizer.quantize()（np.round + clip）逐位对齐；
//   2. 确定性伪随机 xorshift32：可种子化、不依赖仿真器的 $urandom，
//      换仿真器只要 xorshift 不变，噪声实现就不变；
//   3. Box-Muller 高斯：均值 0、方差 1 的标准正态。
//
// 为什么量化要对齐 golden_ref：信道是 S5/S8 环回里 TX→RX 之间的那一环，
// 它的输出量化若与 S1 冻结基准不一致，BER 曲线就会差在量化台阶上，
// 而这种差异极难在整链里定位。位宽取自 docs/spec/fixed_point_spec.md。
// =====================================================================
package ch_pkg;

    // 缺省定点格式：与规格书「AWGN 信道输出 / 同步模块输出」一致
    localparam int CH_W    = 14;
    localparam int CH_FRAC = 11;

    localparam real PI = 3.14159265358979323846;

    // -----------------------------------------------------------------
    // 定点量化：半值取偶 + 饱和，与 golden_ref.quantizer 对齐
    //
    // golden_ref 用 np.round（半值取偶）再 clip 到补码范围，这里逐位复现。
    // 若用「四舍五入远离零」，在恰好 .5 的格点上会与参考差 1 LSB——
    // 对随机噪声而言概率为零，但对确定性的斜坡/常数激励是必然事件，
    // 所以必须对齐。
    //
    // 返回已饱和在 [-(2^(w-1)), 2^(w-1)-1] 内的整数值；调用方按自己的位宽截断即可。
    // 注意 $rtoi 为 32 位，本库使用范围（|scaled| < 2^24）内无精度损失。
    // -----------------------------------------------------------------
    function automatic longint quant_rne_sat(input real v, input int width, input int frac);
        real    scaled, fl, r;
        longint q, lo, hi;
        begin
            scaled = v * (2.0 ** frac);
            fl     = $floor(scaled);
            r      = scaled - fl;              // [0,1)
            q      = longint'($rtoi(fl));
            if (r > 0.5) begin
                q = q + 1;
            end else if (r == 0.5) begin
                if ((q % 2) != 0) q = q + 1;   // 半值取偶
            end
            lo = -(longint'(1) << (width - 1));
            hi =  (longint'(1) << (width - 1)) - 1;
            if (q > hi) q = hi;
            if (q < lo) q = lo;
            return q;
        end
    endfunction

    // 定点码 → 实数（步长 2^-frac）
    function automatic real from_fixed(input longint code, input int frac);
        return real'(code) / (2.0 ** frac);
    endfunction

    // -----------------------------------------------------------------
    // xorshift32：种子为 0 时退化为恒零，故 seed() 里兜一下
    // -----------------------------------------------------------------
    function automatic void xs32(inout logic [31:0] s);
        s ^= (s << 13);
        s ^= (s >> 17);
        s ^= (s << 5);
    endfunction

    function automatic logic [31:0] seed_nz(input logic [31:0] s);
        return (s == 32'h0) ? 32'h1CEB_00D5 : s;
    endfunction

    // 均匀分布 (0,1)：取 31 位并加 0.5，保证 0 与 1 都取不到，
    // 否则 Box-Muller 的 $ln(u) 会出现 -inf
    function automatic real urand01(inout logic [31:0] s);
        xs32(s);
        return (real'({1'b0, s[30:0]}) + 0.5) / 2147483648.0;
    endfunction

    // Box-Muller 标准正态：均值 0、方差 1
    function automatic real gauss01(inout logic [31:0] s);
        real u1, u2;
        begin
            u1 = urand01(s);
            u2 = urand01(s);
            return $sqrt(-2.0 * $ln(u1)) * $cos(2.0 * PI * u2);
        end
    endfunction

    // 复高斯：每维标准差 per_dim_sigma
    function automatic void cgauss(inout logic [31:0] s, input real per_dim_sigma,
                                   output real re, output real im);
        begin
            re = per_dim_sigma * gauss01(s);
            im = per_dim_sigma * gauss01(s);
        end
    endfunction

endpackage
