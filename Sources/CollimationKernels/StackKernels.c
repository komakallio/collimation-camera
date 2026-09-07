#include "StackKernels.h"

#include <math.h>
#include <stdint.h>

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

    uint16_t peak = 0;
    for (int y = y0; y < y1; y++) {
        const uint16_t *row = pixels + y * width;
        for (int x = x0; x < x1; x++) {
            if (row[x] > peak) {
                peak = row[x];
            }
        }
    }
    if (peak == 0) {
        return 0;
    }
    uint16_t threshold = (uint16_t)((double)peak * 0.35);
    if (threshold < 1) {
        threshold = 1;
    }

    double sum_x = 0.0;
    double sum_y = 0.0;
    double flux = 0.0;
    for (int y = y0; y < y1; y++) {
        const uint16_t *row = pixels + y * width;
        for (int x = x0; x < x1; x++) {
            uint16_t value = row[x];
            if (value < threshold) {
                continue;
            }
            double weight = (double)value;
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
