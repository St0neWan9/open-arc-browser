# Codecs: H.264, AAC and HEVC through the macOS system decoders (plan C18)

Decision Q6 says v1 ships open codecs only: VP8, VP9 and AV1 for video, and Opus, Vorbis, FLAC, MP3 and PCM for audio, with `proprietary_codecs = false`. Task C18 asks whether H.264, AAC and HEVC can play by handing decoding to macOS (VideoToolbox for video, AudioToolbox for audio), without shipping FFmpeg's or OpenH264's software decoders for those formats. This document records how Chromium 156 picks decoders on Mac, the configuration we found, what it covers, and what it leaves out.

**Legal note.** This is an engineering note, not legal advice. Whether a browser that parses H.264, HEVC or AAC bitstreams and passes them to the operating system's licensed decoders needs its own patent licenses (MPEG LA / Via LA AVC and AAC pools, Access Advance and others for HEVC), and how the answer changes with distribution and revenue, are questions for counsel. Nothing here concludes either way. Demuxers, bitstream parsers and the H.264/HEVC "accelerator" front ends (slice header parsing, reference picture management) stay in the build, and counsel should know that. The build must not ship with this configuration until counsel has reviewed it (plan C18 acceptance).

## How Chromium chooses decoders on Mac

All paths below are in `~/chromium/src`.

**GN arguments** (`build/config/features.gni`, `media/media_options.gni`, `third_party/ffmpeg/ffmpeg_options.gni`):

| Argument | What it controls |
|---|---|
| `proprietary_codecs` | The `USE_PROPRIETARY_CODECS` build flag. With it off, `media/base/supported_types.cc` rejects H.264, HEVC, AAC, AC-3 and others outright (`IsVideoCodecProprietary` / `IsAudioCodecProprietary`), and the MIME tables in `media/base/mime_util_internal.cc` do not list `video/mp4` with `avc1`, `mp4a` and so on. It also compiles in the MP4 parts that need it: the MSE MP4 stream parser's AVC, HEVC and AAC handling (`media/formats/mp4/`), ADTS framing, the H.264 / H.265 Annex B bitstream converters (`media/filters/`), the FFmpeg demuxer's AAC demuxer (`aac` in `GetAllowedDemuxers`) and its bitstream converters. MP4 demuxing therefore needs `proprietary_codecs = true` even when nothing in the build decodes these codecs. |
| `ffmpeg_branding` | Which generated FFmpeg configuration is built (`third_party/ffmpeg/chromium/config/<branding>/mac/<arch>/`). **`"Chromium"`**: decoders FLAC, MP3, Vorbis, PCM and libopus; demuxers FLAC, Matroska, MOV/MP4, MP3, Ogg and WAV. No H.264 decoder, no AAC decoder, no H.264 or AAC parser, no AAC (ADTS) demuxer. **`"Chrome"`**: the same plus the H.264 decoder, the AAC decoder, the AAC and H.264 parsers and the AAC demuxer, which is where the patent-encumbered software decoders come from. The source lists in `ffmpeg_generated.gni` follow the branding (for example `h264dec.c` and `aacdec*.c` only with `"Chrome"`). |
| `enable_ffmpeg_video_decoders` | Builds `FFmpegVideoDecoder`, which only ever decodes H.264 (`FFmpegVideoDecoder::IsCodecSupported`), and lets `IsDecoderBuiltInVideoCodec(kH264)` return true. |
| `media_use_openh264` | OpenH264 (software H.264 *encoder*, used by WebRTC, MediaRecorder and WebCodecs). Already off when `proprietary_codecs` is off. |
| `enable_platform_hevc`, `enable_hevc_parser_and_hw_decoder` | HEVC demuxing, Chromium's own HEVC parser and the VideoToolbox HEVC accelerator. On by default on Mac whenever `proprietary_codecs` is on. HEVC never had a software decoder in Chromium. |
| `enable_hls_demuxer`, `enable_mse_mpeg2ts_stream_parser` | HLS and MPEG-2 TS in MSE. Default to `proprietary_codecs`. |
| `enable_platform_ac3_eac3_audio`, `enable_platform_dts_audio`, `enable_platform_dolby_vision` | Off on Mac by default; we leave them off. |
| (upstream assert) | `media/BUILD.gn` refuses `proprietary_codecs = true` with `ffmpeg_branding = "Chromium"`, because upstream assumes FFmpeg is the AAC/H.264 decoder. |

