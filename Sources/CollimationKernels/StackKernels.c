#include "StackKernels.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>

static inline void add_edge(
    const uint16_t *pixels,
    int width,
    int height,
    int x,
    int y0,
    int y1,
    float dx,
    float fy,
    int y0ok,
    int y1ok,
    float *sum,
    float *weight
) {
    float sx = (float)x + dx;
    int x0 = (int)floorf(sx);
    float fx = sx - (float)x0;
    int x1 = x0 + 1;
    float w00 = (1.f - fx) * (1.f - fy);
    float w10 = fx * (1.f - fy);
    float w01 = (1.f - fx) * fy;
    float w11 = fx * fy;
    float acc = 0.f;
    float wt = 0.f;
    if (w00 > 1e-6f && y0ok && (unsigned)x0 < (unsigned)width) {
        acc += (float)pixels[y0 * width + x0] * w00;
        wt += w00;
    }
    if (w10 > 1e-6f && y0ok && (unsigned)x1 < (unsigned)width) {
        acc += (float)pixels[y0 * width + x1] * w10;
        wt += w10;
    }
    if (w01 > 1e-6f && y1ok && (unsigned)x0 < (unsigned)width) {
        acc += (float)pixels[y1 * width + x0] * w01;
        wt += w01;
    }
    if (w11 > 1e-6f && y1ok && (unsigned)x1 < (unsigned)width) {
        acc += (float)pixels[y1 * width + x1] * w11;
        wt += w11;
    }
    if (wt > 1e-6f) {
        *sum += acc / wt;
        *weight += 1.f;
    }
}

void collimation_accumulate_integer(
    const uint16_t *pixels,
    int width,
    int height,
    int dx,
    int dy,
    float *sum,
    float *weight
) {
    int x_start = dx < 0 ? -dx : 0;
    int x_end = width - (dx > 0 ? dx : 0);
    if (x_start >= x_end) {
        return;
    }
    for (int y = 0; y < height; y++) {
        int src_y = y + dy;
        if ((unsigned)src_y >= (unsigned)height) {
            continue;
        }
        float *s = sum + y * width;
        float *w = weight + y * width;
        const uint16_t *src = pixels + src_y * width + dx;
        for (int x = x_start; x < x_end; x++) {
            s[x] += (float)src[x];
            w[x] += 1.f;
        }
    }
}

void collimation_accumulate_bilinear(
    const uint16_t *pixels,
    int width,
    int height,
    float dx,
    float dy,
    float *sum,
    float *weight
) {
    for (int y = 0; y < height; y++) {
        float sy = (float)y + dy;
        int y0 = (int)floorf(sy);
        float fy = sy - (float)y0;
        int y1 = y0 + 1;
        int y0ok = (unsigned)y0 < (unsigned)height;
        int y1ok = (unsigned)y1 < (unsigned)height;
        float *s = sum + y * width;
        float *w = weight + y * width;
        if (!y0ok || !y1ok) {
            for (int x = 0; x < width; x++) {
                add_edge(pixels, width, height, x, y0, y1, dx, fy, y0ok, y1ok, s + x, w + x);
            }
            continue;
        }

        int x_start = dx < 0.f ? (int)ceilf(-dx) : 0;
        int x_end = (int)ceilf((float)(width - 1) - dx);
        if (x_start < 0) {
            x_start = 0;
        }
        if (x_end > width) {
            x_end = width;
        }
        if (x_start > x_end) {
            x_start = x_end;
        }

        for (int x = 0; x < x_start; x++) {
            add_edge(pixels, width, height, x, y0, y1, dx, fy, 1, 1, s + x, w + x);
        }
        const uint16_t *row0 = pixels + y0 * width;
        const uint16_t *row1 = pixels + y1 * width;
        for (int x = x_start; x < x_end; x++) {
            float sx = (float)x + dx;
            int x0 = (int)floorf(sx);
            float fx = sx - (float)x0;
            float v00 = (float)row0[x0];
            float v10 = (float)row0[x0 + 1];
            float v01 = (float)row1[x0];
            float v11 = (float)row1[x0 + 1];
            float top = v00 + (v10 - v00) * fx;
            float bot = v01 + (v11 - v01) * fx;
            s[x] += top + (bot - top) * fy;
            w[x] += 1.f;
        }
        for (int x = x_end; x < width; x++) {
            add_edge(pixels, width, height, x, y0, y1, dx, fy, 1, 1, s + x, w + x);
        }
    }
}

/* Fraction of the star's height above the sky. A fraction of the raw peak
   falls below the sky when the star is faint, and the pedestal then pulls
   the centroid to the middle of the window. */
static const double k_moment_excess_fraction = 0.35;
/* Same lower-tail noise estimate as StarDetector.backgroundStats. */
static const double k_moment_sigma_floor = 12.0;
static const double k_moment_sigma_scale = 1.55;

