%% diagnose_qpsk.m — 检查归档链 QPSK 映射/匹配滤波
clear; clc;
rng(1);
N = 20000;
sps = 8; beta = 0.35; span = 10;
h = rcosdesign(beta, span, sps, 'sqrt');
gds_cascade = (numel(h) - 1) / sps; % 10 symbols
fprintf('cascade gds symbols = %g\n', gds_cascade);

info = randi([0 1], 2*N, 1);
m = bi2de(reshape(info, 2, []).', 'left-msb');
sym = pskmod(m, 4, pi/4, 'gray');

b0 = pskdemod(sym, 4, pi/4, 'gray');
bits0 = de2bi(b0, 2, 'left-msb').'; bits0 = bits0(:);
fprintf('Symbol-only BER = %.6f\n', sum(bits0(1:2*N) ~= info)/(2*N));

tx = upfirdn(sym, h, sps);
rx = tx;
mf = upfirdn(rx, h, 1, sps);
fprintf('mf length=%d, need start=%d end=%d\n', numel(mf), gds_cascade+1, gds_cascade+N);

starts = unique([5, 10, 11, gds_cascade, gds_cascade+1, span/2+1]);
for off = starts(:)'
    last = off + N - 1;
    if last > numel(mf)
        fprintf('offset %d OOB (mf=%d)\n', off, numel(mf));
        continue;
    end
    sl = mf(off:last);
    bb = pskdemod(sl, 4, pi/4, 'gray');
    bt = de2bi(bb, 2, 'left-msb').'; bt = bt(:);
    nn = min(numel(bt), 2*N);
    fprintf('offset %d BER=%.6f\n', off, sum(bt(1:nn) ~= info(1:nn))/nn);
end

snr_dB = 6;
sigPow = mean(abs(tx).^2);
snr_ch = snr_dB + 10*log10(1) - 10*log10(sps);
rxn = awgn(tx, snr_ch, 'measured');
mfn = upfirdn(rxn, h, 1, sps);
mfn = mfn(gds_cascade+1 : gds_cascade+N);
bit_pairs = reshape(info, 2, []);
msb = bit_pairs(1,:).';
lsb = bit_pairs(2,:).';
fprintf('corr(MSB,sign(Im))=%.3f corr(LSB,sign(Re))=%.3f\n', ...
    corr(msb, sign(imag(mfn))), corr(lsb, sign(real(mfn))));
fprintf('corr(MSB,sign(-Im))=%.3f corr(LSB,sign(-Re))=%.3f\n', ...
    corr(msb, -sign(imag(mfn))), corr(lsb, -sign(real(mfn))));
fprintf('MATLAB_DIAG_OK\n');