**Decoder selection at run time.** The renderer's `DefaultDecoderFactory` (`media/renderers/default_decoder_factory.cc`) lists candidates in order, and `DecoderSelector` tries them until one initializes:

- Video: the GPU process's decoder through `MojoVideoDecoder` (only when GPU video decode is enabled), then libvpx, dav1d, then `FFmpegVideoDecoder` if it is built. Above a height of 360 px platform decoders come first (`media/filters/decoder_selector.cc`). In the GPU process `GpuMojoMediaClientMac` (`media/mojo/services/gpu_mojo_media_client_mac.cc`) creates `VideoToolboxVideoDecoder` (`media/gpu/mac/video_toolbox_video_decoder.cc`), which parses H.264 / HEVC / VP9 / AV1 with Chromium's own parsers and hands the slices to a `VTDecompressionSession`. On Apple silicon it asks for hardware decode (`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`); for HEVC, and for H.264 on Intel, software decode inside VideoToolbox is allowed (`allow_software_decoding` in the accelerators). Either way the decoder is Apple's.
- Audio: `FFmpegAudioDecoder`, then the GPU process's decoder through `MojoAudioDecoder`. Upstream on Mac the latter is `AudioToolboxAudioDecoder` (`media/filters/mac/audio_toolbox_audio_decoder.cc`), but it only accepts xHE-AAC (USAC), plus AC-3/E-AC-3 when those are enabled. Plain AAC-LC and HE-AAC therefore need FFmpeg's AAC decoder upstream. That is the one real gap that blocks "platform only" without patches.
- Capability answers (`canPlayType`, `MediaSource.isTypeSupported`, Media Capabilities) come from `media::IsDecoderSupported{Audio,Video}Type`. Upstream reports H.264 as always supported (it can count on FFmpeg) and AAC as always supported except xHE-AAC. HEVC is answered from the profiles the GPU process reported (`RenderMediaClient`, `PLATFORM_HAS_OPTIONAL_HEVC_DECODE_SUPPORT`).

## The configuration

GN arguments (on top of `out/Release/args.gn`):

```gn
proprietary_codecs = true          # MP4 / MSE / ADTS / TS demuxing of H.264, HEVC, AAC
ffmpeg_branding = "Chromium"       # FFmpeg without H.264 or AAC decoders
media_proprietary_decoders_platform_only = true   # new, from patch 0009
```

`media_proprietary_decoders_platform_only` is a new argument that patch `0008-openarc-media-decode-H.264-and-AAC-only-with-the-pla.patch` adds to `media/media_options.gni`. It is upstream code only, so it sits before the `//openarc` patches in the series. With the argument off (the default, and `out/Release` today) every change compiles away. With it on:

1. **GN.** It forces `enable_ffmpeg_video_decoders = false` (no `FFmpegVideoDecoder`) and `media_use_openh264 = false` (no OpenH264, so WebRTC has no bundled H.264 either: `rtc_use_h264` follows it). It asserts `proprietary_codecs`, macOS, and `ffmpeg_branding == "Chromium"`, replacing upstream's opposite assert in `media/BUILD.gn`. It also exports the build flag `MEDIA_PROPRIETARY_DECODERS_PLATFORM_ONLY`.
2. **`AudioToolboxAudioDecoder`** accepts every AAC profile, not just xHE-AAC. It uses `kAudioFormatMPEG4AAC` with the `esds` built from the AudioSpecificConfig as the magic cookie, so macOS works out LC, HE-AAC (SBR) and HE-AAC v2 (PS) itself, and USAC stays `kAudioFormatMPEGD_USAC`. It strips an ADTS header when one frames the access unit: the MSE MP4 parser prepends ADTS to every AAC sample, and the ADTS and MPEG-2 TS parsers pass ADTS frames through. It checks the frame-length field first, so a raw access unit is never mistaken for ADTS. Loudness and DRC settings stay xHE-AAC only. AAC without an AudioSpecificConfig is refused.
3. **`GpuMojoMediaClientMac`** also reports `{AAC, kUnknown}` (LC / HE-AAC) as supported, besides `{AAC, xHE-AAC}`.
4. **`supported_types.cc`** answers H.264 and AAC from what the GPU process reported (the same caches the HEVC and xHE-AAC answers already use), not "always yes". When GPU video decode is off (blocklisted GPU, `--disable-accelerated-video-decode`, or VideoToolbox missing H.264), `canPlayType` and `isTypeSupported` should then say no for H.264, so sites such as YouTube fall back to VP9 or AV1 instead of failing (inferred from the code path, not tested).
5. **FFmpeg glue** (src= playback through `FFmpegDemuxer`). FFmpeg has no AAC or H.264 decoder to probe sample or pixel formats with. For AAC an unknown sample format becomes planar float (what AudioToolbox outputs; only the config needs a valid value), and the bytes-per-sample `DCHECK` is skipped for it. For H.264 an unset pixel format becomes I420, as upstream already does for HEVC. `aac` is dropped from the FFmpeg audio decoder allowlist.

