/* Native 8x8 ROM generator from the Anikki-16x16 source font,
   taken from https://github.com/k80w/consolefonts

   Generate the packed native 8x8 .rom file used by the M2M OSM renderer.

   The source font is an exact 2x enlargement: every logical 8x8 pixel is a
   uniform 2x2 block in the 16x16 source.  The generator verifies that
   invariant before collapsing the font.  Consequently, expanding the output
   by 2x with nearest-neighbour sampling reproduces the old 16x16 renderer
   bit-for-bit at 100% OSM size.  Each output line contains one complete
   8x8 glyph, row 0 through row 7, so the renderer needs only one shallow
   ROM lookup per character.

   Hint: The usage of "unsigned" "everywhere" is very important.
   Otherwise the conversion result will be wrong.

   done by sy2002 in January 2021
   native 8x8 generation added in July 2026
*/

#include <stdio.h>
#include <stdlib.h>
#include "Anikki-16x16-m2m.h"

#define GLYPH_COUNT 256u
#define SOURCE_DX   16u
#define SOURCE_DY   16u
#define NATIVE_DX    8u
#define NATIVE_DY    8u

static unsigned int source_row(unsigned int glyph, unsigned int row)
{
    unsigned int index = (glyph * SOURCE_DY + row) * 2u;
    return ((unsigned int) FONT[index] << 8) | (unsigned int) FONT[index + 1u];
}

static unsigned int source_pixel(unsigned int glyph, unsigned int x, unsigned int y)
{
    return (source_row(glyph, y) >> (15u - x)) & 1u;
}

int main(void)
{
    FILE *f;
    unsigned int glyph;
    unsigned int y;
    unsigned int x;
    char bin[NATIVE_DX * NATIVE_DY + 1u];

    if (FONT_SIZE != GLYPH_COUNT * SOURCE_DX * SOURCE_DY / 8u)
    {
        fprintf(stderr, "Unexpected FONT_SIZE: %u (expected %u)\n",
                FONT_SIZE, GLYPH_COUNT * SOURCE_DX * SOURCE_DY / 8u);
        return EXIT_FAILURE;
    }

    /* Prove that the 16x16 source can be collapsed without losing a bit. */
    for (glyph = 0; glyph < GLYPH_COUNT; glyph++)
    {
        for (y = 0; y < NATIVE_DY; y++)
        {
            for (x = 0; x < NATIVE_DX; x++)
            {
                unsigned int p = source_pixel(glyph, 2u * x, 2u * y);
                if (source_pixel(glyph, 2u * x + 1u, 2u * y) != p ||
                    source_pixel(glyph, 2u * x, 2u * y + 1u) != p ||
                    source_pixel(glyph, 2u * x + 1u, 2u * y + 1u) != p)
                {
                    fprintf(stderr,
                            "Font is not a uniform 2x enlargement: glyph %u, native pixel (%u,%u)\n",
                            glyph, x, y);
                    return EXIT_FAILURE;
                }
            }
        }
    }

    f = fopen("Anikki-8x8-m2m.rom", "w");
    if (f == NULL)
    {
        perror("Anikki-8x8-m2m.rom");
        return EXIT_FAILURE;
    }

    bin[NATIVE_DX * NATIVE_DY] = '\0';
    for (glyph = 0; glyph < GLYPH_COUNT; glyph++)
    {
        for (y = 0; y < NATIVE_DY; y++)
        {
            for (x = 0; x < NATIVE_DX; x++)
                bin[y * NATIVE_DX + x] =
                    source_pixel(glyph, 2u * x, 2u * y) ? '1' : '0';
        }

        if (fprintf(f, "%s\n", bin) < 0)
        {
            perror("Writing Anikki-8x8-m2m.rom");
            fclose(f);
            return EXIT_FAILURE;
        }
    }

    if (fclose(f) != 0)
    {
        perror("Closing Anikki-8x8-m2m.rom");
        return EXIT_FAILURE;
    }

    printf("Generated validated packed native 8x8 ROM: %u glyphs, %u bits/glyph\n",
           GLYPH_COUNT, NATIVE_DX * NATIVE_DY);
    return EXIT_SUCCESS;
}
