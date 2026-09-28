// =====================================================================
// frame_tx_sync.vh — 帧同步字常量（生成物，请勿手改）
//
// 生成器: sim/golden_ref/gen_frame_sync.py
// 黄金源: golden_ref.float_chain.framing.gold_sync_word()
// 构造  : 6 级 m 序列优选对 0o103 与 0o133 逐位异或，
//         周期 2^6-1 = 63，取 64 bit（末位重复首位）
// 规格  : docs/spec/frame_format.md §2
// 校验  : python sim/golden_ref/gen_frame_sync.py --check
// =====================================================================
localparam [63:0] FRAME_SYNC_WORD = 64'h517AE4216E7555CA;