The `openarc/156` commit is `openarc: media: decode H.264 and AAC only with the platform decoders`, exported as `chromium-patches/156/0008-…patch`. It comes after the `0001`–`0007` upstream patches and before the `//openarc` patches (now `0009`–`0015`); see the series README.

## Covered

| Path | H.264 | HEVC | AAC |
|---|---|---|---|
| `<video src>` MP4 / MOV / M4A (FFmpeg demuxer) | VideoToolbox | VideoToolbox | AudioToolbox |
| MSE fMP4 (`video/mp4`, `audio/mp4`) | VideoToolbox | VideoToolbox | AudioToolbox |
| MSE MPEG-2 TS, ADTS (`audio/aac`), HLS demuxer | VideoToolbox | VideoToolbox | AudioToolbox |
| WebCodecs `VideoDecoder` / `AudioDecoder` (expected, not tested) | VideoToolbox | VideoToolbox | AudioToolbox |
| WebRTC receive (expected, not tested) | VideoToolbox through Chromium's GPU decoder adapter; no bundled software fallback | VideoToolbox | (WebRTC audio is Opus) |

AAC profiles: LC, HE-AAC v1/v2 and xHE-AAC as far as AudioToolbox supports them. H.264 profiles: the ones VideoToolbox advertises to Chromium (Baseline, Main, High; `VideoToolboxVideoDecoder::GetSupportedVideoDecoderConfigs`), sizes 64×64 to 4096×4096 on Apple silicon. HEVC: Main, Main 10 and the RExt profiles that VideoToolbox reports, up to 8192×8192.

## Not covered, and fallbacks

- **No GPU video decode.** With the GPU process blocklisted or software-only (SwiftShader), the renderer creates no Mojo video decoder, so H.264 and HEVC cannot play at all. Capability checks report this (item 4), and sites pick VP9 or AV1 (libvpx and dav1d stay bundled).
- **H.264 profiles VideoToolbox does not take**: High 10, 4:2:2, 4:4:4 and the scalable and multiview profiles. Upstream plays some of these through FFmpeg. Here they fail, and `canPlayType` already returns `""` or `"maybe"` for them. On Apple silicon VideoToolbox H.264 is hardware only (Chromium asks for it), so sizes below 64×64 do not decode.
- **Encrypted (EME) H.264 / AAC**: needs a CDM (Widevine is not in v1). Clear Key is a test CDM only.
- **AAC without an AudioSpecificConfig** (raw AAC in odd containers) is refused rather than guessed.
- **Encoding.** OpenH264 is not built, so MediaRecorder / WebCodecs H.264 encoding and WebRTC H.264 sending use VideoToolbox's encoder (`MayHaveAndAllowSelectOSSoftwareEncoder`), and AAC encoding uses AudioToolbox. Encoders raise the same licensing question as decoders and are part of counsel's review.
- **Still in the build:** Chromium's own H.264 / HEVC bitstream parsers and decoder state machines (`media/parsers`, `media/gpu/h264_decoder.cc`, `h265_decoder.cc`). They produce no pixels (VideoToolbox does), but they are bitstream processing of these formats.

## Verification

Measured on 2026-10-25 on Apple silicon (arm64, macOS 26), framework from `out/Release_codecs`, in a private dev app instance.

