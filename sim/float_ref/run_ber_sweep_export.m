%% run_ber_sweep_export.m — V2.x 归档链导出 CSV（与 run_ber_sweep.m 同算法/参数）
% 来源: D:\My_project\归档\GoWin_SDR\matlab\run_ber_sweep.m
% 用法: matlab -batch "Ninfo=3e5; EbN0=0:8; run_ber_sweep_export"
clearvars -except Ninfo EbN0 out_csv
clc;

if ~exist('Ninfo','var') || isempty(Ninfo), Ninfo = 3e5; end
if ~exist('EbN0','var') || isempty(EbN0), EbN0 = 0:1:8; end

here = fileparts(mfilename('fullpath'));
if ~exist('out_csv','var') || isempty(out_csv)
    out_csv = fullfile(here, 'results', 'matlab_archive_ber.csv');
end
if ~exist(fileparts(out_csv),'dir'), mkdir(fileparts(out_csv)); end

rng(2026);                                 % 与归档脚本一致

P.sps     = 8;
P.beta    = 0.35;
P.span    = 10;
P.trellis = poly2trellis(7, [171 133]);
P.depth   = 10;
P.tblen   = 96;
P.EbN0    = EbN0;
P.Ninfo   = Ninfo;

h   = rcosdesign(P.beta, P.span, P.sps, 'sqrt');
% 收发各一级 SRRC，级联群延迟 = (numel(h)-1)/sps = span 符号
% 归档脚本误用 gds=span/2（仅单级），会导致 BER≈0.5
gds = (numel(h) - 1) / P.sps;   % = P.span
berT = berawgn(P.EbN0, 'psk', 4, 'nondiff');

berUnc = zeros(size(P.EbN0));
berCoded = berUnc;

for i = 1:numel(P.EbN0)
    info = randi([0 1], P.Ninfo, 1);
    enc  = convenc([info; zeros(6,1)], P.trellis);
    nPad = mod(-numel(enc), P.depth);
    itlv = reshape(reshape([enc; zeros(nPad,1)], [], P.depth).', [], 1);

    m    = bi2de(reshape(itlv, 2, []).', 'left-msb');
    sym  = pskmod(m, 4, pi/4, 'gray');
    tx   = upfirdn(sym, h, P.sps);

    sigPow = mean(abs(tx).^2);
    snr_dB = P.EbN0(i) + 10*log10(1) - 10*log10(P.sps);
    rx     = awgn(tx, snr_dB, 'measured');
    nVar   = sigPow / 10^(snr_dB/10);

    mf   = upfirdn(rx, h, 1, P.sps);
    n_sym = numel(sym);
    n_mf = numel(mf);
    idx_end = min(gds + n_sym, n_mf);
    mf   = mf(gds+1 : idx_end);
    if numel(mf) < n_sym
        mf = [mf; zeros(n_sym - numel(mf), 1)];
    else
        mf = mf(1:n_sym);
    end

    llr  = 2*sqrt(2) * [imag(mf), real(mf)] / nVar;  % N×2 [MSB, LSB]
    % MATLAB vitdec('unquant'): 正值→0, 负值→1
    % 本机 pskmod Gray: MSB=1 时 Im<0, LSB=1 时 Re<0 → 直接用 +Im/+Re
    % 按符号行展开为 MSB1,LSB1,MSB2,LSB2…（勿用 llr(:) 列主序）
    s    = reshape(llr.', [], 1);
    de   = reshape(reshape(s, P.depth, []).', [], 1);
    de   = de(1:numel(enc));
    dec  = vitdec(de, P.trellis, P.tblen, 'term', 'unquant');
    berCoded(i) = biterr(dec(1:P.Ninfo), info) / P.Ninfo;

    info2 = randi([0 1], 2*P.Ninfo, 1);
    m2    = bi2de(reshape(info2, 2, []).', 'left-msb');
    tx2   = upfirdn(pskmod(m2, 4, pi/4, 'gray'), h, P.sps);
    snr2  = P.EbN0(i) + 10*log10(2) - 10*log10(P.sps);
    rx2   = awgn(tx2, snr2, 'measured');
    mf2   = upfirdn(rx2, h, 1, P.sps);
    n_u = 2*P.Ninfo;
    n_mf2 = numel(mf2);
    idx2 = min(gds + n_u, n_mf2);
    mf2   = mf2(gds+1 : idx2);
    if numel(mf2) < n_u
        mf2 = [mf2; zeros(n_u - numel(mf2), 1)];
    else
        mf2 = mf2(1:n_u);
    end
    b2    = pskdemod(mf2, 4, pi/4, 'gray');
    bits2 = de2bi(b2, 2, 'left-msb').';
    bits2 = bits2(:);
    n_cmp = min(numel(bits2), numel(info2));
    berUnc(i) = sum(bits2(1:n_cmp) ~= info2(1:n_cmp)) / n_cmp;

    fprintf('Eb/N0=%2d dB  unc=%9.3e (th %9.3e)  coded=%9.3e  Ninfo=%g\n', ...
            P.EbN0(i), berUnc(i), berT(i), berCoded(i), P.Ninfo);
end

T = table(P.EbN0(:), berT(:), berUnc(:), berCoded(:), ...
    'VariableNames', {'eb_n0_db','ber_theory_unc','ber_unc','ber_coded'});
writetable(T, out_csv);
save(fullfile(fileparts(out_csv), 'matlab_archive_ber.mat'), ...
     'P', 'berT', 'berUnc', 'berCoded');
fprintf('WROTE %s\n', out_csv);
fprintf('MATLAB_ARCHIVE_EXPORT_OK\n');
