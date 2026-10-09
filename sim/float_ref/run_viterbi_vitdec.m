function run_viterbi_vitdec(io_dir)
%RUN_VITERBI_VITDEC  S5 viterbi_dec BER 对比 · MATLAB vitdec 同序列交叉
%
% 读取 run_viterbi_ber.py 导出的 vitdec_in.mat（逐点逐帧 Q3.5 量化软序列，
% 与 Python 浮点参考 / 硬件忠实模型**同一批实数**），用 Communications
% Toolbox 的 vitdec 译码并回写逐点误码统计 vitdec_out.mat。
%
% 口径（与 RTL 滑窗语义对齐，见 docs/report/s5_viterbi_ber.md）：
%   trellis = poly2trellis(7, [171 133])（八进制，= config.CONV_GEN_POLY）
%   vitdec(soft, trellis, 96, 'trunc', 'unquant')
%     'trunc'  —— 滑窗截断模式，对应 RTL 回溯深度 96（非块最优 'term'）
%     'unquant'—— 软输入实数（正 = 更可能为 0），与 golden 同约定
%   每帧 4332 软比特 → 4332 译码比特，末 6 位是尾比特位置，取前 2160 位与
%   信息比特比对（与 Python 两路的去尾口径一致）。
%
% 用法（由 run_viterbi_ber.py 自动调用）：
%   matlab -batch "cd('sim/float_ref'); run_viterbi_vitdec('data/s5_viterbi_ber/matlab_io')"

    trellis = poly2trellis(7, [171 133]);
    tblen = 96;

    S = load(fullfile(io_dir, 'vitdec_in.mat'));
    n_pt = numel(S.soft);
    n_err = zeros(n_pt, 1, 'int64');
    n_bits = zeros(n_pt, 1, 'int64');

    for p = 1:n_pt
        sf = double(S.soft{p});          % 4332 × nf（Q3.5 格点实数）
        ib = double(S.info{p});          % 2160 × nf
        nf = size(sf, 2);
        for k = 1:nf
            dec = vitdec(sf(:, k), trellis, tblen, 'trunc', 'unquant');
            n_err(p) = n_err(p) + sum(dec(1:size(ib, 1)) ~= ib(:, k));
        end
        n_bits(p) = n_bits(p) + int64(size(ib, 1) * nf);
        fprintf('[vitdec] 点 %d/%d: %d 帧 %d bit, err=%d\n', ...
                p, n_pt, nf, n_bits(p), n_err(p));
    end

    save(fullfile(io_dir, 'vitdec_out.mat'), 'n_err', 'n_bits');
    fprintf('[vitdec] 回写 vitdec_out.mat PASS\n');
end
