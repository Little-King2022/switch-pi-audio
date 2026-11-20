#include <stddef.h>
#include <stdint.h>

typedef struct SwitchSBCDecoder SwitchSBCDecoder;

SwitchSBCDecoder *switch_sbc_create(void);
void switch_sbc_destroy(SwitchSBCDecoder *decoder);

// Consumes one complete 48 kHz stereo frame or one invalid byte.
// When more input is needed, return zero. Output holds up to 128 stereo samples.
size_t switch_sbc_decode(SwitchSBCDecoder *decoder, const uint8_t *data,
                         size_t length, int16_t *pcm, uint32_t *pcm_bytes);
