#ifndef EEGBINFORMAT_H
#define EEGBINFORMAT_H

#include <QtGlobal>

// .eegbin 记录文件的格式定义。
//
// **写端与读端共用这一份**：serialcollector.cpp 按它落盘，recordingpreview.cpp
// 按它回放。以前两边各写一份常量、只靠注释约定「必须逐字对应」—— 那种约定在
// 格式改动时必然失效，而失效的表现是「回放出来的波形是乱的」，不是报错
//
// 64 字节文件头（全小端），其后是连续的样本记录：
//   偏移 0   magic[8]      "EEGBIN01"
//        8   version       u32
//       12   channels      u32
//       16   sample_rate   u32
//       20   header_size   u32（= 64）
//       24   start_utc_ms  i64
//       32   frame_count   i64（收尾时回填，写头时置 0）
//       40   reserved[24]
// 样本记录：float32 帧优先交错，每帧 channels 个值，单位 µV
namespace eegbin
{

inline constexpr char kMagic[8] = {'E', 'E', 'G', 'B', 'I', 'N', '0', '1'};
inline constexpr quint32 kVersion = 1;
inline constexpr int kHeaderSize = 64;

inline constexpr int kVersionOffset = 8;
inline constexpr int kChannelsOffset = 12;
inline constexpr int kSampleRateOffset = 16;
inline constexpr int kHeaderSizeOffset = 20;
inline constexpr int kStartTimeOffset = 24;
inline constexpr int kFrameCountOffset = 32;

// 每个样本占的字节数（float32）
inline constexpr int kBytesPerSample = 4;

} // namespace eegbin

#endif // EEGBINFORMAT_H
