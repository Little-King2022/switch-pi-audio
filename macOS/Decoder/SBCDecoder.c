#include "SBCDecoder.h"
#include "oi_codec_sbc.h"

#include <stdlib.h>

struct SwitchSBCDecoder {
    OI_CODEC_SBC_DECODER_CONTEXT context;
    OI_CODEC_SBC_CODEC_DATA_STEREO work;
    uint8_t format;
    int initialized;
};

SwitchSBCDecoder *switch_sbc_create(void) {
    return calloc(1, sizeof(SwitchSBCDecoder));
}

void switch_sbc_destroy(SwitchSBCDecoder *decoder) {
    free(decoder);
}

size_t switch_sbc_decode(SwitchSBCDecoder *decoder, const uint8_t *data,
                         size_t length, int16_t *pcm, uint32_t *pcm_bytes) {
    *pcm_bytes = 0;
    if (length < 4) return 0;

    unsigned format = data[1];
    unsigned mode = (format >> 2) & 3;
    unsigned bitpool = data[2];
    // Match the SBC capabilities published on the Pi: 48 kHz, eight subbands,
    // sixteen blocks, stereo or joint stereo.
    if (data[0] != 0x9c || (format & 0xf1) != 0xf1 || mode < 2 ||
        bitpool < 2 || bitpool > 53) return 1;
    unsigned frame_size = 12 + (16 * bitpool + (mode == 3 ? 8 : 0) + 7) / 8;
    if (length < frame_size) return 0;

    if (!decoder->initialized || decoder->format != format) {
        decoder->initialized = OI_CODEC_SBC_DecoderReset(
            &decoder->context, decoder->work.data, sizeof(decoder->work.data), 2, 2, 0) == OI_OK;
        decoder->format = format;
    }
    if (decoder->initialized) {
        uint32_t remaining = frame_size;
        uint32_t capacity = 512;
        if (OI_CODEC_SBC_DecodeFrame(&decoder->context, &data, &remaining, pcm, &capacity) == OI_OK &&
            remaining == 0 && capacity == 512) {
            *pcm_bytes = capacity;
        } else {
            decoder->initialized = 0;
        }
    }
    return frame_size;
}