static int moment_window(
    int width,
    int height,
    int cx,
    int cy,
    int half_window,
    int *x0_out,
    int *y0_out,
    int *x1_out,
    int *y1_out
) {
    int hw = half_window < 32 ? 32 : half_window;
    int max_dim = width > height ? width : height;
    if (hw > max_dim) {
        hw = max_dim;
    }
    int x0 = cx - hw;
    int y0 = cy - hw;
    int x1 = cx + hw + 1;
    int y1 = cy + hw + 1;
    if (x0 < 0) {
        x0 = 0;
    }
    if (y0 < 0) {
        y0 = 0;
    }
    if (x1 > width) {
        x1 = width;
    }
    if (y1 > height) {
        y1 = height;
    }
    if (x1 <= x0 || y1 <= y0) {
        return 0;
    }
    *x0_out = x0;
    *y0_out = y0;
    *x1_out = x1;
    *y1_out = y1;
    return 1;
}

static int moment_levels_in_window(
    const uint16_t *pixels,
    int width,
    int x0,
    int y0,
    int x1,
    int y1,
    uint16_t *out_sky,
    uint16_t *out_threshold
) {
    uint32_t *hist = calloc(65536, sizeof(uint32_t));
    if (hist == NULL) {
        return 0;
    }
    uint16_t peak = 0;
    uint32_t count = 0;
    for (int y = y0; y < y1; y++) {
        const uint16_t *row = pixels + (size_t)y * (size_t)width;
        for (int x = x0; x < x1; x++) {
            uint16_t value = row[x];
            hist[value] += 1;
            count += 1;
            if (value > peak) {
                peak = value;
            }
        }
    }
    if (count == 0 || peak == 0) {
        free(hist);
        return 0;
    }

    uint32_t target05 = count * 5 / 100;
    uint32_t target16 = count * 16 / 100;
    uint32_t seen = 0;
    uint16_t p05 = 0;
    uint16_t p16 = 0;
    int have05 = 0;
    int have16 = 0;
    for (int value = 0; value < 65536; value++) {
        seen += hist[value];
        if (!have05 && seen > target05) {
            p05 = (uint16_t)value;
            have05 = 1;
        }
        if (!have16 && seen > target16) {
            p16 = (uint16_t)value;
            have16 = 1;
            break;
        }
    }
    free(hist);

    double sigma = ((double)p16 - (double)p05) * k_moment_sigma_scale;
    if (sigma < k_moment_sigma_floor) {
        sigma = k_moment_sigma_floor;
    }
    double excess = (double)peak - (double)p16;
    /* The only signal in the window is the star. If it does not clear the
       noise, there is nothing to lock onto. */
    if (excess < sigma) {
        return 0;
    }
    double cut = (double)p16 + k_moment_excess_fraction * excess;
    double noise_cut = (double)p16 + sigma;
    if (cut < noise_cut) {
        cut = noise_cut;
    }
    if (cut > (double)peak) {
        return 0;
    }
    uint16_t threshold = (uint16_t)ceil(cut);
    if (threshold < p16) {
        threshold = p16;
    }
    *out_sky = p16;
    *out_threshold = threshold;
    return 1;
}

int collimation_moment_levels(
    const uint16_t *pixels,
    int width,
    int height,
    int cx,
    int cy,
    int half_window,
    uint16_t *out_sky,
    uint16_t *out_threshold
) {
    int x0, y0, x1, y1;
    if (!moment_window(width, height, cx, cy, half_window, &x0, &y0, &x1, &y1)) {
        return 0;
    }
    return moment_levels_in_window(pixels, width, x0, y0, x1, y1, out_sky, out_threshold);
}

int collimation_moment_centroid(
    const uint16_t *pixels,
    int width,
    int height,
    int cx,
    int cy,
    int half_window,
    double *out_x,
    double *out_y
) {
    int x0, y0, x1, y1;
    if (!moment_window(width, height, cx, cy, half_window, &x0, &y0, &x1, &y1)) {
        return 0;
    }
    uint16_t sky = 0;
    uint16_t threshold = 0;
    if (!moment_levels_in_window(pixels, width, x0, y0, x1, y1, &sky, &threshold)) {
        return 0;
    }

    double sum_x = 0.0;
    double sum_y = 0.0;
    double flux = 0.0;
    for (int y = y0; y < y1; y++) {
        const uint16_t *row = pixels + (size_t)y * (size_t)width;
        for (int x = x0; x < x1; x++) {
            uint16_t value = row[x];
            if (value < threshold) {
                continue;
            }
            double weight = (double)value - (double)sky;
            flux += weight;
            sum_x += (double)x * weight;
            sum_y += (double)y * weight;
        }
    }
    if (flux <= 0.0) {
        return 0;
    }
    *out_x = sum_x / flux;
    *out_y = sum_y / flux;
    return 1;
}