**No FFmpeg H.264 / AAC / HEVC decoders (observed).** `third_party/ffmpeg/chromium/config/Chromium/mac/arm64/libavcodec/codec_list.c` lists only FLAC, MP3, Vorbis, PCM and libopus decoders. `nm` on the built `OpenArcCore.framework/Versions/A/OpenArcCore` finds:
- none of `ff_h264_decoder`, `ff_hevc_decoder`, `ff_aac_decoder`, `ff_aac_fixed_decoder`, `ff_aac_latm_decoder`, `ff_h264_parser`, `ff_hevc_parser`, `ff_aac_parser`, `ff_aac_demuxer`, `ff_h264_decode_init`;
- no OpenH264 (`WelsCreateDecoder`, `WelsCreateSVCEncoder`) and no `FFmpegVideoDecoder`;
- FFmpeg's `_decoder` symbols are exactly FLAC, MP3, Vorbis, the PCM family and libopus. The only H.264/HEVC/AAC names left in FFmpeg are its static profile-name tables (`ff_h264_profiles`, `ff_hevc_profiles`, `ff_aac_profiles`, from `libavcodec/profiles.c`);
- `ff_mov_demuxer` (MP4 container) is present, and so are `AudioToolboxAudioDecoder`, `VideoToolboxVideoDecoder` and Chromium's `H264Decoder` / `H265Decoder` front ends.

**Playback (observed).** Test files were made with `AVAssetWriter` (640×360, 30 fps, H.264 High `avc1.64001e`, HEVC Main `hvc1.1.6.L63.B0`, AAC-LC 44.1 kHz stereo; fragmented MP4 via `AVAssetWriter` segment output). A local page reports `canPlayType`, `MediaSource.isTypeSupported`, playback to `timeupdate` > 1 s, and WebCodecs / Media Capabilities answers.

| Case | Result |
|---|---|
| src= `h264_aac.mp4` | plays, 640×360, frames decoded, 0 dropped, audio bytes decoded |
| src= `h264_only.mp4` | plays |
| src= `hevc_aac.mp4` | plays, video and audio |
| src= `aac_only.m4a` | plays (audio) |
| MSE fMP4 H.264 (`video/mp4; codecs="avc1.64001e"`) | plays |
| MSE fMP4 AAC (`audio/mp4; codecs="mp4a.40.2"`, ADTS-prepended samples) | plays |
| MSE fMP4 HEVC (`video/mp4; codecs="hvc1.1.6.L63.B0"`) | plays |
| `canPlayType` / `isTypeSupported` for `avc1.42E01E`, `avc1.64001e`, `avc1.640028, mp4a.40.2`, `hvc1`/`hev1` Main and Main 10, `mp4a.40.2/.5/.29`, `audio/aac` | `probably` / `true` |
| WebCodecs `VideoDecoder.isConfigSupported` H.264 and HEVC with `prefer-software` | `false` (no software decoder is bundled) |
| … with `prefer-hardware` / `no-preference` | `true` |
| WebCodecs `AudioDecoder.isConfigSupported` `mp4a.40.2` | `true` |
| Media Capabilities `decodingInfo` (MSE, H.264 and HEVC 640×360) | supported, smooth, power efficient |

Video can only come from VideoToolbox here: the build has no other H.264 or HEVC decoder, and WebCodecs confirms that no software decoder exists. Audio comes from AudioToolbox, because FFmpeg's allowlist and build have no AAC decoder.

Not tested yet: WebCodecs decoding itself (only `isConfigSupported`), WebRTC, the MPEG-2 TS / HLS demuxers, HE-AAC v2 and xHE-AAC files, Intel Macs, YouTube itself, and long or seek-heavy playback. A first build hit a debug check (`DCHECK`) in `AVCodecContextToAudioDecoderConfig` (bytes per sample for demux-only AAC); this is fixed in patch 0009 and is the reason it skips that check for AAC.

## Switching the main build

`out/Release` keeps `proprietary_codecs = false` until counsel has reviewed this. The experiment builds in `out/Release_codecs` (an APFS clone of `out/Release` with the arguments above): `chromium-bridge/build-framework.sh ~/chromium/src out/Release_codecs` packages it. To switch the main build, copy the three arguments into `out/Release/args.gn` and rebuild. That rebuilds `//media`, `//content`, Blink's media parts, WebRTC and their dependents (6,427 ninja actions, about 20 minutes on an M-series Mac), then run `chromium-bridge/build-framework.sh`. Going back is the same in reverse. Patch 0008 itself changes nothing in `out/Release` while the argument is off (checked with `gn args … --list`).
