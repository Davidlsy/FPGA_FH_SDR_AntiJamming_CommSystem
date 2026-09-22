%% run_ber_sweep.m — P1-S6 浮点参考链
% 随机源 → CC(171,133)_8 → 交织(深度10) → QPSK → SRRC(0.35)
% → AWGN → 匹配滤波 → 理想同步 → 解交织 → 软判决 Viterbi
clear; clc; close all;
rng(2026);                                 % 固定种子：黄金参考必须可复现

%% ---------- 参数 ----------
P.sps     = 8;                             % 每符号采样数
P.beta    = 0.35;                          % SRRC 滚降
P.span    = 10;                            % 滤波器跨度(符号)
P.trellis = poly2trellis(7, [171 133]);   % 八进制 (171,133), R=1/2, K=7
P.depth   = 10;                            % 交织深度(行)
P.tblen   = 96;                            % Viterbi 回溯深度 ≥ 5K
P.EbN0    = 0:1:12;                       % 扫描范围 dB
P.Ninfo   = 2e6;                           % 每点信息比特(1e-5 附近点改 1e7+)

h   = rcosdesign(P.beta, P.span, P.sps, 'sqrt');   % 收发共用 SRRC
gds = P.span/2;                            % 群延迟(符号) = 5
berT = berawgn(P.EbN0, 'psk', 4, 'nondiff');     % 未编码 QPSK 理论线(图5-1)

%% ---------- 扫描 ----------
berUnc = zeros(size(P.EbN0)); berCoded = berUnc;
for i = 1:numel(P.EbN0)

  % ===== 编码链 =====
  info = randi([0 1], P.Ninfo, 1);
  enc  = convenc([info; zeros(6,1)], P.trellis);    % 尾比特回零, 长度 2(N+6)
  nPad = mod(-numel(enc), P.depth);                  % 补齐到深度10整除
  itlv = reshape(reshape([enc; zeros(nPad,1)], [], P.depth).', [], 1);  % 交织(行入列出)

  m    = bi2de(reshape(itlv, 2, []).', 'left-msb'); % 2bit → 符号整数
  sym  = pskmod(m, 4, pi/4, 'gray');
  tx   = upfirdn(sym, h, P.sps);                     % 上采样 + SRRC 成形

  % Eb/N0 → 信道 SNR：编码链 k = 2R = 1
  sigPow = mean(abs(tx).^2);
  snr_dB = P.EbN0(i) + 10*log10(1) - 10*log10(P.sps);
  rx     = awgn(tx, snr_dB, 'measured');
  nVar   = sigPow / 10^(snr_dB/10);                  % 供 LLR 用

  mf   = upfirdn(rx, h, 1, P.sps);                  % 匹配滤波 + 下采样
  mf   = mf(gds+1 : gds+numel(sym));               % 补群延迟(理想同步)

  % QPSK pi/4 Gray 近似LLR: MSB←Im, LSB←Re; 正→0, 负→1
  % 星座: 00(+,+),01(-,+),10(+,-),11(-,-) → MSB由Im符号决定, LSB由Re符号决定
  llr  = 2*sqrt(2) * [imag(mf), real(mf)] / nVar;   % N×2 [MSB_LLR, LSB_LLR]
  s    = llr(:);                                     % 列展开: MSB1,LSB1,MSB2,LSB2,...
  % 若小信噪比下 BER≈0.5, 说明 LLR 方向相反, 改为 s = -llr(:);

  de   = reshape(reshape(s, P.depth, []).', [], 1);  % 解交织(转置逆)
  de   = de(1:numel(enc));                          % 去 pad
  dec  = vitdec(de, P.trellis, P.tblen, 'term', 'unquant');
  berCoded(i) = biterr(dec(1:P.Ninfo), info) / P.Ninfo;

  % ===== 未编码对照(同一 SRRC 信道, k=2) =====
  info2 = randi([0 1], 2*P.Ninfo, 1);
  m2    = bi2de(reshape(info2, 2, []).', 'left-msb');
  tx2   = upfirdn(pskmod(m2, 4, pi/4, 'gray'), h, P.sps);
  snr2  = P.EbN0(i) + 10*log10(2) - 10*log10(P.sps);
  rx2   = awgn(tx2, snr2, 'measured');
  mf2   = upfirdn(rx2, h, 1, P.sps);
  mf2   = mf2(gds+1 : gds+2*P.Ninfo);
  b2    = pskdemod(mf2, 4, pi/4, 'gray');
  berUnc(i) = biterr(de2bi(b2,2,'left-msb').', info2) / (2*P.Ninfo);

  fprintf('Eb/N0=%2d dB  unc=%9.3e (th %9.3e)  coded=%9.3e\n', ...
          P.EbN0(i), berUnc(i), berT(i), berCoded(i));
end

%% ---------- 绘图 ----------
semilogy(P.EbN0, berT, 'k--', P.EbN0, berUnc, 'o-', P.EbN0, berCoded, 's-');
grid on; xlabel('E_b/N_0 (dB)'); ylabel('BER');
legend('理论未编码(图5-1)','仿真未编码','仿真编码 R=1/2,K=7 软判决');
title('P1-S6 浮点参考链 BER'); ylim([1e-6 1]);
save('results/ber.mat', 'P', 'berT', 'berUnc', 'berCoded');
